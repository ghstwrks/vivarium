import Foundation
import Testing

@testable import Vivarium

@Suite("Long-lived SSH sessions")
struct SSHSessionTests {
    let runner = SSHCommandRunner(
        username: "vivadmin",
        authentication: .password("hunter2-not-on-the-command-line"),
        address: "192.168.64.5",
        knownHostsFile: URL(fileURLWithPath: "/tmp/known_hosts")
    )

    @Test("a session refuses a terminal and keeps the connection alive, before the destination")
    func sessionOptions() throws {
        let (arguments, _) = runner.commandLine(
            remoteCommand: "/usr/bin/safaridriver --mcp",
            extraOptions: SSHCommandRunner.sessionOptions
        )
        #expect(Array(arguments.suffix(2)) == ["vivadmin@192.168.64.5", "/usr/bin/safaridriver --mcp"])
        let options = Array(arguments.dropLast(2))
        #expect(options.contains("-T"))
        #expect(options.contains("ServerAliveInterval=15"))
        #expect(options.contains("ServerAliveCountMax=4"))
        #expect(options.contains("UserKnownHostsFile=/tmp/known_hosts"))
        #expect(options.contains("StrictHostKeyChecking=accept-new"))
    }

    @Test("a one-shot command line carries no session options")
    func oneShotUnchanged() {
        let (arguments, _) = runner.commandLine(remoteCommand: "/usr/bin/id -un")
        #expect(!arguments.contains("-T"))
        #expect(!arguments.contains("ServerAliveInterval=15"))
    }

    @Test("the redacted vector replaces only the command, and neither carries the password")
    func redaction() {
        let (arguments, redacted) = runner.commandLine(
            remoteCommand: "secret script", redactedCommand: "<script>",
            extraOptions: SSHCommandRunner.sessionOptions
        )
        #expect(redacted.last == "<script>")
        #expect(Array(redacted.dropLast()) == Array(arguments.dropLast()))
        #expect(!(arguments + redacted).contains { $0.contains("hunter2") })
    }
}
