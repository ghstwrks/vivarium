import Foundation

/// Why an `MCPProxy` stopped pumping.
enum MCPProxyEnd: Sendable {
    /// The client closed its side of the stream, and the server then finished
    /// answering and closed its own.
    case clientEOF
    /// The server closed its side of the stream, or a read from it failed.
    case serverEOF
    /// `stop()` was called, or the task running the proxy was cancelled.
    case stopped
    /// A frame could not be delivered, typically because the peer went away.
    case writeFailed(any Error)
    /// A frame grew past the proxy's size limit before its line ended.
    case frameTooLarge
}

/// Carries newline-delimited JSON-RPC frames between an MCP client and an MCP
/// server, passing each one through an `MCPFrameRewriter`.
///
/// Each direction runs on a thread of its own with blocking reads, so a slow
/// consumer on one side never stalls the other direction's reads. Frames are
/// reassembled across reads. A final frame with no line terminator at EOF is
/// forwarded as it stands, and a frame longer than the size limit ends the
/// session.
///
/// When the client reaches EOF the proxy closes the server's input, which is
/// how a stdio server learns it has no more requests, and keeps delivering the
/// server's remaining responses until the server closes its output.
///
/// SIGPIPE is suppressed per descriptor with `F_SETNOSIGPIPE` on the two
/// output handles, so a vanished peer surfaces as `writeFailed` and the rest
/// of the process keeps its signal dispositions.
///
/// Apart from the server's input after client EOF, the proxy never closes the
/// handles it is given. A write blocked on a peer that has stopped reading is
/// only released when that peer goes away, so `stop()` is best followed by
/// terminating the server.
final class MCPProxy: @unchecked Sendable {
    static let defaultMaxFrameBytes = 64 * 1024 * 1024

    private enum Direction {
        case toServer
        case toClient
    }

    private static let chunkSize = 64 * 1024

    private let clientIn: FileHandle
    private let clientOut: FileHandle
    private let serverIn: FileHandle
    private let serverOut: FileHandle
    private let rewriter: MCPFrameRewriter
    private let maxFrameBytes: Int
    private let retryShareWriteDenial: (@Sendable (ShareWriteDenial) -> Bool)?

    /// Becomes readable (hung up) when the proxy should stop, which wakes a
    /// pump blocked in `poll`.
    private let wakeReader: Int32
    private var wakeWriter: Int32

    private let lock = NSLock()
    private var hasRun = false
    private var activity = Date()
    private var toServerCount = 0
    private var toClientCount = 0
    private var clientReachedEOF = false
    private var retriedRequests: Set<JSONRPCID> = []

    /// Held while writing to, or closing, the server's input.
    private let serverWriteLock = NSLock()
    private var serverInputClosed = false

    /// Requests waiting to be sent to the server a second time. They are
    /// written by a thread of their own so the thread delivering responses
    /// never waits on the server's input.
    private let resends = NSCondition()
    private var resendQueue: [Data] = []
    private var resendsClosed = false

    private let ended = OneShot<MCPProxyEnd>()
    private let toServerDone = OneShot<Void>()
    private let toClientDone = OneShot<Void>()
    private let resenderDone = OneShot<Void>()

