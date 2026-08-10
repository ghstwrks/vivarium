import Foundation

/// Process-wide logger.
///
/// Writes every line to stderr so that stdout stays available for structured
/// output, and mirrors the same lines into a per-run log file once a bundle
/// exists. Secrets never reach this type: callers redact before logging.
final class Logger: @unchecked Sendable {
    static let shared = Logger()

    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private let start = ContinuousClock.now

    // `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the latter
    // is not `Sendable`, so it cannot be a shared constant under Swift 6.
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private init() {}

    /// Starts mirroring output into `url`. Safe to call more than once; the
    /// previous destination is closed first.
    func attachFile(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.close()
        fileHandle = nil

        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        fileHandle = handle
    }

    func detachFile() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.close()
        fileHandle = nil
    }

    func info(_ message: String) { emit(level: "INFO ", message: message) }
    func warn(_ message: String) { emit(level: "WARN ", message: message) }
    func error(_ message: String) { emit(level: "ERROR", message: message) }
    func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["VIV_DEBUG"] != nil else { return }
        emit(level: "DEBUG", message: message)
    }

    private func emit(level: String, message: String) {
        // Both the wall-clock stamp and the monotonic offset are recorded: the
        // former to correlate with system logs, the latter because install
        // progress is only meaningful as a duration.
        let elapsed = ContinuousClock.now - start
        let line = String(
            format: "%@ %@ [+%8.3fs] %@\n",
            Date().formatted(Self.timestampStyle),
            level,
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            message
        )
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(data)
        try? fileHandle?.write(contentsOf: data)
    }
}

let log = Logger.shared
