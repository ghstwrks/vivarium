import Foundation
import Virtualization

/// Bridges `VZVirtualMachineDelegate` callbacks into something awaitable.
///
/// Apple's `MacOSVirtualMachineDelegate` calls `exit()` from inside the
/// delegate methods. That is fine for a sample whose only job is to install,
/// but here a guest stopping is an ordinary, *expected* event that the
/// orchestrator has to await and then act on — validating a detached disk, for
/// instance. The delegate reports; the orchestrator decides.
///
/// A latch rather than an `AsyncStream`. The shutdown path waits twice: once
/// for `requestStop`, and again after falling back to an in-guest `shutdown -h
/// now`. `AsyncStream` is single-consumer, and cancelling the first waiter
/// deinitialises its iterator, which *terminates the stream*. The second wait
/// then observed an already-finished stream and returned "did not stop" in the
/// same millisecond it started — so a guest that shut down perfectly well was
/// destructively killed and the run failed. A latch has no such edge: it
/// records the terminal outcome once and hands the same answer to every waiter,
/// early or late.
final class VMEventRelay: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    /// How the guest reached a stopped state.
    enum StopOutcome: Sendable, CustomStringConvertible {
        case guestDidStop
        case stoppedWithError(String)

        var description: String {
            switch self {
            case .guestDidStop:
                return "guest stopped the virtual machine"
            case let .stoppedWithError(message):
                return "virtual machine stopped with error: \(message)"
            }
        }
    }

    /// One suspended `awaitStop()` call.
    ///
    /// The cancellation flag and the continuation both live under the relay's
    /// lock, so a cancellation that arrives before the body has registered is
    /// still seen by the body — the ordinary race in
    /// `withTaskCancellationHandler`, which would otherwise leave a waiter
    /// suspended forever and deadlock the task group that cancelled it.
    /// Unchecked because every field is only ever touched under the relay's
    /// lock, which the compiler cannot see.
    private final class Waiter: @unchecked Sendable {
        var isCancelled = false
        var continuation: CheckedContinuation<StopOutcome?, Never>?
    }

    private let lock = NSLock()
    private var outcome: StopOutcome?
    private var isFinished = false
    private var waiters: [ObjectIdentifier: Waiter] = [:]

    /// Waits for the guest to stop.
    ///
    /// Returns the outcome, or `nil` if the relay was finished or this wait was
    /// cancelled before the guest stopped. Safe to call repeatedly and safe to
    /// call after the guest has already stopped.
    func awaitStop() async -> StopOutcome? {
        let waiter = Waiter()
        let key = ObjectIdentifier(waiter)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<StopOutcome?, Never>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                } else if isFinished || waiter.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiter.continuation = continuation
                    waiters[key] = waiter
                    lock.unlock()
                }
            }
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

    /// Whether the guest has already been observed to stop.
    var hasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome != nil
    }

    /// Releases every waiter, for teardown paths where nothing more will arrive.
    func finish() {
        lock.lock()
        isFinished = true
        let pending = drainWaitersLocked()
        lock.unlock()
        for continuation in pending { continuation.resume(returning: nil) }
    }

    private func record(_ newOutcome: StopOutcome) {
        lock.lock()
        // First terminal event wins: a stop followed by an error report should
        // not rewrite history into a failure.
        guard outcome == nil else { return lock.unlock() }
        outcome = newOutcome
        let pending = drainWaitersLocked()
        lock.unlock()
        for continuation in pending { continuation.resume(returning: newOutcome) }
    }

    private func drainWaitersLocked() -> [CheckedContinuation<StopOutcome?, Never>] {
        let pending = waiters.values.compactMap(\.continuation)
        for waiter in waiters.values { waiter.continuation = nil }
        waiters.removeAll()
        return pending
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log.info("Delegate: guest stopped the virtual machine.")
        record(.guestDidStop)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = POCError.describe(error)
        log.error("Delegate: virtual machine stopped with error: \(message)")
        record(.stoppedWithError(message))
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        // Not terminal: the guest tearing down its network on the way to a
        // clean shutdown looks exactly like this.
        log.warn("Delegate: network attachment disconnected: \(POCError.describe(error))")
    }
}
