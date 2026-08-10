import Foundation

/// How an SSH invocation ended, distinguishing transport failure from a remote
/// command that ran and chose its own exit status.
///
/// Collapsing these is the single easiest way to make this proof meaningless:
/// the acceptance test asserts on a *remote* exit code of 23, and a run that
/// reported 23 because the connection failed in some way that happened to
/// produce 23 would prove nothing.
enum SSHOutcome: Sendable, Equatable {
    /// The remote command ran and exited with this status.
    case remoteExit(Int32)
    /// SSH itself failed: transport, authentication, host key, or protocol.
    case transportFailure(String)
    /// The local ssh process was killed, usually by our own timeout.
    case localFailure(String)

    var isTransportFailure: Bool {
        if case .transportFailure = self { return true }
        return false
    }
}

struct SSHResult: Sendable {
    let outcome: SSHOutcome
    let command: CommandResult

    var stdoutText: String { command.stdoutText }
    var stderrText: String { command.stderrText }

    var remoteExitCode: Int32? {
        if case let .remoteExit(code) = outcome { return code }
        return nil
    }
}

/// Runs commands in the guest over the system OpenSSH client.
///
/// `/usr/bin/ssh` needs no library and makes stdout, stderr, and termination
/// status trivially separable through `Process`. The cost is the password:
/// OpenSSH will not read one from an argument or from stdin, so an askpass
/// helper is required. That is acceptable against a NAT-local VM whose
/// credential is generated per run and never persisted; it is not a
/// credential-management design, and the limitations are documented on
/// `AskpassHelper`.
struct SSHCommandRunner: Sendable {
    let username: String
    let password: String
    let address: String
    let knownHostsFile: URL

    /// Runs a command in the guest.
    ///
    /// - Parameter redactedCommand: what to record in logs and result files in
    ///   place of the real command, when the real one is long or sensitive.
    func run(
        remoteCommand: String,
        timeout: Duration,
        redactedCommand: String? = nil
    ) async throws -> SSHResult {
        try await invoke(
            remoteCommand: remoteCommand,
            timeout: timeout,
            redactedCommand: redactedCommand
        )
    }

    /// Runs a command with data on its standard input.
    ///
    /// Used for `sudo -S`, so the password reaches sudo's stdin rather than an
    /// argument vector visible in the guest's process list.
    func run(
        remoteCommand: String,
        stdinData: Data,
        timeout: Duration,
        redactedCommand: String? = nil
    ) async throws -> SSHResult {
        try await invoke(
            remoteCommand: remoteCommand,
            stdinData: stdinData,
            timeout: timeout,
            redactedCommand: redactedCommand
        )
    }

    /// Runs a command, handing its output onwards as it arrives.
    ///
    /// Used for the user's test command, whose output has to reach the host
    /// terminal while the test is still running. No pseudo-terminal is
    /// requested (`ssh -t`), because a tty would merge the two streams into
    /// one and Vivarium promises to capture them separately. The cost is that
    /// a guest program which block-buffers when its output is not a terminal
    /// arrives in bursts rather than lines; that is the program's own choice
    /// and is preferable to losing the distinction between them.
    func runStreaming(
        remoteCommand: String,
        timeout: Duration,
        redactedCommand: String? = nil,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void
    ) async throws -> SSHResult {
        try await invoke(
            remoteCommand: remoteCommand,
            timeout: timeout,
            redactedCommand: redactedCommand,
            onStdout: onStdout,
            onStderr: onStderr
        )
    }

    private func invoke(
        remoteCommand: String,
        stdinData: Data? = nil,
        timeout: Duration,
        redactedCommand: String?,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> SSHResult {
        let helper = try AskpassHelper()
        defer { helper.remove() }

        var arguments = Self.baseArguments(knownHostsFile: knownHostsFile)
        arguments.append("\(username)@\(address)")
        arguments.append(remoteCommand)

        var redacted = Self.baseArguments(knownHostsFile: knownHostsFile)
        redacted.append("\(username)@\(address)")
        redacted.append(redactedCommand ?? remoteCommand)

        let result = try await ProcessRunner.run(
            "/usr/bin/ssh", arguments,
            environment: helper.environment(password: password),
            stdinData: stdinData,
            timeout: timeout,
            redactedArguments: redacted,
            stage: .sshCommand,
            onStdout: onStdout,
            onStderr: onStderr
        )

        return SSHResult(outcome: Self.classify(result), command: result)
    }

    static func baseArguments(knownHostsFile: URL) -> [String] {
        [
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "PubkeyAuthentication=no",
            // accept-new records the guest's key on first contact but still
            // refuses a *changed* key. Host-key checking is never disabled
            // globally; the per-run file keeps a reused address from poisoning
            // the operator's own known_hosts.
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "LogLevel=ERROR",
            "-o", "BatchMode=no",
            "-o", "NumberOfPasswordPrompts=1"
        ]
    }

    /// Separates remote exit statuses from SSH's own failures.
    ///
    /// OpenSSH reserves 255 for its own errors, so a remote command that exits
    /// 255 is indistinguishable from a transport failure. The acceptance test
    /// deliberately uses 23 to stay well clear of that boundary.
    private static func classify(_ result: CommandResult) -> SSHOutcome {
        if result.timedOut {
            return .localFailure("the local ssh process exceeded its timeout and was terminated")
        }
        if result.terminationReason != .exit {
            return .localFailure("the local ssh process was terminated by a signal")
        }
        if result.exitCode == 255 {
            let detail = result.stderrText.trimmed(to: 500)
            return .transportFailure(detail.isEmpty ? "ssh exited 255 with no diagnostics" : detail)
        }
        return .remoteExit(result.exitCode)
    }
}

/// A temporary `SSH_ASKPASS` helper.
///
/// OpenSSH accepts a password only from a terminal or from an askpass program.
/// The helper's contents are a fixed two-line script; the password travels in
/// the child's environment, never in the script, never in an argument vector,
/// and never in a file.
///
/// Limitations, accepted for a single-run per-run credential and not suitable
/// for a password with a longer life:
///  - environment variables are readable by sufficiently privileged local
///    processes;
///  - the helper exists on disk, mode 0700 in a mode-0700 directory, for the
///    duration of one ssh invocation and is removed immediately afterwards.
struct AskpassHelper: Sendable {
    let directory: URL
    let script: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("viv-askpass-\(UUID().uuidString)")
        script = directory.appendingPathComponent("askpass.sh")

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let contents = """
            #!/bin/sh
            printf '%s\\n' "$VIV_SSH_PASSWORD"

            """
            try Data(contents.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: script.path
            )
        } catch {
            throw VivError(.sshCommand, "Failed to create the askpass helper.", underlying: error)
        }
    }

    func environment(password: String) -> [String: String] {
        [
            "SSH_ASKPASS": script.path,
            // Without `force`, OpenSSH only consults the askpass program when
            // it has no controlling terminal, which is not guaranteed here.
            "SSH_ASKPASS_REQUIRE": "force",
            // SSH_ASKPASS is historically gated on DISPLAY being set; the value
            // is never connected to.
            "DISPLAY": "viv",
            "VIV_SSH_PASSWORD": password,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory()
        ]
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
