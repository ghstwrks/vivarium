import Foundation
import Testing

@testable import Vivarium

/// Runs `command` through a POSIX shell and returns what it wrote to stdout.
///
/// The escaping is asserted against a real shell rather than against an
/// expected string: what matters is not how a value is spelled but that the
/// shell reads it back unchanged.
private func shellStdout(_ command: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

@Suite("Shell quoting")
struct ShellEscapingTests {
    @Test("an ordinary value is wrapped in single quotes")
    func quotesOrdinaryValue() {
        #expect(ShellEscaping.singleQuoted("hello") == "'hello'")
    }

    @Test("an embedded single quote is closed, escaped, and reopened")
    func escapesEmbeddedQuote() {
        #expect(ShellEscaping.singleQuoted("it's") == #"'it'\''s'"#)
    }

    @Test("a shell reads back exactly what was quoted", arguments: [
        "hello",
        "it's",
        "a b\tc",
        "$HOME",
        "`whoami`",
        "$(whoami)",
        #"'; echo pwned; '"#,
        #"" ; rm -rf / ; ""#,
        "back\\slash",
        "new\nline",
        "🐚 unicode",
        "",
    ])
    func roundTripsThroughAShell(_ value: String) throws {
        let output = try shellStdout("printf %s \(ShellEscaping.singleQuoted(value))")
        #expect(output == value)
    }

    @Test("a quoted value stays one word however many spaces it holds")
    func staysOneWord() throws {
        let value = "one two three"
        let output = try shellStdout("set -- \(ShellEscaping.singleQuoted(value)); echo $#")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("an injected command is data, not a command")
    func neverExecutesInjectedCommand() throws {
        // The value below closes the quoting and starts a new command in any
        // implementation that merely wraps it in quotes.
        let hostile = #"'; echo INJECTED; echo '"#
        let output = try shellStdout("printf %s \(ShellEscaping.singleQuoted(hostile))")
        #expect(output == hostile)
    }
}

@Suite("Remote commands")
struct RemoteCommandTests {
    @Test("the script travels as base64, so only the encoding needs quoting")
    func encodesScript() {
        // Base64 is alphanumeric plus `+/=`, so one layer of single quotes is
        // provably enough through the local shell, ssh's own concatenation,
        // and the remote shell.
        let command = ShellEscaping.base64RemoteCommand(script: "echo hello", shell: "/bin/zsh")
        #expect(command.contains(Data("echo hello".utf8).base64EncodedString()))
        #expect(command.contains("/usr/bin/base64 -d"))
        #expect(command.hasSuffix("/bin/zsh -s"))
    }

    @Test("each guest's own shell runs the script")
    func namesTheGuestShell() {
        // A Fedora guest has no zsh, which is why the shell is a parameter
        // rather than a constant.
        #expect(ShellEscaping.base64RemoteCommand(script: "true", shell: "/bin/bash").hasSuffix("/bin/bash -s"))
    }

    @Test("a script full of quoting hazards survives the trip")
    func survivesHazardousScript() throws {
        let script = """
            printf %s 'single' && printf %s "double" && printf %s $(echo substituted)
            """
        let command = ShellEscaping.base64RemoteCommand(script: script, shell: "/bin/sh")
        #expect(try shellStdout(command) == "singledoublesubstituted")
    }

    @Test("a script's own newlines are preserved")
    func preservesNewlines() throws {
        let command = ShellEscaping.base64RemoteCommand(
            script: "printf a\nprintf b\n", shell: "/bin/sh"
        )
        #expect(try shellStdout(command) == "ab")
    }
}
