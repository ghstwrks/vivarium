import Foundation

/// Splits a byte stream into lines as the bytes arrive, keeping the whole
/// stream as well.
///
/// A run's stdout has two jobs that pull in opposite directions: it has to
/// reach the operator's terminal while the test is still running, and it has to
/// be written to `results/test-stdout.txt` byte-for-byte afterwards. Chunks
/// from a pipe respect neither line nor UTF-8 boundaries, so the raw bytes are
/// accumulated untouched and a separate buffer emits only complete lines.
///
/// The instance outlives the command deliberately: an attempt abandoned on
/// timeout leaves its partial output here, where the caller can still report
/// it, rather than in a task nobody holds.
final class LineStream: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var collected = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    /// Everything received so far.
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    /// Called from the pipe-draining queue for each chunk.
    func append(_ chunk: Data) {
        lock.lock()
        collected.append(chunk)
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending = pending[pending.index(after: newline)...]
        }
        lock.unlock()

        // Emitted outside the lock: the handler writes to a file handle, and
        // holding this lock across that write would serialise the two streams
        // against each other for no benefit.
        for line in lines { onLine(line) }
    }

    /// Flushes a trailing line that never ended in a newline.
    ///
    /// A command whose last write is `printf 'no newline'` still said
    /// something, and dropping it would make the terminal disagree with the
    /// captured file.
    func finish() {
        lock.lock()
        let remainder = pending
        pending = Data()
        lock.unlock()
        guard !remainder.isEmpty else { return }
        onLine(String(decoding: remainder, as: UTF8.self))
    }
}

/// Echoes the guest's output to the host terminal, line by line.
///
/// Each stream keeps its identity: the guest's stdout is written to the host's
/// stdout and its stderr to the host's stderr, so `viv run > out.txt 2> err.txt`
/// separates them exactly as the guest did. The prefix marks which lines came
/// from inside the VM without hiding the text: it is the one thing on screen
/// that distinguishes a test's own output from Vivarium's.
///
/// Writes are serialised through one lock shared by both streams, because the
/// two pipes are drained on separate queues and a write large enough to be
/// split would otherwise interleave mid-line.
final class GuestEcho: @unchecked Sendable {
    static let prefix = "guest │ "

    private let lock = NSLock()

    func stdout(_ line: String) { write(line, to: FileHandle.standardOutput) }
    func stderr(_ line: String) { write(line, to: FileHandle.standardError) }

    private func write(_ line: String, to handle: FileHandle) {
        let data = Data((Self.prefix + line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }
}
