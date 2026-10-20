import Foundation

/// Why an `MCPProxy` stopped pumping.
enum MCPProxyEnd: Sendable {
    /// The client closed its side of the stream.
    case clientEOF
    /// The server closed its side of the stream, or a read from it failed.
    case serverEOF
    /// `stop()` was called, or the task running the proxy was cancelled.
    case stopped
    /// A frame could not be delivered, typically because the peer went away.
    case writeFailed(any Error)
}

/// Carries newline-delimited JSON-RPC frames between an MCP client and an MCP
/// server, passing each one through an `MCPFrameRewriter`.
///
/// Each direction runs on a thread of its own with blocking reads, so a slow
/// consumer on one side never stalls the other direction's reads. Frames are
/// reassembled across reads and may be any length. A final frame with no line
/// terminator at EOF is forwarded as it stands.
///
/// SIGPIPE is suppressed per descriptor with `F_SETNOSIGPIPE` on the two
/// output handles, so a vanished peer surfaces as `writeFailed` and the rest
/// of the process keeps its signal dispositions.
///
/// The proxy never closes the handles it is given; the owner closes the
/// server's input to let the server see EOF. A write blocked on a peer that
/// has stopped reading is only released when that peer goes away, so `stop()`
/// is best followed by terminating the server.
final class MCPProxy: @unchecked Sendable {
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
    private let retryShareWriteDenial: (@Sendable (ShareWriteDenial) -> Bool)?

    /// Becomes readable (hung up) when the proxy should stop, which wakes a
    /// pump blocked in `poll`.
    private let wakeReader: Int32
    private var wakeWriter: Int32

    private let lock = NSLock()
    private let serverWriteLock = NSLock()
    private var activity = Date()
    private var toServerCount = 0
    private var toClientCount = 0

    private let ended = OneShot<MCPProxyEnd>()
    private let toServerDone = OneShot<Void>()
    private let toClientDone = OneShot<Void>()

    /// - Parameter retryShareWriteDenial: Asked whenever the server reports
    ///   that the share refused a write. Returning `true` withholds that
    ///   response from the client and sends the request to the server again;
    ///   the caller decides how often that is allowed. When `nil`, such
    ///   responses are delivered like any other.
    init(
        clientIn: FileHandle,
        clientOut: FileHandle,
        serverIn: FileHandle,
        serverOut: FileHandle,
        rewriter: MCPFrameRewriter,
        retryShareWriteDenial: (@Sendable (ShareWriteDenial) -> Bool)? = nil
    ) {
        self.clientIn = clientIn
        self.clientOut = clientOut
        self.serverIn = serverIn
        self.serverOut = serverOut
        self.rewriter = rewriter
        self.retryShareWriteDenial = retryShareWriteDenial

        var wake: [Int32] = [-1, -1]
        let created = pipe(&wake)
        precondition(created == 0, "cannot create a pipe: errno \(errno)")
        wakeReader = wake[0]
        wakeWriter = wake[1]

        _ = fcntl(clientOut.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(serverIn.fileDescriptor, F_SETNOSIGPIPE, 1)
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

    /// Frames delivered to the server, retries included.
    var framesToServer: Int {
        lock.lock()
        defer { lock.unlock() }
        return toServerCount
    }

    /// Frames delivered to the client; responses withheld for a retry are not
    /// counted.
    var framesToClient: Int {
        lock.lock()
        defer { lock.unlock() }
        return toClientCount
    }

    /// Pumps until a side reaches EOF, a write fails, or `stop()` is called,
    /// and returns once both directions have finished. Call it once.
    func run() async -> MCPProxyEnd {
        await withTaskCancellationHandler {
            start(.toServer, done: toServerDone)
            start(.toClient, done: toClientDone)
            let end = await ended.waitIgnoringCancellation() ?? .stopped
            wake()
            _ = await toServerDone.waitIgnoringCancellation()
            _ = await toClientDone.waitIgnoringCancellation()
            return end
        } onCancel: {
            stop()
        }
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
            ended.fulfil(end)
            wake()
            done.fulfil(())
        }
    }

    private func wake() {
        lock.lock()
        defer { lock.unlock() }
        if wakeWriter >= 0 {
            close(wakeWriter)
            wakeWriter = -1
        }
    }

    private func touch() {
        lock.lock()
        activity = Date()
        lock.unlock()
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
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return eof
                }
                if count == 0 {
                    if !pending.isEmpty { try forward(pending, direction, terminated: false) }
                    return eof
                }
                touch()

                pending.append(contentsOf: chunk[0..<count])
                while let newline = pending[scanned...].firstIndex(of: 0x0A) {
                    try forward(pending[..<newline], direction, terminated: true)
                    pending.removeSubrange(0..<newline + 1)
                    scanned = 0
                }
                scanned = pending.count
            }
        } catch {
            return .writeFailed(error)
        }
    }

    /// Rewrites one frame and delivers it, or withholds it and repeats the
    /// request it answers.
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
            if let denial, retryShareWriteDenial?(denial) == true {
                let resent = rewriter.clientToServer(denial.originalRequest)
                try deliver(resent + Data([0x0A]), .toServer, counting: true)
                return
            }
            try deliver(frame + terminator, .toClient, counting: true)
        }
    }

    private func deliver(_ data: Data, _ direction: Direction, counting: Bool) throws {
        switch direction {
        case .toServer:
            serverWriteLock.lock()
            defer { serverWriteLock.unlock() }
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
