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
    /// The process's standard output — all of it, unless the caller passed an
    /// `outputLimit`, in which case only its last bytes.
    let stdout: Data
    let stderr: Data
    /// How many bytes the process actually produced, which is what `stdout`
    /// holds only when nothing was dropped.
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let exitCode: Int32
    let terminationReason: Process.TerminationReason
    let timedOut: Bool
    let startedAt: Date
    let endedAt: Date

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    var stdoutTruncated: Bool { stdoutByteCount > stdout.count }
    var stderrTruncated: Bool { stderrByteCount > stderr.count }
    var succeeded: Bool { exitCode == 0 && terminationReason == .exit && !timedOut }
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// A one-line summary safe to log.
    var summary: String {
        let reason = terminationReason == .exit ? "exit" : "uncaughtSignal"
        func describe(_ name: String, _ total: Int, _ kept: Int) -> String {
            total > kept ? "\(name) \(total)B (last \(kept)B kept)" : "\(name) \(total)B"
        }
        return "\(executable) \(redactedArguments.joined(separator: " ")) -> "
            + "\(reason) \(exitCode), "
            + describe("stdout", stdoutByteCount, stdout.count) + ", "
            + describe("stderr", stderrByteCount, stderr.count)
            + (timedOut ? ", TIMED OUT" : "")
    }
}

/// A `Codable` projection of `CommandResult` for the run's result files.
///
/// `Process.TerminationReason` is not `Codable` and raw `Data` in JSON is
/// base64 noise, so the report carries a decoded text view alongside byte
/// counts and a digest of each stream. Only for a result captured in full: a
/// digest of a tail would claim to identify the whole stream.
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
        stdoutByteCount = result.stdoutByteCount
        stderrByteCount = result.stderrByteCount
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
    ///   - outputLimit: the most of each stream to keep in the result, in
    ///     bytes; the last such bytes are kept and the rest are dropped as they
    ///     go past. Given by a caller that is already writing the stream
    ///     somewhere durable and only wants a tail to reason about — without
    ///     it, a chatty child is held in this process's memory in its entirety,
    ///     next to a running virtual machine.
    ///   - onStdout: called with each chunk of standard output as it arrives,
    ///     on a background queue. Given for a command whose output is echoed
    ///     live; every chunk is handed over whole, whatever `outputLimit` says,
    ///     so a handler never has to reassemble the stream itself.
    ///   - onStderr: the same, for standard error.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeout: Duration? = nil,
        redactedArguments: [String]? = nil,
        stage: VivStage,
        outputLimit: Int? = nil,
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
        let exited = OneShot<Void>()
        process.terminationHandler = { _ in exited.fulfil(()) }

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

        async let stdoutData = readToEnd(
            stdoutPipe.fileHandleForReading, limit: outputLimit, onChunk: onStdout
        )
        async let stderrData = readToEnd(
            stderrPipe.fileHandleForReading, limit: outputLimit, onChunk: onStderr
        )

        let timedOut = await waitForExit(process, exited: exited, timeout: timeout)

        let out = await stdoutData
        let err = await stderrData

        let result = CommandResult(
            executable: executable,
            redactedArguments: redactedArguments ?? arguments,
            stdout: out.kept,
            stderr: err.kept,
            stdoutByteCount: out.totalByteCount,
            stderrByteCount: err.totalByteCount,
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

    /// What a drained pipe produced, and how much of it was kept.
    private struct DrainedStream: Sendable {
        let kept: Data
        let totalByteCount: Int
    }

    /// Drains a pipe to EOF, handing every chunk onwards as it arrives.
    ///
    /// Read incrementally rather than with `readToEnd()` so that a caller
    /// echoing the guest's output sees it during the command rather than after
    /// it. `read(upToCount:)` returns nil at EOF and, unlike `availableData`,
    /// reports a failed read as a Swift error instead of an Objective-C
    /// exception.
    ///
    /// With a `limit`, the oldest bytes are dropped as newer ones arrive rather
    /// than the newest being refused: what a caller wants from a stream it did
    /// not keep is the end of it — the error, the last thing that happened —
    /// and the beginning is the part it can most easily do without.
    private static func readToEnd(
        _ handle: FileHandle,
        limit: Int?,
        onChunk: (@Sendable (Data) -> Void)? = nil
    ) async -> DrainedStream {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var collected = Data()
                var total = 0
                while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    total += chunk.count
                    collected.append(chunk)
                    if let limit, collected.count > limit {
                        collected.removeFirst(collected.count - limit)
                    }
                    onChunk?(chunk)
                }
                try? handle.close()
                continuation.resume(
                    returning: DrainedStream(kept: collected, totalByteCount: total)
                )
            }
        }
    }

    /// Applied whenever a caller passes no timeout of its own.
    ///
    /// Every subprocess Vivarium runs is a quick query or a `diskutil`
    /// operation measured in seconds. An unbounded wait has no legitimate use
    /// here and turns any surprise into a run that hangs until someone notices.
    static let defaultTimeout = Duration.seconds(600)

    /// How long a process is given to act on SIGTERM before it is sent SIGKILL.
    static let terminationGrace = Duration.seconds(5)

    /// Waits for the process, terminating it if `timeout` elapses first.
    /// Returns whether the timeout fired.
    private static func waitForExit(
        _ process: Process,
        exited: OneShot<Void>,
        timeout: Duration?
    ) async -> Bool {
        let deadline = timeout ?? defaultTimeout
        let didTimeOut = AtomicFlag()
        let killer = Task {
            try await Task.sleep(for: deadline)
            guard process.isRunning else { return }
            didTimeOut.set()
            log.warn("Process \(process.processIdentifier) exceeded its timeout; sending SIGTERM.")
            try await sendTerminationSignals(to: process, grace: terminationGrace)
        }

        await exited.waitIgnoringCancellation()
        killer.cancel()
        return didTimeOut.value
    }

    /// Sends SIGTERM, then SIGKILL if the process is still running once
    /// `grace` has passed.
    ///
    /// Returns when the signals have been sent, not when the process has
    /// exited; the caller awaits the exit itself and cancels this once it has
    /// seen it, which ends the grace period early.
    fileprivate static func sendTerminationSignals(to process: Process, grace: Duration) async throws {
        guard process.isRunning else { return }
        process.terminate()
        try await Task.sleep(for: grace)
        guard process.isRunning else { return }
        log.warn("Process \(process.processIdentifier) ignored SIGTERM; sending SIGKILL.")
        kill(process.processIdentifier, SIGKILL)
    }
}

