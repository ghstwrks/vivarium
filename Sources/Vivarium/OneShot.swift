import Foundation

/// A value that is set at most once and awaited by any number of tasks.
///
/// The value may arrive before or after any given wait, and every waiter,
/// including one that starts after the value was set, gets the same answer.
/// Callbacks from Foundation and Dispatch fulfil it; async code awaits it.
///
/// Waits come in two kinds. `wait()` gives up when its task is cancelled, which
/// is what a child of a task group racing several events needs: the group
/// cannot finish until every child returns. `waitIgnoringCancellation()` does
/// not, for a caller that must not proceed until the event has happened, such
/// as one about to read a process's exit status.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    /// One suspended wait.
    ///
    /// The cancellation flag and the continuation both live under the
    /// latch's lock, so a cancellation that arrives before the body has
    /// registered is still seen by the body; otherwise that waiter would stay
    /// suspended forever.
    private final class Waiter: @unchecked Sendable {
        var isCancelled = false
        var continuation: CheckedContinuation<Value?, Never>?
    }

    private let lock = NSLock()
    private var stored: Value?
    private var isClosed = false
    private var waiters: [ObjectIdentifier: Waiter] = [:]

    init() {}

    /// The value, if it has been set. Never suspends.
    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Sets the value and releases every waiter with it.
    ///
    /// Returns whether this call set it: the first fulfilment wins, and a
    /// later one, or one after `close()`, is discarded.
    @discardableResult
    func fulfil(_ newValue: Value) -> Bool {
        lock.lock()
        guard stored == nil, !isClosed else {
            lock.unlock()
            return false
        }
        stored = newValue
        let pending = drainWaitersLocked()
        lock.unlock()
        for continuation in pending { continuation.resume(returning: newValue) }
        return true
    }

    /// Releases every waiter with `nil` and refuses any later value. Has no
    /// effect once a value has been set.
    func close() {
        lock.lock()
        guard stored == nil else { return lock.unlock() }
        isClosed = true
        let pending = drainWaitersLocked()
        lock.unlock()
        for continuation in pending { continuation.resume(returning: nil) }
    }

    /// Waits for the value. Returns `nil` if the latch is closed, or if the
    /// calling task is cancelled, before a value is set.
    func wait() async -> Value? {
        let waiter = Waiter()
        let key = ObjectIdentifier(waiter)
        return await withTaskCancellationHandler {
            await suspend(waiter, key: key, honoursCancellation: true)
        } onCancel: {
            lock.lock()
            waiter.isCancelled = true
            let continuation = waiter.continuation
            waiter.continuation = nil
            waiters[key] = nil
            lock.unlock()
            continuation?.resume(returning: nil)
        }
    }

    /// Waits for the value whether or not the calling task is cancelled.
    /// Returns `nil` only if the latch is closed first.
    func waitIgnoringCancellation() async -> Value? {
        let waiter = Waiter()
        return await suspend(waiter, key: ObjectIdentifier(waiter), honoursCancellation: false)
    }

    private func suspend(_ waiter: Waiter, key: ObjectIdentifier, honoursCancellation: Bool) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            lock.lock()
            if let stored {
                lock.unlock()
                continuation.resume(returning: stored)
            } else if isClosed || (honoursCancellation && waiter.isCancelled) {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter.continuation = continuation
                waiters[key] = waiter
                lock.unlock()
            }
        }
    }

    private func drainWaitersLocked() -> [CheckedContinuation<Value?, Never>] {
        let pending = waiters.values.compactMap(\.continuation)
        for waiter in waiters.values { waiter.continuation = nil }
        waiters.removeAll()
        return pending
    }
}