    /// - Parameters:
    ///   - retryShareWriteDenial: Asked when the server reports that the share
    ///     refused a write. It runs on the thread delivering responses, so it
    ///     must return quickly. Returning `true` withholds that response and
    ///     sends the request to the server again, at most once per request;
    ///     when the retry is denied too, that response is delivered. When
    ///     `nil`, such responses are delivered like any other. Request
    ///     identifiers are assumed not to be reused within a session.
    ///   - maxFrameBytes: The longest frame, without its line terminator, that
    ///     the proxy will buffer.
    init(
        clientIn: FileHandle,
        clientOut: FileHandle,
        serverIn: FileHandle,
        serverOut: FileHandle,
        rewriter: MCPFrameRewriter,
        retryShareWriteDenial: (@Sendable (ShareWriteDenial) -> Bool)? = nil,
        maxFrameBytes: Int = MCPProxy.defaultMaxFrameBytes
    ) {
        self.clientIn = clientIn
        self.clientOut = clientOut
        self.serverIn = serverIn
        self.serverOut = serverOut
        self.rewriter = rewriter
        self.retryShareWriteDenial = retryShareWriteDenial
        self.maxFrameBytes = maxFrameBytes

        var wake: [Int32] = [-1, -1]
        let created = pipe(&wake)
        precondition(created == 0, "cannot create a pipe: errno \(errno)")
        wakeReader = wake[0]
        wakeWriter = wake[1]

        for (name, handle) in [("client output", clientOut), ("server input", serverIn)] {
            if fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
                log.warn("Cannot suppress SIGPIPE on the MCP \(name): errno \(errno).")
            }
        }
    }

    deinit {
        close(wakeReader)
        if wakeWriter >= 0 { close(wakeWriter) }
    }

    /// When a chunk last arrived from, or a frame was last written to, either
    /// side. Starts at the proxy's creation.
    var lastActivity: Date {
        lock.lock()
        defer { lock.unlock() }
        return activity
    }

    /// Frames delivered to the server, resends included.
    var framesToServer: Int {
        lock.lock()
        defer { lock.unlock() }
        return toServerCount
    }

    /// Frames delivered to the client; responses withheld for a resend are not
    /// counted.
    var framesToClient: Int {
        lock.lock()
        defer { lock.unlock() }
        return toClientCount
    }

    /// Pumps until the session ends and returns once every thread has
    /// finished. A proxy runs once; a second call returns `.stopped` at once.
    func run() async -> MCPProxyEnd {
        guard claimRun() else { return .stopped }

        return await withTaskCancellationHandler {
            start(.toServer, done: toServerDone)
            start(.toClient, done: toClientDone)
            startResender()
            let end = await ended.waitIgnoringCancellation() ?? .stopped
            wake()
            _ = await toServerDone.waitIgnoringCancellation()
            _ = await toClientDone.waitIgnoringCancellation()
            _ = await resenderDone.waitIgnoringCancellation()
            return end
        } onCancel: {
            stop()
        }
    }

    private func claimRun() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { hasRun = true }
        return !hasRun
    }

    /// Ends the session as `.stopped` unless it has already ended another way.
    /// Safe to call from any thread, before or after `run()`.
    func stop() {
        ended.fulfil(.stopped)
        wake()
    }

    private func start(_ direction: Direction, done: OneShot<Void>) {
        Thread.detachNewThread { [self] in
            let end = pump(direction)
            switch (direction, end) {
            case (.toServer, .clientEOF):
                finishClientInput()
            case (.toClient, .serverEOF) where clientEOF:
                ended.fulfil(.clientEOF)
                wake()
            default:
                ended.fulfil(end)
                wake()
            }
            done.fulfil(())
        }
    }

    private func startResender() {
        Thread.detachNewThread { [self] in
            if let end = sendResends() {
                ended.fulfil(end)
                wake()
            }
            resenderDone.fulfil(())
        }
    }

    private func wake() {
        lock.lock()
        if wakeWriter >= 0 {
            close(wakeWriter)
            wakeWriter = -1
        }
        lock.unlock()

        resends.lock()
        resendsClosed = true
        resends.broadcast()
        resends.unlock()
    }

    private var clientEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clientReachedEOF
    }

    /// Passes the client's EOF on to the server and leaves the other direction
    /// running to collect the server's last responses.
    private func finishClientInput() {
        lock.lock()
        clientReachedEOF = true
        lock.unlock()

        serverWriteLock.lock()
        serverInputClosed = true
        try? serverIn.close()
        serverWriteLock.unlock()
    }

    private func pump(_ direction: Direction) -> MCPProxyEnd {
        let input = (direction == .toServer ? clientIn : serverOut).fileDescriptor
        let eof: MCPProxyEnd = direction == .toServer ? .clientEOF : .serverEOF

        var polled = [
            pollfd(fd: input, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeReader, events: Int16(POLLIN), revents: 0),
        ]
        var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
        var pending = Data()
        var scanned = 0

        do {
            while true {
                if poll(&polled, 2, -1) < 0 {
                    if errno == EINTR { continue }
                    return eof
                }
                if polled[1].revents != 0 { return .stopped }

                let count = read(input, &chunk, Self.chunkSize)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if count <= 0 {
                    if !pending.isEmpty { try forward(pending, direction, terminated: false) }
                    return eof
                }
                touch()

                pending.append(contentsOf: chunk[0..<count])
                while let newline = pending[scanned...].firstIndex(of: 0x0A) {
                    if newline > maxFrameBytes { return .frameTooLarge }
                    try forward(pending[..<newline], direction, terminated: true)
                    pending.removeSubrange(0..<newline + 1)
                    scanned = 0
                }
                if pending.count > maxFrameBytes { return .frameTooLarge }
                scanned = pending.count
            }
        } catch {
            return .writeFailed(error)
        }
    }

    private func touch() {
        lock.lock()
        activity = Date()
        lock.unlock()
    }

    /// Rewrites one frame and delivers it, or withholds it and queues the
    /// request it answers to be sent again.
    private func forward(_ line: Data, _ direction: Direction, terminated: Bool) throws {
        let terminator = terminated ? Data([0x0A]) : Data()
        if line.isEmpty || line == Data([0x0D]) {
            try deliver(line + terminator, direction, counting: false)
            return
        }

        switch direction {
        case .toServer:
            try deliver(rewriter.clientToServer(line) + terminator, .toServer, counting: true)
        case .toClient:
            let (frame, denial) = rewriter.serverToClient(line)
            if let denial, shouldResend(denial) {
                queueResend(denial.originalRequest)
                return
            }
            try deliver(frame + terminator, .toClient, counting: true)
        }
    }

    private func shouldResend(_ denial: ShareWriteDenial) -> Bool {
        guard let retryShareWriteDenial, !clientEOF else { return false }
        lock.lock()
        let alreadyRetried = retriedRequests.contains(denial.requestID)
        lock.unlock()
        guard !alreadyRetried, retryShareWriteDenial(denial) else { return false }

        lock.lock()
        retriedRequests.insert(denial.requestID)
        lock.unlock()
        return true
    }

    private func queueResend(_ request: Data) {
        resends.lock()
        resendQueue.append(request)
        resends.signal()
        resends.unlock()
    }

    /// Writes queued resends until the proxy ends. Returns how it ended only
    /// if a write failed.
    private func sendResends() -> MCPProxyEnd? {
        while true {
            resends.lock()
            while resendQueue.isEmpty && !resendsClosed { resends.wait() }
            if resendsClosed {
                resends.unlock()
                return nil
            }
            let request = resendQueue.removeFirst()
            resends.unlock()

            do {
                try deliver(rewriter.clientToServer(request) + Data([0x0A]), .toServer, counting: true)
            } catch {
                return .writeFailed(error)
            }
        }
    }

    private func deliver(_ data: Data, _ direction: Direction, counting: Bool) throws {
        switch direction {
        case .toServer:
            serverWriteLock.lock()
            defer { serverWriteLock.unlock() }
            if serverInputClosed { return }
            try Self.writeAll(data, to: serverIn.fileDescriptor)
        case .toClient:
            try Self.writeAll(data, to: clientOut.fileDescriptor)
        }

        lock.lock()
        activity = Date()
        if counting {
            switch direction {
            case .toServer: toServerCount += 1
            case .toClient: toClientCount += 1
            }
        }
        lock.unlock()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                } else if errno == EAGAIN {
                    var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&waiting, 1, -1)
                } else if errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
}