extension ProcessRunner {
    /// Starts `executable` and returns as soon as it is running, handing the
    /// child to the caller rather than waiting for it.
    ///
    /// For a child that lives as long as the caller decides, such as one
    /// serving a protocol over the streams it is given. Unlike `run`, nothing
    /// here imposes a timeout, creates a pipe, or nulls standard input: each
    /// stream is connected exactly as the caller says.
    static func spawn(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        standardInput: ChildStream,
        standardOutput: ChildStream,
        standardError: ChildStream,
        redactedArguments: [String]? = nil,
        stage: VivStage
    ) throws -> SpawnedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let stream = standardInput.processValue { process.standardInput = stream }
        if let stream = standardOutput.processValue { process.standardOutput = stream }
        if let stream = standardError.processValue { process.standardError = stream }

        let description = ([executable] + (redactedArguments ?? arguments)).joined(separator: " ")
        let exited = OneShot<ProcessExit>()
        let terminationRequested = AtomicFlag()
        // Installed before `run()` for the same reason as in `run`: a child
        // that exits at once would otherwise never be observed to exit.
        process.terminationHandler = { ended in
            let exit = ProcessExit(
                status: ended.terminationStatus,
                reason: ended.terminationReason,
                wasTerminated: terminationRequested.value
            )
            log.debug("\(description) -> \(exit)")
            exited.fulfil(exit)
        }

        do {
            try process.run()
        } catch {
            throw VivError(stage, "Failed to launch \(executable).", underlying: error)
        }

