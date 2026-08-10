import Foundation

/// Runs `operation`, abandoning it if `timeout` elapses first.
///
/// Returns `nil` on expiry.
///
/// Polling loops here bound their *total* effort with a deadline
/// evaluated between attempts, which silently assumes each attempt finishes.
/// One that never returns therefore hangs the loop for as long as the process
/// lives, and the outer timeout never gets a chance to fire — exactly the
/// failure seen when `Process.waitUntilExit()` lost a termination event and a
/// ten-minute discovery budget overran by two and a half hours. That specific
/// defect is fixed in `ProcessRunner`; this is the structural guard that keeps
/// the next one from being unbounded, so a stuck attempt costs one interval and
/// is retried rather than ending the run.
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
