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
    ///
    /// - Parameters:
    ///   - onStdout: called with each chunk of standard output as it arrives,
    ///     on a background queue. Given for a command whose output is echoed
    ///     live; the chunk is still accumulated into the result either way, so
    ///     a handler never has to reassemble the stream itself.
    ///   - onStderr: the same, for standard error.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeout: Duration? = nil,
        redactedArguments: [String]? = nil,
        stage: VivStage,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
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

        // Installed before `run()`, never after. Foundation delivers termination
        // exactly once, and a handler attached afterwards races the child: a
        // short-lived process can exit first, and the notification is then lost
        // with nothing left to wake the waiter.
        let exited = TerminationLatch()
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw VivError(
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

        async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading, onChunk: onStdout)
        async let stderrData = readToEnd(stderrPipe.fileHandleForReading, onChunk: onStderr)

        let timedOut = await waitForExit(process, exited: exited, timeout: timeout)

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
        stage: VivStage,
        inspectionHints: [String] = []
    ) async throws -> CommandResult {
        let result = try await run(
            executable, arguments,
            environment: environment,
            timeout: timeout,
            stage: stage
        )
        guard result.succeeded else {
            throw VivError(
                stage,
                "\(executable) \(arguments.joined(separator: " ")) failed: \(result.summary)\n"
                    + "  stdout: \(result.stdoutText.trimmed(to: 2000))\n"
                    + "  stderr: \(result.stderrText.trimmed(to: 2000))",
                inspectionHints: inspectionHints
            )
        }
        return result
    }

    /// Drains a pipe to EOF, handing every chunk onwards as it arrives.
    ///
    /// Read incrementally rather than with `readToEnd()` so that a caller
    /// echoing the guest's output sees it during the command rather than after
    /// it. `read(upToCount:)` returns nil at EOF and, unlike `availableData`,
    /// reports a failed read as a Swift error instead of an Objective-C
    /// exception.
    private static func readToEnd(
        _ handle: FileHandle,
        onChunk: (@Sendable (Data) -> Void)? = nil
    ) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var collected = Data()
                while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    collected.append(chunk)
                    onChunk?(chunk)
                }
                try? handle.close()
                continuation.resume(returning: collected)
            }
        }
    }

    /// Applied whenever a caller passes no timeout of its own.
    ///
    /// Every subprocess Vivarium runs is a quick query or a `diskutil`
    /// operation measured in seconds. An unbounded wait has no legitimate use
    /// here and turns any surprise into a run that hangs until someone notices.
    static let defaultTimeout = Duration.seconds(600)

    /// Waits for the process, terminating it if `timeout` elapses first.
    /// Returns whether the timeout fired.
    private static func waitForExit(
        _ process: Process,
        exited: TerminationLatch,
        timeout: Duration?
    ) async -> Bool {
        let deadline = timeout ?? defaultTimeout
        let didTimeOut = AtomicFlag()
        let killer = Task {
            try await Task.sleep(for: deadline)
            guard process.isRunning else { return }
            didTimeOut.set()
            log.warn("Process \(process.processIdentifier) exceeded its timeout; sending SIGTERM.")
            process.terminate()
            try await Task.sleep(for: .seconds(5))
            guard process.isRunning else { return }
            log.warn("Process \(process.processIdentifier) ignored SIGTERM; sending SIGKILL.")
            kill(process.processIdentifier, SIGKILL)
        }

        await exited.wait()
        killer.cancel()
        return didTimeOut.value
    }
}

/// A one-shot gate between Foundation's termination callback and the waiting
/// task.
///
/// This replaces `Process.waitUntilExit()`, which is a run-loop poll performed
/// on whichever thread calls it. If the child exits before that thread has
/// installed its wakeup source the event is lost and the thread blocks in
/// `mach_msg` forever — observed here as a run that sat in address discovery
/// for over two hours with no child process alive, no pipes open, and a
/// ten-minute timeout that could never fire because it is only evaluated
/// between loop iterations. Being edge-triggered by the termination handler
/// rather than polling removes the race: `signal()` is safe whether it lands
/// before or after `wait()`.
final class TerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var hasExited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        guard !hasExited else { return lock.unlock() }
        hasExited = true
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if hasExited {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
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