        return SpawnedProcess(
            process: process,
            description: description,
            exited: exited,
            terminationRequested: terminationRequested
        )
    }
}

/// Where one of a spawned child's standard streams is connected.
enum ChildStream {
    /// The same stream this process has.
    case inherited
    /// `/dev/null`.
    case nullDevice
    /// A file handle the caller opened and keeps: the child gets a duplicate
    /// of its descriptor, so the caller's copy stays open until it closes it.
    case fileHandle(FileHandle)
    /// A pipe whose other end the caller reads or writes. The child's end is
    /// closed in this process once the child has launched, so closing the
    /// caller's end of a standard-input pipe delivers EOF to the child.
    case pipe(Pipe)

    /// What `Process` expects for this stream, or `nil` to keep its default,
    /// which is inheritance.
    fileprivate var processValue: Any? {
        switch self {
        case .inherited: return nil
        case .nullDevice: return FileHandle.nullDevice
        case let .fileHandle(handle): return handle
        case let .pipe(pipe): return pipe
        }
    }
}

/// How a spawned child ended.
struct ProcessExit: Sendable, Equatable, CustomStringConvertible {
    /// The exit code, or the signal number when `reason` is `.uncaughtSignal`.
    let status: Int32
    let reason: Process.TerminationReason
    /// Whether `SpawnedProcess.terminate()` had been called by the time the
    /// child ended, which tells an exit the holder caused from one it did not.
    let wasTerminated: Bool

    var succeeded: Bool { reason == .exit && status == 0 }

    var description: String {
        (reason == .exit ? "exit \(status)" : "signal \(status)")
            + (wasTerminated ? " (terminated)" : "")
    }
}

/// A child started by `ProcessRunner.spawn`, owned by whoever holds this.
///
/// The child's lifetime is not bound to this object or to any task: dropping
/// the handle, or cancelling a task waiting on it, leaves the child running.
/// The holder ends it with `terminate()`, or learns from `wait()` that it
/// ended on its own.
final class SpawnedProcess: Sendable {
    let pid: pid_t
    /// The executable and its redacted arguments, for log lines.
    let description: String

    private let process: Process
    private let exited: OneShot<ProcessExit>
    private let terminationRequested: AtomicFlag

    fileprivate init(
        process: Process,
        description: String,
        exited: OneShot<ProcessExit>,
        terminationRequested: AtomicFlag
    ) {
        self.process = process
        self.pid = process.processIdentifier
        self.description = description
        self.exited = exited
        self.terminationRequested = terminationRequested
    }

    /// Whether the child has yet to be observed to exit. Never suspends.
    var isRunning: Bool { exited.value == nil }

    /// How the child ended, or `nil` while it is still running. Never suspends.
    var exit: ProcessExit? { exited.value }

    /// Waits for the child to exit.
    ///
    /// Returns `nil` if the waiting task is cancelled first, which makes this
    /// safe to race against other events in a task group; the child itself is
    /// unaffected. Safe to call repeatedly, and after the child has exited.
    func wait() async -> ProcessExit? {
        await exited.wait()
    }

    /// Stops the child and waits for it to exit: SIGTERM, then SIGKILL if it
    /// is still running after `grace`.
    ///
    /// The signals are sent from a task of their own, so cancelling the caller
    /// does not interrupt the escalation. Returns at once if the child has
    /// already exited.
    @discardableResult
    func terminate(grace: Duration = ProcessRunner.terminationGrace) async -> ProcessExit {
        if let exit { return exit }
        terminationRequested.set()
        log.info("Stopping process \(pid) (\(description)); sending SIGTERM.")
        let process = self.process
        let escalation = Task {
            try await ProcessRunner.sendTerminationSignals(to: process, grace: grace)
        }
        guard let exit = await exited.waitIgnoringCancellation() else {
            preconditionFailure("a spawned process's exit latch is never closed")
        }
        escalation.cancel()
        return exit
    }
}

/// A one-way boolean shared between tasks and callbacks.
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
