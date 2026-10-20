import Foundation
import Testing

@testable import Vivarium

/// Serialized because signal dispositions belong to the whole test process.
@Suite("Watching for signals", .serialized)
struct SignalWatcherTests {
    /// The handler currently installed for `signo`, without changing it.
    private func disposition(of signo: Int32) -> sig_t? {
        var current = sigaction()
        sigaction(signo, nil, &current)
        return current.__sigaction_u.__sa_handler
    }

    private func sameHandler(_ lhs: sig_t?, _ rhs: sig_t?) -> Bool {
        lhs.map { unsafeBitCast($0, to: Int.self) } == rhs.map { unsafeBitCast($0, to: Int.self) }
    }

    @Test("the first signal is delivered, and a second one is swallowed")
    func deliversFirstSignalOnce() async {
        let before = disposition(of: SIGTERM)
        let watcher = SignalWatcher(signals: SignalWatcher.sessionSignals)
        #expect(watcher.received == nil)

        kill(getpid(), SIGTERM)
        #expect(await watcher.wait() == SIGTERM)

        kill(getpid(), SIGINT)
        kill(getpid(), SIGTERM)
        #expect(await watcher.wait() == SIGTERM)
        #expect(watcher.received == SIGTERM)

        watcher.stop()
        #expect(sameHandler(disposition(of: SIGTERM), before))
        #expect(await watcher.wait() == SIGTERM)
    }

    @Test("a hangup is one of the session's signals")
    func deliversHangup() async {
        let watcher = SignalWatcher(signals: SignalWatcher.sessionSignals)
        defer { watcher.stop() }
        kill(getpid(), SIGHUP)
        #expect(await watcher.wait() == SIGHUP)
    }

    @Test("every waiter is told about the same signal")
    func releasesEveryWaiter() async {
        let watcher = SignalWatcher(signals: [SIGINT])
        defer { watcher.stop() }
        await withTaskGroup(of: Int32?.self) { group in
            for _ in 0..<4 { group.addTask { await watcher.wait() } }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(20))
                kill(getpid(), SIGINT)
                return SIGINT
            }
            for await signo in group { #expect(signo == SIGINT) }
        }
    }

    @Test("stopping before any signal releases a waiter with nothing")
    func stopReleasesWaiter() async {
        let before = disposition(of: SIGHUP)
        let watcher = SignalWatcher(signals: [SIGHUP])
        #expect(sameHandler(disposition(of: SIGHUP), SIG_IGN))

        async let waited = watcher.wait()
        try? await Task.sleep(for: .milliseconds(20))
        watcher.stop()
        #expect(await waited == nil)
        #expect(watcher.received == nil)
        #expect(sameHandler(disposition(of: SIGHUP), before))
        watcher.stop()
    }

    @Test("a wait raced against another event gives up when the race is decided")
    func waitYieldsToCancellation() async {
        let watcher = SignalWatcher(signals: [SIGINT])
        defer { watcher.stop() }
        let winner = await withTaskGroup(of: String.self) { group in
            group.addTask { await watcher.wait() == nil ? "cancelled" : "signalled" }
            group.addTask { "other event" }
            let first = await group.next() ?? "nothing"
            group.cancelAll()
            #expect(await group.next() == "cancelled")
            return first
        }
        #expect(winner == "other event")
    }
}
