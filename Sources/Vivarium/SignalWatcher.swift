import Foundation
import Synchronization

/// Takes over a set of signals and reports the first one to arrive.
///
/// The virtual machine is an object in this process, so a signal left to its
/// default disposition kills the guest along with the process before any
/// cleanup can run. While a watcher is running its signals are caught by a
/// handler that only records them, and reported through dispatch sources. A
/// caught signal, unlike an ignored one, reverts to its default disposition
/// across `exec`, so a child started meanwhile still responds to SIGTERM.
///
/// Only the first signal is reported, and every waiter gets that same one;
/// when several arrive together, which of them is first is unspecified.
/// Signals after it are swallowed until `stop()`, which restores each
/// signal's previous action, so the holder decides when a further signal
/// should take effect again. Once the watcher is no longer referenced it stops
/// itself.
///
/// Watchers must not overlap on a signal: each restores the action it found,
/// and all of them share one record of caught signals.
final class SignalWatcher: @unchecked Sendable {
    /// The signals that end an interactive or supervised session: Ctrl-C, a
    /// supervisor's stop request, and the controlling terminal going away.
    static let sessionSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private let signals: [Int32]
    private let mask: UInt64
    private let first = OneShot<Int32>()
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var previousActions: [(signal: Int32, action: sigaction)] = []
    private var isStopped = false

    /// Starts watching `signals` at once.
    init(signals: [Int32]) {
        precondition(signals.allSatisfy { $0 > 0 && $0 < NSIG }, "not a signal number")
        self.signals = signals
        mask = signals.reduce(0) { $0 | signalBit($1) }

        let previouslyClaimed = claimedSignals.bitwiseOr(mask, ordering: .sequentiallyConsistent).oldValue
        assert(previouslyClaimed & mask == 0, "two SignalWatchers are watching the same signal")
        // Also the first touch of the caught-signal record, which must be
        // initialised before a signal handler can read it.
        caughtSignals.bitwiseAnd(~mask, ordering: .sequentiallyConsistent)

        // A serial queue of its own: the sources only record a value, and
        // must not depend on the main queue being serviced.
        let queue = DispatchQueue(label: "viv.signal-watcher")
        for signo in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = recordCaughtSignal
            action.sa_flags = SA_RESTART
            sigemptyset(&action.sa_mask)
            var previous = sigaction()
            sigaction(signo, &action, &previous)
            previousActions.append((signo, previous))

            let source = DispatchSource.makeSignalSource(signal: signo, queue: queue)
            source.setEventHandler { [first] in first.fulfil(signo) }
            // A signal caught after the handler was installed but before the
            // source was registered with the kernel reaches only the handler.
            source.setRegistrationHandler { [first, signals] in
                Self.collectCaught(signals, into: first)
            }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        stop()
    }

    /// The first signal received, if one has been. Never suspends.
    var received: Int32? {
        Self.collectCaught(signals, into: first)
        return first.value
    }

    /// Waits for the first signal.
    ///
    /// Returns it at once if it has already arrived. Returns `nil` if the
    /// watcher is stopped, or the waiting task is cancelled, before any signal
    /// arrives, which makes this safe to race against other events in a task
    /// group.
    func wait() async -> Int32? {
        Self.collectCaught(signals, into: first)
        return await first.wait()
    }

    /// Stops watching and restores each signal's previous action. A waiter
    /// still suspended is released with `nil`. Safe to call more than once.
    func stop() {
        lock.lock()
        guard !isStopped else { return lock.unlock() }
        isStopped = true
        let stopping = sources
        let restoring = previousActions
        sources.removeAll()
        previousActions.removeAll()
        lock.unlock()

        for source in stopping { source.cancel() }
        for (signo, action) in restoring {
            var action = action
            sigaction(signo, &action, nil)
        }
        claimedSignals.bitwiseAnd(~mask, ordering: .sequentiallyConsistent)
        first.close()
    }

    /// Whether the handler has caught `signo` since a watcher for it started.
    static func hasCaught(_ signo: Int32) -> Bool {
        caughtSignals.load(ordering: .sequentiallyConsistent) & signalBit(signo) != 0
    }

    private static func collectCaught(_ signals: [Int32], into first: OneShot<Int32>) {
        guard first.value == nil, let signo = signals.first(where: hasCaught) else { return }
        first.fulfil(signo)
    }
}

/// One bit per signal number, set by the handler when it catches that signal.
/// Atomic, and touched by nothing else in the handler, because only
/// async-signal-safe operations may run there.
private let caughtSignals = Atomic<UInt64>(0)

/// One bit per signal number with a running watcher.
private let claimedSignals = Atomic<UInt64>(0)

private func signalBit(_ signo: Int32) -> UInt64 {
    UInt64(1) << UInt64(signo)
}

private func recordCaughtSignal(_ signo: Int32) {
    caughtSignals.bitwiseOr(UInt64(1) << UInt64(signo), ordering: .sequentiallyConsistent)
}
