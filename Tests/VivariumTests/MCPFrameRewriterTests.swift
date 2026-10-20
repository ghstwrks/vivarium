import Foundation
import Testing

@testable import Vivarium

@Suite("Rewriting MCP frames")
struct MCPFrameRewriterTests {
    private static let guestDirectory = "/Volumes/My Shared Files/artifacts"
    private static let hostDirectory = "/runs/r1/results/artifacts"

    private func makeRewriter() -> MCPFrameRewriter {
        MCPFrameRewriter(mapping: MCPPathMapping(hostArtifactsDirectory: Self.hostDirectory + "/"))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func arguments(of frame: Data) throws -> [String: Any] {
        let params = try #require(try object(frame)["params"] as? [String: Any])
        return try #require(params["arguments"] as? [String: Any])
    }

    private func call(_ tool: String, id: Int = 1, arguments: String? = nil) -> Data {
        let arguments = arguments.map { ",\"arguments\":\($0)" } ?? ""
        return Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\"\(arguments)}}".utf8)
    }

    private func text(of frame: Data) throws -> String {
        let result = try #require(try object(frame)["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    // MARK: Toward the server

    @Test("a screenshot without a savePath is given one on the share")
    func injectsScreenshotPath() throws {
        let forwarded = makeRewriter().clientToServer(call("screenshot", arguments: "{\"full_page\":true}"))
        let arguments = try arguments(of: forwarded)
        #expect(arguments["savePath"] as? String == "\(Self.guestDirectory)/screenshot-1.png")
        #expect(arguments["full_page"] as? Bool == true)
    }

    @Test("a screenshot with no arguments at all is given a savePath")
    func injectsWhenArgumentsAreMissing() throws {
        let forwarded = makeRewriter().clientToServer(call("screenshot"))
        #expect(try arguments(of: forwarded)["savePath"] as? String == "\(Self.guestDirectory)/screenshot-1.png")
    }

    @Test("get_page_content takes its file extension from the requested format")
    func injectsPageContentPath() throws {
        let rewriter = makeRewriter()
        let expectations = [
            ("{\"format\":\"markdown\"}", "page-content-1.md"),
            ("{\"format\":\"json\"}", "page-content-2.json"),
            ("{\"format\":\"html\"}", "page-content-3.html"),
            ("{\"format\":\"textTree\"}", "page-content-4.txt"),
            ("{}", "page-content-5.txt"),
        ]
        for (arguments, filename) in expectations {
            let forwarded = rewriter.clientToServer(call("get_page_content", arguments: arguments))
            #expect(try self.arguments(of: forwarded)["savePath"] as? String == "\(Self.guestDirectory)/\(filename)")
        }
    }

    @Test("one counter numbers the files of both tools, so names never collide")
    func countsAcrossTools() throws {
        let rewriter = makeRewriter()
        let first = try arguments(of: rewriter.clientToServer(call("screenshot")))
        let second = try arguments(of: rewriter.clientToServer(call("get_page_content", arguments: "{}")))
        #expect(first["savePath"] as? String == "\(Self.guestDirectory)/screenshot-1.png")
        #expect(second["savePath"] as? String == "\(Self.guestDirectory)/page-content-2.txt")
    }

    @Test("a savePath chosen by the client is forwarded byte for byte")
    func keepsClientSavePath() {
        let rewriter = makeRewriter()
        for tool in ["screenshot", "get_page_content"] {
            let request = call(tool, arguments: "{\"savePath\":\"/tmp/mine.out\"}")
            #expect(rewriter.clientToServer(request) == request)
        }
    }

    @Test("frames that are not save requests pass through byte for byte")
    func passesOtherFramesThrough() {
        let rewriter = makeRewriter()
        let frames = [
            "{ \"jsonrpc\" : \"2.0\",\"id\":1,  \"method\":\"initialize\",\"params\":{\"b\":1,\"a\":2.50}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"list_tabs\",\"arguments\":{}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\",\"arguments\":\"oops\"}}",
            "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]",
            "not json at all",
            "{\"truncated\":",
            "",
        ].map { Data($0.utf8) }
        for frame in frames {
            #expect(rewriter.clientToServer(frame) == frame)
        }
    }

    // MARK: Toward the client

    @Test("guest artifact paths in a result become host paths")
    func rewritesSavedPath() throws {
        let response = Data("""
            {"id": 4, "jsonrpc": "2.0", "result": {"content": [{"text": "Saved screenshot to '/Volumes/My Shared Files/artifacts/probe.png' (89.0 kB).", "type": "text"}]}}
            """.utf8)
        let (frame, denial) = makeRewriter().serverToClient(response)
        #expect(denial == nil)
        #expect(try text(of: frame) == "Saved screenshot to '\(Self.hostDirectory)/probe.png' (89.0 kB).")
        #expect(try object(frame)["id"] as? Int == 4)
    }

    @Test("every occurrence in every content item is rewritten, and the slashes stay unescaped")
    func rewritesEveryOccurrence() throws {
        let guest = Self.guestDirectory
        let response = Data("""
            {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"\(guest)/a.txt and \(guest)/b.txt"},{"type":"text","text":"also \(guest)/c.md"}]}}
            """.utf8)
        let (frame, _) = makeRewriter().serverToClient(response)
        let result = try #require(try object(frame)["result"] as? [String: Any])
        let texts = try #require(result["content"] as? [[String: Any]]).compactMap { $0["text"] as? String }
        #expect(texts == [
            "\(Self.hostDirectory)/a.txt and \(Self.hostDirectory)/b.txt",
            "also \(Self.hostDirectory)/c.md",
        ])
        #expect(String(decoding: frame, as: UTF8.self).contains("\\/") == false)
    }

    @Test("a sibling directory that merely shares the prefix is left alone")
    func ignoresSiblingDirectories() {
        let response = Data("""
            {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"/Volumes/My Shared Files/artifacts-old/a.png"}]}}
            """.utf8)
        #expect(makeRewriter().serverToClient(response).frame == response)
    }

    @Test("server frames with nothing to rewrite pass through byte for byte")
    func passesServerFramesThrough() {
        let rewriter = makeRewriter()
        let frames = [
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"/var/folders/x/T/com.apple.WebDriver/a.png\"}]}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"data\":\"hi\"}}",
            "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32601,\"message\":\"nope\"}}",
            "plain text from a chatty server",
        ].map { Data($0.utf8) }
        for frame in frames {
            let (out, denial) = rewriter.serverToClient(frame)
            #expect(out == frame)
            #expect(denial == nil)
        }
    }

    // MARK: Share write failures

    private static let denialResponse = Data("""
        {"id": 5, "jsonrpc": "2.0", "result": {"content": [{"text": "Tool error: Command failed: Failed to write screenshot to '/Volumes/My Shared Files/artifacts/probe.png': You don\\u2019t have permission to save the file \\u201cprobe.png\\u201d in the folder \\u201cartifacts\\u201d.", "type": "text"}], "isError": true}}
        """.utf8)

    @Test("a refused share write is reported with the request that caused it")
    func detectsShareWriteDenial() throws {
        let rewriter = makeRewriter()
        let forwarded = rewriter.clientToServer(call("screenshot", id: 5))
        let (frame, denial) = rewriter.serverToClient(Self.denialResponse)

        let found = try #require(denial)
        #expect(found.requestID == .int(5))
        #expect(found.originalRequest == forwarded)
        #expect(try arguments(of: found.originalRequest)["savePath"] as? String == "\(Self.guestDirectory)/screenshot-1.png")
        #expect(try text(of: frame).contains("\(Self.hostDirectory)/probe.png"))
    }

    @Test("sending the stored request again keeps its savePath and can be denied again")
    func resendKeepsTheSamePath() throws {
        let rewriter = makeRewriter()
        _ = rewriter.clientToServer(call("screenshot", id: 5))
        let denial = try #require(rewriter.serverToClient(Self.denialResponse).shareWriteDenied)

        #expect(rewriter.clientToServer(denial.originalRequest) == denial.originalRequest)
        #expect(rewriter.serverToClient(Self.denialResponse).shareWriteDenied != nil)
    }

    @Test("a denial is reported once per request, and not for unknown ids or other errors")
    func ignoresOtherFailures() {
        let rewriter = makeRewriter()
        #expect(rewriter.serverToClient(Self.denialResponse).shareWriteDenied == nil)

        _ = rewriter.clientToServer(call("screenshot", id: 5))
        #expect(rewriter.serverToClient(Self.denialResponse).shareWriteDenied != nil)
        #expect(rewriter.serverToClient(Self.denialResponse).shareWriteDenied == nil)

        _ = rewriter.clientToServer(call("screenshot", id: 6))
        let other = Data("""
            {"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"Tool error: no such tab"}],"isError":true}}
            """.utf8)
        #expect(rewriter.serverToClient(other).shareWriteDenied == nil)
    }

    @Test("string request identifiers are matched too")
    func matchesStringIdentifiers() throws {
        let rewriter = makeRewriter()
        _ = rewriter.clientToServer(Data(
            "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\"}}".utf8))
        let response = Data(String(decoding: Self.denialResponse, as: UTF8.self)
            .replacingOccurrences(of: "\"id\": 5", with: "\"id\": \"abc\"").utf8)
        #expect(rewriter.serverToClient(response).shareWriteDenied?.requestID == .string("abc"))
    }
}
