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

struct SSHCommandRunner: Sendable {
    let username: String
    let authentication: GuestAuthentication
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
        stdinData: Data?,
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
    ///
    /// `outputLimit` caps what the result carries, for a caller that is keeping
    /// the streams itself; the handlers still see every byte.
    func runStreaming(
        remoteCommand: String,
        timeout: Duration,
        redactedCommand: String? = nil,
        outputLimit: Int? = nil,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void
    ) async throws -> SSHResult {
        try await invoke(
            remoteCommand: remoteCommand,
            timeout: timeout,
            redactedCommand: redactedCommand,
            outputLimit: outputLimit,
            onStdout: onStdout,
            onStderr: onStderr
        )
    }

    private func invoke(
        remoteCommand: String,
        stdinData: Data? = nil,
        timeout: Duration,
        redactedCommand: String?,
        outputLimit: Int? = nil,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> SSHResult {
        let (helper, environment) = try makeAskpass()
        defer { helper?.remove() }

        let (arguments, redacted) = commandLine(
            remoteCommand: remoteCommand, redactedCommand: redactedCommand
        )

        let result = try await ProcessRunner.run(
            "/usr/bin/ssh", arguments,
            environment: environment,
            stdinData: stdinData,
            timeout: timeout,
            redactedArguments: redacted,
            stage: .sshCommand,
            outputLimit: outputLimit,
            onStdout: onStdout,
            onStderr: onStderr
        )

        return SSHResult(outcome: Self.classify(result), command: result)
    }

    /// What a long-lived session adds to every other invocation's options.
    ///
    /// `-T` refuses a pseudo-terminal, which would rewrite the bytes of a
    /// protocol carried over the streams. The keepalives end a session whose
    /// guest has gone silent within about a minute, rather than leaving it
    /// waiting on a connection that will never answer.
    static let sessionOptions = [
        "-T",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4"
    ]

    /// Starts `remoteCommand` in the guest and returns while it runs, with
    /// each of ssh's streams connected as the caller says.
    ///
    /// For a guest program that serves for as long as the caller decides.
    /// The askpass helper a password needs stays on disk until the child
    /// exits, rather than for one call.
    func spawnSession(
        remoteCommand: String,
        standardInput: ChildStream,
        standardOutput: ChildStream,
        standardError: ChildStream,
        redactedCommand: String? = nil,
        stage: VivStage
    ) throws -> SSHSession {
        let (helper, environment) = try makeAskpass()
        let (arguments, redacted) = commandLine(
            remoteCommand: remoteCommand,
            redactedCommand: redactedCommand,
            extraOptions: Self.sessionOptions
        )
        let process: SpawnedProcess
        do {
            process = try ProcessRunner.spawn(
                "/usr/bin/ssh", arguments,
                environment: environment,
                standardInput: standardInput,
                standardOutput: standardOutput,
                standardError: standardError,
                redactedArguments: redacted,
                stage: stage
            )
        } catch {
            helper?.remove()
            throw error
        }
        return SSHSession(process: process, askpass: helper)
    }

    /// The askpass helper and environment this runner's credential needs,
    /// if it needs one.
    private func makeAskpass() throws -> (AskpassHelper?, [String: String]?) {
        guard case let .password(password) = authentication else { return (nil, nil) }
        let helper = try AskpassHelper()
        return (helper, helper.environment(password: password))
    }

    /// ssh's argument vector for `remoteCommand`, and the same vector with
    /// the command replaced by `redactedCommand` for logs.
    func commandLine(
        remoteCommand: String,
        redactedCommand: String? = nil,
        extraOptions: [String] = []
    ) -> (arguments: [String], redacted: [String]) {
        let base = extraOptions + Self.baseArguments(
            knownHostsFile: knownHostsFile, authentication: authentication
        )
        let destination = "\(username)@\(address)"
        return (
            base + [destination, remoteCommand],
            base + [destination, redactedCommand ?? remoteCommand]
        )
    }

    private static func baseArguments(
        knownHostsFile: URL,
        authentication: GuestAuthentication
    ) -> [String] {
        var arguments = [
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            // accept-new records the guest's key on first contact but still
            // refuses a *changed* key. Host-key checking is never disabled
            // globally; the per-run file keeps a reused address from poisoning
            // the operator's own known_hosts.
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "LogLevel=ERROR"
        ]

        switch authentication {
        case .password:
            arguments += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "BatchMode=no",
                "-o", "NumberOfPasswordPrompts=1"
            ]
        case let .privateKey(path, _):
            arguments += [
                "-i", path.path,
                "-o", "PreferredAuthentications=publickey",
                "-o", "IdentitiesOnly=yes",
                "-o", "PasswordAuthentication=no",
                "-o", "BatchMode=yes"
            ]
        case .unavailable:
            arguments += ["-o", "BatchMode=yes"]
        }
        return arguments
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

/// A long-lived ssh child started by `SSHCommandRunner.spawnSession`, and
/// the askpass helper that authenticated it.
///
/// The helper is removed once the child is observed to exit, whether the
/// holder stopped it or it ended on its own.
final class SSHSession: Sendable {
    let process: SpawnedProcess
    private let askpass: AskpassHelper?

    fileprivate init(process: SpawnedProcess, askpass: AskpassHelper?) {
        self.process = process
        self.askpass = askpass
        if let askpass {
            Task.detached {
                _ = await process.wait()
                askpass.remove()
            }
        }
    }

    /// Waits for ssh to exit. Returns `nil` if the waiting task is cancelled
    /// first; the child is unaffected.
    func wait() async -> ProcessExit? {
        await process.wait()
    }

    /// Stops ssh and waits for it to exit, removing the askpass helper
    /// before returning.
    @discardableResult
    func terminate() async -> ProcessExit {
        let exit = await process.terminate()
        askpass?.remove()
        return exit
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
