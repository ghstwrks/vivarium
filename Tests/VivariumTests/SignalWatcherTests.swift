import Foundation
import Testing

@testable import Vivarium

/// The suites that change signal dispositions or start child processes.
///
/// Serialized as a whole, because dispositions belong to the whole test
/// process and `.serialized` on one suite orders only that suite's own tests.
/// The time limit turns a lost wakeup into a failure rather than a hang.
@Suite("Process and signal plumbing", .serialized, .timeLimit(.minutes(1)))
struct ProcessPlumbingTests {}

extension ProcessPlumbingTests {
    @Suite("Watching for signals", .timeLimit(.minutes(1)))
    struct SignalWatcherTests {
        /// The action currently installed for `signo`, without changing it.
        private func action(for signo: Int32) -> sigaction {
            var current = sigaction()
            sigaction(signo, nil, &current)
            return current
        }

        private func sameAction(_ lhs: sigaction, _ rhs: sigaction) -> Bool {
            func address(_ action: sigaction) -> Int {
                action.__sigaction_u.__sa_handler.map { unsafeBitCast($0, to: Int.self) } ?? 0
            }
            return address(lhs) == address(rhs) && lhs.sa_flags == rhs.sa_flags
        }

        /// Sends `signo` to this process every 10 ms until `done` holds.
        ///
        /// Repeated because a signal sent to the whole process can be taken
        /// by any thread, and nothing promises it has been handled by the time
        /// `kill` returns.
        private func send(_ signo: Int32, until done: () -> Bool) async {
            while !done() {
                kill(getpid(), signo)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        @Test("the first signal is delivered, and a later one is swallowed")
        func deliversFirstSignalOnce() async {
            let before = action(for: SIGTERM)
            let watcher = SignalWatcher(signals: SignalWatcher.sessionSignals)
            #expect(watcher.received == nil)

            await send(SIGTERM) { watcher.received != nil }
            #expect(await watcher.wait() == SIGTERM)

            // SIGINT's default action would end the test process, so getting
            // past this line with the handler having caught it is the proof
            // that it was swallowed.
            await send(SIGINT) { SignalWatcher.hasCaught(SIGINT) }
            #expect(watcher.received == SIGTERM)
            #expect(await watcher.wait() == SIGTERM)

            watcher.stop()
            #expect(sameAction(action(for: SIGTERM), before))
            #expect(await watcher.wait() == SIGTERM)
        }

        @Test("a hangup is one of the session's signals")
        func deliversHangup() async {
            let watcher = SignalWatcher(signals: SignalWatcher.sessionSignals)
            defer { watcher.stop() }
            await send(SIGHUP) { watcher.received != nil }
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
                    await send(SIGINT) { watcher.received != nil }
                    return SIGINT
                }
                for await signo in group { #expect(signo == SIGINT) }
            }
        }

        @Test("stopping before any signal releases a waiter with nothing")
        func stopReleasesWaiter() async {
            let before = action(for: SIGHUP)
            let watcher = SignalWatcher(signals: [SIGHUP])
            #expect(!sameAction(action(for: SIGHUP), before))

            async let waited = watcher.wait()
            try? await Task.sleep(for: .milliseconds(20))
            watcher.stop()
            #expect(await waited == nil)
            #expect(watcher.received == nil)
            #expect(sameAction(action(for: SIGHUP), before))
            watcher.stop()
        }

        @Test("a child started while a signal is watched still stops on SIGTERM")
        func childDoesNotInheritTakeover() async throws {
            let watcher = SignalWatcher(signals: [SIGTERM])
            defer { watcher.stop() }
            let child = try ProcessRunner.spawn(
                "/bin/sleep", ["30"],
                standardInput: .nullDevice,
                standardOutput: .nullDevice,
                standardError: .nullDevice,
                stage: .sshCommand
            )
            let exit = await child.terminate(grace: .milliseconds(200))
            #expect(exit.reason == .uncaughtSignal)
            #expect(exit.status == SIGTERM)
            #expect(watcher.received == nil)
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
}
