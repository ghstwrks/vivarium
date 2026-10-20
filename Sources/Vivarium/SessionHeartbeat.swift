import Foundation

/// The file a serving browser session touches, so that `viv gc` can tell a
/// session that is still serving from one whose process has gone.
///
/// A session's guest lives inside the `viv` process that serves it, so a run
/// directory with a bundle and no report is either a live session or the
/// remains of a killed one. The heartbeat's modification date says which:
/// it is rewritten every `interval` while the session serves, and once it is
/// older than `staleAfter` nothing is rewriting it.
enum SessionHeartbeat {
    static let interval = Duration.seconds(30)

    /// Ten missed beats, so a host that is briefly too busy to schedule the
    /// writer is not mistaken for one whose session has died.
    static let staleAfter: TimeInterval = 300

    enum State: Equatable, Sendable {
        case absent
        case fresh(age: TimeInterval)
        case stale(age: TimeInterval)
    }

    static func state(of file: URL, now: Date = Date()) -> State {
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else {
            return .absent
        }
        let age = max(0, now.timeIntervalSince(modified))
        return age < staleAfter ? .fresh(age: age) : .stale(age: age)
    }

    /// Rewrites the file with the current time, which is what moves its
    /// modification date. A failed write is logged and otherwise ignored: a
    /// session is not ended because its liveness marker could not be written.
    static func touch(_ file: URL, now: Date = Date()) {
        do {
            try Data((now.formatted(.iso8601) + "\n").utf8).write(to: file, options: .atomic)
        } catch {
            log.warn("Could not write the session heartbeat \(file.path): \(VivError.describe(error))")
        }
    }

    /// Touches `file` at once and then every `interval` until the returned
    /// task is cancelled.
    static func beat(at file: URL) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                touch(file)
                try? await Task.sleep(for: interval)
            }
        }
    }
}
