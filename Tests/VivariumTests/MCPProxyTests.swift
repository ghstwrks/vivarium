import Foundation
import Testing

@testable import Vivarium

/// Whatever the next read on `handle` returns, which is empty only at EOF.
/// `FileHandle.read(upToCount:)` waits for the full count on a pipe, so a
/// short frame would never be seen.
private func readAvailable(_ handle: FileHandle) -> Data {
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(handle.fileDescriptor, &chunk, chunk.count)
        if count >= 0 { return Data(chunk[0..<count]) }
        if errno != EINTR { return Data() }
    }
}

/// Collects everything that arrives on `handle` until it reaches EOF.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            while case let chunk = readAvailable(handle), !chunk.isEmpty {
                lock.lock()
                buffer.append(chunk)
                lock.unlock()
            }
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// A server that answers each complete line it reads and records the raw
/// bytes it was sent, so a test can see exactly what reached it and when. Once
/// its input reaches EOF it sends `atEOF` and then closes its output, as a
/// stdio server does when it exits.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var raw = Data()
    private let respond: @Sendable (Data) -> [Data]

    init(
        input: FileHandle,
        output: FileHandle,
        respond: @escaping @Sendable (Data) -> [Data],
        atEOF: @escaping @Sendable () -> [Data] = { [] }
    ) {
        self.respond = respond
        Thread.detachNewThread { [self] in
            var pending = Data()
            while case let chunk = readAvailable(input), !chunk.isEmpty {
                lock.lock()
                raw.append(chunk)
                lock.unlock()
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(0...newline)
                    for reply in respond(line) {
                        try? output.write(contentsOf: reply + Data([0x0A]))
                    }
                }
            }
            for reply in atEOF() { try? output.write(contentsOf: reply + Data([0x0A])) }
            try? output.close()
        }
    }

    /// Echoes every line back unchanged.
    static let echo: @Sendable (Data) -> [Data] = { [$0] }

    var received: Data {
        lock.lock()
        defer { lock.unlock() }
        return raw
    }
}

/// Four pipes wired the way a session wires them, with the test holding the
/// far end of each.
private struct Harness {
    let clientIn = Pipe()
    let clientOut = Pipe()
    let serverIn = Pipe()
    let serverOut = Pipe()
    let rewriter = MCPFrameRewriter(mapping: MCPPathMapping(hostArtifactsDirectory: "/host/artifacts"))
    let proxy: MCPProxy
    let toClient: Collector

    init(retry: (@Sendable (ShareWriteDenial) -> Bool)? = nil, maxFrameBytes: Int = MCPProxy.defaultMaxFrameBytes) {
        proxy = MCPProxy(
            clientIn: clientIn.fileHandleForReading,
            clientOut: clientOut.fileHandleForWriting,
            serverIn: serverIn.fileHandleForWriting,
            serverOut: serverOut.fileHandleForReading,
            rewriter: rewriter,
            retryShareWriteDenial: retry,
            maxFrameBytes: maxFrameBytes
        )
        toClient = Collector(clientOut.fileHandleForReading)
    }

    func server(
        _ respond: @escaping @Sendable (Data) -> [Data] = FakeServer.echo,
        atEOF: @escaping @Sendable () -> [Data] = { [] }
    ) -> FakeServer {
        FakeServer(
            input: serverIn.fileHandleForReading,
            output: serverOut.fileHandleForWriting,
            respond: respond,
            atEOF: atEOF
        )
    }

    func send(_ text: String) throws {
        try clientIn.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    /// Releases the threads that are blocked reading the far ends.
    func close() {
        try? clientOut.fileHandleForWriting.close()
        try? serverIn.fileHandleForWriting.close()
        try? serverOut.fileHandleForWriting.close()
        try? clientIn.fileHandleForWriting.close()
    }
}

private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("The MCP line proxy")
struct MCPProxyTests {
    private let ping = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"

