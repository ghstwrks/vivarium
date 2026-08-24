import Foundation

/// Splits a byte stream into lines as the bytes arrive.
///
/// Chunks from a pipe respect neither line nor UTF-8 boundaries, so a chunk
/// cannot simply be printed: the buffer holds the tail of an unfinished line
/// until the newline that ends it turns up. Only that remainder is held —
/// whoever needs the stream itself keeps it, and keeping a second copy here
/// meant the process held a chatty test's output twice over.
final class LineStream: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    /// Called from the pipe-draining queue for each chunk.
    func append(_ chunk: Data) {
        lock.lock()
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

/// One of the test command's streams, on its way to the terminal and to disk
/// at the same time.
///
/// Every byte is written to `file` as it arrives and echoed a line at a time;
/// nothing is accumulated. A test that prints a gigabyte should cost a
/// gigabyte of disk, not a gigabyte of resident memory in a process that is
/// also hosting a virtual machine. Writing incrementally also preserves output
/// if the run ends before the command does.
///
/// The file is opened before the command starts, so the output of an attempt
/// abandoned on timeout is already on disk: there is nothing left to flush.
final class CapturedStream: @unchecked Sendable {
    private let destination: URL
    private let lines: LineStream
    private let lock = NSLock()
    private var handle: FileHandle?
    private var failure: (any Error)?

    /// Opens `file` for writing, replacing anything already there.
    init(file: URL, onLine: @escaping @Sendable (String) -> Void) throws {
        destination = file
        lines = LineStream(onLine: onLine)
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let opened = try? FileHandle(forWritingTo: file) else {
            throw VivError(
                .testExecution,
                "Cannot open \(file.path) to capture the test command's output.",
                inspectionHints: ["ls -la \(file.deletingLastPathComponent().path)"]
            )
        }
        handle = opened
    }

    /// Called from the pipe-draining queue for each chunk.
    func append(_ chunk: Data) {
        lock.lock()
        // After `finish` there is no file left to write to. A chunk can still
        // arrive: an abandoned attempt is finished while its pipes are still
        // being drained, and the reader has no way of knowing.
        if let handle {
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                failure = failure ?? error
            }
        }
        lock.unlock()

        // Echoed outside the lock, for the reason LineStream gives: the two
        // streams are drained on separate queues and should not wait on each
        // other's file writes.
        lines.append(chunk)
    }

    /// Flushes a trailing line that never ended in a newline and closes the
    /// file.
    func finish() {
        lines.finish()
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    /// A report-ready description of the first write that failed, if one did.
    var warning: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let failure else { return nil }
        return "could not write \(destination.lastPathComponent): " + VivError.describe(failure)
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
