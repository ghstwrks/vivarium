import Foundation

/// Takes over a set of signals and reports the first one to arrive.
///
/// The virtual machine is an object in this process, so a signal left to its
/// default disposition kills the guest along with the process before any
/// cleanup can run. While a watcher is running its signals are ignored by the
/// process and observed through dispatch sources instead, which see a signal
/// even when its disposition is `SIG_IGN`.
///
/// Only the first signal is reported, and every waiter gets that same one.
/// Signals after it are swallowed until `stop()`, which restores each
/// signal's previous disposition, so the holder decides when a further signal
/// should take effect again. Once the watcher is no longer referenced it stops
/// itself.
final class SignalWatcher: @unchecked Sendable {
    /// The signals that end an interactive or supervised session: Ctrl-C, a
    /// supervisor's stop request, and the controlling terminal going away.
    static let sessionSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var previousDispositions: [(signal: Int32, handler: sig_t?)] = []
    private let first = OneShot<Int32>()

    /// Starts watching `signals` at once.
    init(signals: [Int32]) {
        // A serial queue of its own: the handlers only record a value, and
        // must not depend on the main queue being serviced.
        let queue = DispatchQueue(label: "viv.signal-watcher")
        for signo in signals {
            // Ignored before the source exists, so there is no moment at which
            // the signal can still take its default action.
            previousDispositions.append((signo, signal(signo, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: signo, queue: queue)
            source.setEventHandler { [first] in first.fulfil(signo) }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        stop()
    }

    /// The first signal received, if one has been. Never suspends.
    var received: Int32? { first.value }

    /// Waits for the first signal.
    ///
    /// Returns it at once if it has already arrived. Returns `nil` if the
    /// watcher is stopped, or the waiting task is cancelled, before any signal
    /// arrives, which makes this safe to race against other events in a task
    /// group.
    func wait() async -> Int32? {
        await first.wait()
    }

    /// Stops watching and restores each signal's previous disposition. A
    /// waiter still suspended is released with `nil`. Safe to call more than
    /// once.
    func stop() {
        lock.lock()
        let stopping = sources
        let restoring = previousDispositions
        sources.removeAll()
        previousDispositions.removeAll()
        lock.unlock()

        for source in stopping { source.cancel() }
        for (signo, handler) in restoring { signal(signo, handler) }
        first.close()
    }
}