    @Test("a frame split across writes is forwarded only once it is complete")
    func buffersPartialLines() async throws {
        let harness = Harness()
        let server = harness.server()
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        let frame = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
        try harness.send(String(frame.prefix(10)))
        try harness.send(String(frame.dropFirst(10).prefix(12)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(server.received.isEmpty)

        try harness.send(String(frame.dropFirst(22)) + "\n")
        #expect(await eventually { harness.toClient.data == Data((frame + "\n").utf8) })
        #expect(server.received == Data((frame + "\n").utf8))

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("several frames in one write are forwarded in order")
    func splitsConcatenatedFrames() async throws {
        let harness = Harness()
        _ = harness.server()
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        let frames = (1...3).map { "{\"jsonrpc\":\"2.0\",\"id\":\($0),\"method\":\"ping\"}\n" }
        try harness.send(frames.joined())
        let expected = Data(frames.joined().utf8)
        #expect(await eventually { harness.toClient.data == expected })
        #expect(await eventually { harness.proxy.framesToServer == 3 })
        #expect(await eventually { harness.proxy.framesToClient == 3 })

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("a frame longer than one read chunk arrives intact")
    func carriesLongFrames() async throws {
        let harness = Harness()
        let server = harness.server()
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        let padding = String(repeating: "x", count: 300_000)
        let frame = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{\"pad\":\"\(padding)\"}}\n"
        try harness.send(frame)
        #expect(await eventually { harness.toClient.data.count == frame.utf8.count })
        #expect(harness.toClient.data == Data(frame.utf8))
        #expect(server.received == Data(frame.utf8))

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("requests are rewritten toward the server and responses toward the client")
    func rewritesBothWays() async throws {
        let harness = Harness()
        let server = harness.server { _ in
            [Data("""
                {"id": 2, "jsonrpc": "2.0", "result": {"content": [{"text": "Saved screenshot to '/Volumes/My Shared Files/artifacts/screenshot-1.png' (89.0 kB).", "type": "text"}]}}
                """.utf8)]
        }
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\"}}\n")
        #expect(await eventually { !harness.toClient.data.isEmpty })

        #expect(String(decoding: server.received, as: UTF8.self)
            .contains("\"savePath\":\"/Volumes/My Shared Files/artifacts/screenshot-1.png\""))
        #expect(String(decoding: harness.toClient.data, as: UTF8.self)
            .contains("Saved screenshot to '/host/artifacts/screenshot-1.png' (89.0 kB)."))

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("a refused share write is retried when the caller asks, and the first answer is withheld")
    func retriesOnRequest() async throws {
        let attempts = Counter()
        let denial = Data("""
            {"id": 3, "jsonrpc": "2.0", "result": {"content": [{"text": "Tool error: You don\\u2019t have permission to save the file \\u201cx.png\\u201d.", "type": "text"}], "isError": true}}
            """.utf8)
        let success = Data("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}".utf8)
        let harness = Harness(retry: { _ in true })
        _ = harness.server { _ in attempts.increment() == 1 ? [denial] : [success] }
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\"}}\n")
        #expect(await eventually { harness.toClient.data == success + Data([0x0A]) })
        #expect(attempts.value == 2)
        #expect(await eventually { harness.proxy.framesToServer == 2 })
        #expect(await eventually { harness.proxy.framesToClient == 1 })

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("a refused share write is delivered when no retry is requested")
    func deliversDenialWithoutRetry() async throws {
        let denial = Data("""
            {"id": 3, "jsonrpc": "2.0", "result": {"content": [{"text": "Tool error: You don\\u2019t have permission to save the file \\u201cx.png\\u201d.", "type": "text"}], "isError": true}}
            """.utf8)
        let harness = Harness()
        _ = harness.server { _ in [denial] }
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\"}}\n")
        #expect(await eventually { harness.toClient.data == denial + Data([0x0A]) })

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("the client closing its side ends the session as clientEOF")
    func endsOnClientEOF() async throws {
        let harness = Harness()
        _ = harness.server()
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send(ping + "\n")
        #expect(await eventually { harness.proxy.framesToClient == 1 })
        try harness.clientIn.fileHandleForWriting.close()

        guard case .clientEOF = await running.value else {
            Issue.record("expected clientEOF")
            return
        }
    }

    @Test("the server closing its side ends the session as serverEOF")
    func endsOnServerEOF() async throws {
        let harness = Harness()
        _ = harness.server()
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.serverOut.fileHandleForWriting.close()
        guard case .serverEOF = await running.value else {
            Issue.record("expected serverEOF")
            return
        }
    }

    @Test("a final frame with no newline is forwarded when the client closes")
    func flushesUnterminatedFrame() async throws {
        let harness = Harness()
        let server = harness.server { _ in [] }
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send(ping)
        try harness.clientIn.fileHandleForWriting.close()
        guard case .clientEOF = await running.value else {
            Issue.record("expected clientEOF")
            return
        }
        #expect(await eventually { server.received == Data(ping.utf8) })
    }

    @Test("stop ends a session that is waiting on both sides")
    func stopsWhileIdle() async throws {
        let harness = Harness()
        _ = harness.server()
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try await Task.sleep(for: .milliseconds(100))
        harness.proxy.stop()
        guard case .stopped = await running.value else {
            Issue.record("expected stopped")
            return
        }
    }

    @Test("stop before run makes run return at once")
    func stopsBeforeRunning() async {
        let harness = Harness()
        defer { harness.close() }
        harness.proxy.stop()
        guard case .stopped = await harness.proxy.run() else {
            Issue.record("expected stopped")
            return
        }
    }

    @Test("cancelling the task that runs the proxy stops it")
    func cancellationStops() async throws {
        let harness = Harness()
        defer { harness.close() }
        let running = Task { await harness.proxy.run() }
        try await Task.sleep(for: .milliseconds(100))
        running.cancel()
        guard case .stopped = await running.value else {
            Issue.record("expected stopped")
            return
        }
    }

    @Test("a server that has gone away is a write failure, not a fatal signal")
    func reportsWriteFailure() async throws {
        let harness = Harness()
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.serverIn.fileHandleForReading.close()
        try harness.send(ping + "\n")
        guard case .writeFailed(.server, let error) = await running.value else {
            Issue.record("expected writeFailed to the server")
            return
        }
        #expect((error as? POSIXError)?.code == .EPIPE)
    }

    @Test("a client that has gone away is a write failure on the client's side")
    func reportsClientWriteFailure() async throws {
        let clientIn = Pipe()
        let clientOut = Pipe()
        let serverIn = Pipe()
        let serverOut = Pipe()
        let proxy = MCPProxy(
            clientIn: clientIn.fileHandleForReading,
            clientOut: clientOut.fileHandleForWriting,
            serverIn: serverIn.fileHandleForWriting,
            serverOut: serverOut.fileHandleForReading,
            rewriter: MCPFrameRewriter(mapping: MCPPathMapping(hostArtifactsDirectory: "/host/artifacts"))
        )
        defer {
            try? clientIn.fileHandleForWriting.close()
            try? serverOut.fileHandleForWriting.close()
            try? serverIn.fileHandleForReading.close()
        }
        try clientOut.fileHandleForReading.close()

        let running = Task { await proxy.run() }
        try serverOut.fileHandleForWriting.write(
            contentsOf: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8 + [0x0A])
        )
        guard case .writeFailed(.client, let error) = await running.value else {
            Issue.record("expected writeFailed to the client")
            return
        }
        #expect((error as? POSIXError)?.code == .EPIPE)
    }

    @Test("activity is recorded when frames cross")
    func tracksActivity() async throws {
        let harness = Harness()
        _ = harness.server()
        let before = harness.proxy.lastActivity
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.proxy.lastActivity == before)

        try harness.send(ping + "\n")
        #expect(await eventually { harness.proxy.framesToClient == 1 })
        #expect(harness.proxy.lastActivity > before)

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("responses the server sends after the client closed its side still reach the client")
    func deliversResponsesAfterClientEOF() async throws {
        let late = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"late\"}]}}".utf8)
        let harness = Harness()
        _ = harness.server({ _ in [] }, atEOF: { [late] })
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n")
        try harness.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_tabs\"}}\n")
        try harness.clientIn.fileHandleForWriting.close()

        guard case .clientEOF = await running.value else {
            Issue.record("expected clientEOF")
            return
        }
        #expect(await eventually { harness.toClient.data == late + Data([0x0A]) })
    }

    @Test("a frame past the size limit ends the session")
    func rejectsOversizedFrames() async throws {
        let harness = Harness(maxFrameBytes: 100)
        _ = harness.server()
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send(String(repeating: "x", count: 150))
        guard case .frameTooLarge = await running.value else {
            Issue.record("expected frameTooLarge")
            return
        }
    }

    @Test("a complete line past the size limit ends the session, and one at the limit does not")
    func enforcesTheLimitOnWholeLines() async throws {
        let atLimit = String(repeating: "y", count: 100)
        let harness = Harness(maxFrameBytes: 100)
        _ = harness.server()
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send(atLimit + "\n")
        #expect(await eventually { harness.toClient.data == Data((atLimit + "\n").utf8) })

        try harness.send(atLimit + "z\n")
        guard case .frameTooLarge = await running.value else {
            Issue.record("expected frameTooLarge")
            return
        }
    }

    private static let denialReply = Data("""
        {"id": 3, "jsonrpc": "2.0", "result": {"content": [{"text": "Tool error: You don\\u2019t have permission to save the file \\u201cx.png\\u201d.", "type": "text"}], "isError": true}}
        """.utf8)

    @Test("a server that always refuses the write is retried once, then its answer is delivered")
    func retriesOnlyOnce() async throws {
        let asked = Counter()
        let attempts = Counter()
        let harness = Harness(retry: { _ in _ = asked.increment(); return true })
        _ = harness.server { _ in _ = attempts.increment(); return [Self.denialReply] }
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\"}}\n")
        #expect(await eventually { harness.toClient.data == Self.denialReply + Data([0x0A]) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(attempts.value == 2)
        #expect(asked.value == 1)
        #expect(harness.proxy.framesToClient == 1)

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("a callback that declines the retry leaves the first answer to be delivered")
    func declinedRetryDelivers() async throws {
        let asked = Counter()
        let attempts = Counter()
        let harness = Harness(retry: { _ in _ = asked.increment(); return false })
        _ = harness.server { _ in _ = attempts.increment(); return [Self.denialReply] }
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\"}}\n")
        #expect(await eventually { harness.toClient.data == Self.denialReply + Data([0x0A]) })
        #expect(attempts.value == 1)
        #expect(asked.value == 1)

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("a request that is never answered does not disturb later traffic")
    func unansweredRequestIsHarmless() async throws {
        let harness = Harness()
        _ = harness.server { line in
            String(decoding: line, as: UTF8.self).contains("\"id\":9") ? [] : [line]
        }
        let running = Task { await harness.proxy.run() }
        defer { harness.close() }

        try harness.send("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\"}}\n")
        let later = "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"ping\"}\n"
        try harness.send(later)
        #expect(await eventually { harness.toClient.data == Data(later.utf8) })

        harness.proxy.stop()
        _ = await running.value
    }

    @Test("running a proxy a second time returns at once")
    func runsOnce() async {
        let harness = Harness()
        defer { harness.close() }
        harness.proxy.stop()
        _ = await harness.proxy.run()
        guard case .stopped = await harness.proxy.run() else {
            Issue.record("expected stopped")
            return
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
