import Foundation

/// The complete result of running a subprocess.
///
/// `stdout` and `stderr` are kept as raw bytes and never merged: the acceptance
/// test asserts on distinct tokens arriving on distinct streams, so collapsing
/// them would destroy the thing being proved.
struct CommandResult: Sendable {
    let executable: String
    /// Arguments with secrets already removed. Nothing else is ever logged.
    let redactedArguments: [String]
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    let terminationReason: Process.TerminationReason
    let timedOut: Bool
    let startedAt: Date
    let endedAt: Date

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    var succeeded: Bool { exitCode == 0 && terminationReason == .exit && !timedOut }
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// A one-line summary safe to log.
    var summary: String {
        let reason = terminationReason == .exit ? "exit" : "uncaughtSignal"
        return "\(executable) \(redactedArguments.joined(separator: " ")) -> "
            + "\(reason) \(exitCode), stdout \(stdout.count)B, stderr \(stderr.count)B"
            + (timedOut ? ", TIMED OUT" : "")
    }
}

/// A `Codable` projection of `CommandResult` for the run's result files.
///
/// `Process.TerminationReason` is not `Codable` and raw `Data` in JSON is
/// base64 noise, so the report carries a decoded text view alongside byte
/// counts and a digest of each stream.
struct CommandResultReport: Codable, Sendable {
    let executable: String
    let redactedArguments: [String]
    let stdoutText: String
    let stderrText: String
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let stdoutSHA256: String
    let stderrSHA256: String
    let exitCode: Int32
    let terminationReason: String
    let timedOut: Bool
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double

    init(_ result: CommandResult) {
        executable = result.executable
        redactedArguments = result.redactedArguments
        stdoutText = result.stdoutText
        stderrText = result.stderrText
        stdoutByteCount = result.stdout.count
        stderrByteCount = result.stderr.count
        stdoutSHA256 = Digest.sha256Hex(result.stdout)
        stderrSHA256 = Digest.sha256Hex(result.stderr)
        exitCode = result.exitCode
        terminationReason = result.terminationReason == .exit ? "exit" : "uncaughtSignal"
        timedOut = result.timedOut
        startedAt = result.startedAt
        endedAt = result.endedAt
        durationSeconds = result.duration
    }
}

enum ProcessRunner {
    /// Runs `executable` and returns its complete output.
    ///
    /// Both pipes are drained concurrently for the lifetime of the process.
    /// Reading one only after the process exits deadlocks as soon as the other
    /// fills its 64 KiB buffer, which is easy to hit with a verbose `ssh -v`.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeout: Duration? = nil,
        redactedArguments: [String]? = nil,
        stage: POCStage
    ) async throws -> CommandResult {
        let startedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if let stdinData {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
            _ = stdinData
        } else {
            // Never leave stdin attached to the terminal: ssh would fall back to
            // interactive password entry and hang the run.
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        do {
            try process.run()
        } catch {
            throw POCError(
                stage,
                "Failed to launch \(executable).",
                underlying: error
            )
        }

        if let stdinPipe, let stdinData {
            // Written on a background queue: a large payload would otherwise
            // block here until the child drains it.
            let handle = stdinPipe.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                try? handle.write(contentsOf: stdinData)
                try? handle.close()
            }
        }

        async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = readToEnd(stderrPipe.fileHandleForReading)

        let timedOut = await waitForExit(process, timeout: timeout)

        let out = await stdoutData
        let err = await stderrData

        let result = CommandResult(
            executable: executable,
            redactedArguments: redactedArguments ?? arguments,
            stdout: out,
            stderr: err,
            exitCode: process.terminationStatus,
            terminationReason: process.terminationReason,
            timedOut: timedOut,
            startedAt: startedAt,
            endedAt: Date()
        )
        log.debug(result.summary)
        return result
    }

    /// Runs a command and throws unless it exits zero.
    @discardableResult
    static func runChecked(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration? = nil,
        stage: POCStage,
        inspectionHints: [String] = []
    ) async throws -> CommandResult {
        let result = try await run(
            executable, arguments,
            environment: environment,
            timeout: timeout,
            stage: stage
        )
        guard result.succeeded else {
            throw POCError(
                stage,
                "\(executable) \(arguments.joined(separator: " ")) failed: \(result.summary)\n"
                    + "  stdout: \(result.stdoutText.trimmed(to: 2000))\n"
                    + "  stderr: \(result.stderrText.trimmed(to: 2000))",
                inspectionHints: inspectionHints
            )
        }
        return result
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                try? handle.close()
                continuation.resume(returning: data)
            }
        }
    }

    /// Waits for the process, terminating it if `timeout` elapses first.
    /// Returns whether the timeout fired.
    private static func waitForExit(_ process: Process, timeout: Duration?) async -> Bool {
        guard let timeout else {
            await blockingWait(process)
            return false
        }

        let didTimeOut = AtomicFlag()
        let killer = Task {
            try await Task.sleep(for: timeout)
            guard process.isRunning else { return }
            didTimeOut.set()
            log.warn("Process \(process.processIdentifier) exceeded its timeout; sending SIGTERM.")
            process.terminate()
            try await Task.sleep(for: .seconds(5))
            guard process.isRunning else { return }
            log.warn("Process \(process.processIdentifier) ignored SIGTERM; sending SIGKILL.")
            kill(process.processIdentifier, SIGKILL)
        }

        await blockingWait(process)
        killer.cancel()
        return didTimeOut.value
    }

    private static func blockingWait(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

/// A one-way boolean shared between the waiting task and the timeout task.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

extension String {
    /// Truncates for logging so a runaway subprocess cannot flood the log.
    func trimmed(to limit: Int) -> String {
        let compact = trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "… (\(compact.count - limit) more characters)"
    }
}
