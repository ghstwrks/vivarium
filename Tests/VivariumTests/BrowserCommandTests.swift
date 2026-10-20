import Foundation
import Testing

@testable import Vivarium

@Suite("viv browser's command line")
struct BrowserCommandTests {
    @Test("the defaults are a two-hour lifetime and a twenty-minute idle timeout")
    func defaults() throws {
        let command = try BrowserCommand.parse([])
        #expect(command.maxLifetime == 7200)
        #expect(command.idleTimeout == 1200)
        #expect(command.appCommand.isEmpty)
        #expect(command.appPort == nil)
        #expect(command.code == nil)
    }

    @Test("the app under test keeps its own flags after --")
    func trailingCommand() throws {
        let command = try BrowserCommand.parse([
            "--code", "/tmp/project", "--app-port", "5173", "--run-id", "s1",
            "--", "npm", "run", "dev", "--port", "5173"
        ])
        #expect(command.appCommand == ["npm", "run", "dev", "--port", "5173"])
        #expect(command.appPort == 5173)
        #expect(command.code?.path == "/tmp/project")
        #expect(command.runID == "s1")
        #expect(RunCommand.joined(command.appCommand) == "npm run dev --port 5173")
    }

    @Test("the root command dispatches to browser")
    func dispatch() throws {
        let parsed = try Viv.parseAsRoot(["browser", "--max-lifetime", "60", "--idle-timeout", "30"])
        let command = try #require(parsed as? BrowserCommand)
        #expect(command.maxLifetime == 60)
        #expect(command.idleTimeout == 30)
    }

    @Test("a guest without Safari is refused", arguments: ["fedora"])
    func refusesOtherGuests(_ os: String) {
        #expect(throws: (any Error).self) { try BrowserCommand.parse(["--os", os]) }
    }

    @Test("macOS is accepted by name")
    func acceptsMacOS() throws {
        #expect(try BrowserCommand.parse(["--os", "macos"]).os == .macOS)
    }

    @Test(
        "lifetimes, idle timeouts, and ports must make sense",
        arguments: [
            ["--max-lifetime", "0"],
            ["--idle-timeout", "-5"],
            ["--app-port", "0", "--", "npm", "start"],
            ["--app-port", "70000", "--", "npm", "start"],
            ["--app-port", "3000"]
        ]
    )
    func refusesNonsense(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try BrowserCommand.parse(arguments) }
    }

    @Test("the help explains that stdout carries nothing but MCP frames")
    func helpExplainsStdio() {
        let help = BrowserCommand.helpMessage(columns: 200)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(help.contains("newline-delimited JSON-RPC"))
        #expect(help.contains("the server's frames are the only thing written to standard output"))
        #expect(help.contains("go to standard error"))
        #expect(help.contains("--idle-timeout"))
        #expect(help.contains("claude mcp add safari -- viv browser --code . -- npm run dev"))
    }
}
