import Foundation
import Testing

@testable import Vivarium

extension ProcessPlumbingTests {
    @Suite("Waiting for the guest to stop", .timeLimit(.minutes(1)))
    struct VMEventRelayTests {
        /// What ended a race between the events a long session watches.
        private enum SessionEnd: Equatable {
            case guestStopped(String)
            case childExited
            case signalled
            case cancelled
        }

        private func describe(_ outcome: VMEventRelay.StopOutcome?) -> SessionEnd {
            guard let outcome else { return .cancelled }
            return .guestStopped(outcome.description)
        }

        @Test("the outcome can be read without waiting, and the first one recorded stays")
        func currentOutcomeIsFirstRecorded() {
            let relay = VMEventRelay()
            #expect(relay.currentOutcome == nil)
            #expect(!relay.hasStopped)

            relay.record(.guestDidStop)
            relay.record(.stoppedWithError("late error"))

            guard case .guestDidStop = relay.currentOutcome else {
                Issue.record("expected the first outcome, got \(String(describing: relay.currentOutcome))")
                return
            }
            #expect(relay.hasStopped)
        }

        @Test("a wait that starts after the guest stopped returns at once")
        func lateWaiterSeesOutcome() async {
            let relay = VMEventRelay()
            relay.record(.stoppedWithError("boom"))
            #expect(describe(await relay.awaitStop()) == .guestStopped("virtual machine stopped with error: boom"))
        }

        @Test("a guest that stops ends a race against a running child and a signal")
        func guestStopWinsRace() async throws {
            let relay = VMEventRelay()
            let signal = OneShot<Int32>()
            let child = try ProcessRunner.spawn(
                "/bin/sleep", ["30"],
                standardInput: .nullDevice,
                standardOutput: .nullDevice,
                standardError: .nullDevice,
                stage: .sshCommand
            )

            let ends = await withTaskGroup(of: SessionEnd.self) { group in
                group.addTask { describe(await relay.awaitStop()) }
                group.addTask { await child.wait() == nil ? .cancelled : .childExited }
                group.addTask { await signal.wait() == nil ? .cancelled : .signalled }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(20))
                    relay.record(.stoppedWithError("guest crashed"))
                    return .cancelled
                }
                var ends: [SessionEnd] = []
                for await end in group where end != .cancelled {
                    ends.append(end)
                    group.cancelAll()
                }
                return ends
            }

            #expect(ends == [.guestStopped("virtual machine stopped with error: guest crashed")])
            #expect(child.isRunning)
            await child.terminate()
        }

        @Test("a wait on a guest that is still running gives up when the race is decided elsewhere")
        func awaitStopYieldsToCancellation() async {
            let relay = VMEventRelay()
            let first = await withTaskGroup(of: SessionEnd.self) { group in
                group.addTask { describe(await relay.awaitStop()) }
                group.addTask { .childExited }
                let first = await group.next() ?? .cancelled
                group.cancelAll()
                #expect(await group.next() == .cancelled)
                return first
            }
            #expect(first == .childExited)
            #expect(relay.currentOutcome == nil)
        }
    }
}
