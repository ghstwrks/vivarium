import Foundation

/// Runs `operation`, abandoning it if `timeout` elapses first.
///
/// Returns `nil` on expiry.
///
/// Polling loops bound their *total* effort with a deadline evaluated between
/// attempts, which only works if each attempt also finishes. This outer guard
/// ensures a stuck attempt costs one interval and can be abandoned instead of
/// blocking the polling loop indefinitely.
///
/// The losing child is cancelled, not killed: Swift cancellation is
/// cooperative, so an operation blocked in a system call keeps its thread until
/// it returns. Every subprocess Vivarium spawns is bounded by
/// `ProcessRunner.defaultTimeout`, so such a thread is temporary rather than
/// permanent, and the caller resumes either way.
extension Duration {
    /// Seconds as a `Double`, for reports and log lines.
    var elapsedSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
