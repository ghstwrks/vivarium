import Foundation
import Testing

@testable import Vivarium

extension ProcessPlumbingTests {
    @Suite("A long-lived child process", .timeLimit(.minutes(1)))
    struct SpawnedProcessTests {
        /// Reads from `handle` until `expected` bytes have arrived or the stream ends.
        private func read(_ expected: Int, from handle: FileHandle) throws -> Data {
            var received = Data()
            while received.count < expected, let chunk = try handle.read(upToCount: expected - received.count),
                  !chunk.isEmpty {
                received.append(chunk)
            }
            return received
        }

        @Test("bytes written to its standard input come back on its standard output")
        func echoesThroughPipes() async throws {
            let input = Pipe()
            let output = Pipe()
            let child = try ProcessRunner.spawn(
                "/bin/cat", [],
                standardInput: .pipe(input),
                standardOutput: .pipe(output),
                standardError: .nullDevice,
                stage: .sshCommand
            )
            #expect(child.pid > 0)
            #expect(child.isRunning)

            let message = Data("{\"jsonrpc\":\"2.0\",\"id\":1}\n".utf8)
            try input.fileHandleForWriting.write(contentsOf: message)
            #expect(try read(message.count, from: output.fileHandleForReading) == message)
            #expect(child.isRunning)

            let exit = await child.terminate()
            #expect(exit.reason == .uncaughtSignal)
            #expect(exit.status == SIGTERM)
            #expect(exit.wasTerminated)
            #expect(!child.isRunning)
            #expect(child.exit == exit)
            #expect(await child.wait() == exit)
        }

        @Test("closing its standard input ends a child that reads to EOF")
        func exitsOnEOF() async throws {
            let input = Pipe()
            let child = try ProcessRunner.spawn(
                "/bin/cat", [],
                standardInput: .pipe(input),
                standardOutput: .nullDevice,
                standardError: .nullDevice,
                stage: .sshCommand
            )
            try input.fileHandleForWriting.close()

            let exit = await child.wait()
            #expect(exit == ProcessExit(status: 0, reason: .exit, wasTerminated: false))
            #expect(exit?.succeeded == true)
        }

        @Test("an exit status of the child's own choosing is reported as is")
        func reportsOwnExitStatus() async throws {
            let child = try ProcessRunner.spawn(
                "/bin/sh", ["-c", "exit 23"],
                standardInput: .nullDevice,
                standardOutput: .nullDevice,
                standardError: .nullDevice,
                stage: .sshCommand
            )
            #expect(await child.wait() == ProcessExit(status: 23, reason: .exit, wasTerminated: false))
            // Stopping a child that has already gone sends nothing and changes nothing.
            #expect(await child.terminate() == ProcessExit(status: 23, reason: .exit, wasTerminated: false))
        }

        @Test("a handed file handle receives the child's output directly")
        func writesToHandedFileHandle() async throws {
            let url = try temporaryFile("")
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }

            let child = try ProcessRunner.spawn(
                "/bin/sh", ["-c", "printf out; printf err >&2"],
                standardInput: .nullDevice,
                standardOutput: .fileHandle(file),
                standardError: .fileHandle(file),
                stage: .sshCommand
            )
            #expect(await child.wait()?.succeeded == true)
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(written.contains("out"))
            #expect(written.contains("err"))
        }

        @Test("a child that ignores SIGTERM is killed once the grace period ends")
        func escalatesToSIGKILL() async throws {
            let output = Pipe()
            // The child announces that its trap is installed before it is
            // signalled, so the SIGTERM cannot arrive while it is still starting.
            let child = try ProcessRunner.spawn(
                "/bin/sh", ["-c", "trap '' TERM; echo ready; while :; do sleep 1; done"],
                standardInput: .nullDevice,
                standardOutput: .pipe(output),
                standardError: .nullDevice,
                stage: .sshCommand
            )
            #expect(try read(6, from: output.fileHandleForReading) == Data("ready\n".utf8))

            let exit = await child.terminate(grace: .milliseconds(200))
            #expect(exit.reason == .uncaughtSignal)
            #expect(exit.status == SIGKILL)
            #expect(exit.wasTerminated)
        }

        @Test("a wait raced against another event gives up when the race is decided")
        func waitYieldsToCancellation() async throws {
            let child = try ProcessRunner.spawn(
                "/bin/sleep", ["30"],
                standardInput: .nullDevice,
                standardOutput: .nullDevice,
                standardError: .nullDevice,
                stage: .sshCommand
            )
            let winner = await withTaskGroup(of: String.self) { group in
                group.addTask { await child.wait() == nil ? "cancelled" : "exited" }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(50))
                    return "other event"
                }
                let first = await group.next() ?? "nothing"
                group.cancelAll()
                #expect(await group.next() == "cancelled")
                return first
            }
            #expect(winner == "other event")
            #expect(child.isRunning)
            await child.terminate()
        }

        @Test("a missing executable fails to launch with the caller's stage")
        func reportsLaunchFailure() throws {
            let error = #expect(throws: VivError.self) {
                try ProcessRunner.spawn(
                    "/nonexistent/viv-test-binary", [],
                    standardInput: .nullDevice,
                    standardOutput: .nullDevice,
                    standardError: .nullDevice,
                    stage: .sshCommand
                )
            }
            #expect(error?.stage == .sshCommand)
        }
    }
}

@Suite("A value set once", .timeLimit(.minutes(1)))
struct OneShotTests {
    @Test("a waiter that starts after the value was set gets it at once")
    func lateWaiterSeesValue() async {
        let latch = OneShot<Int>()
        #expect(latch.fulfil(1))
        #expect(!latch.fulfil(2))
        #expect(latch.value == 1)
        #expect(await latch.wait() == 1)
        #expect(await latch.waitIgnoringCancellation() == 1)
    }

    @Test("every waiter is released with the same value")
    func releasesEveryWaiter() async {
        let latch = OneShot<Int>()
        await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<8 { group.addTask { await latch.wait() } }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(20))
                latch.fulfil(7)
                return 7
            }
            for await value in group { #expect(value == 7) }
        }
    }

    @Test("closing releases waiters with nothing and refuses a later value")
    func closeReleasesWaiters() async {
        let latch = OneShot<Int>()
        async let waited = latch.wait()
        try? await Task.sleep(for: .milliseconds(20))
        latch.close()
        #expect(await waited == nil)
        #expect(!latch.fulfil(1))
        #expect(latch.value == nil)
    }

    @Test("a wait ignoring cancellation still returns the value after its task is cancelled")
    func uncancellableWaitOutlivesCancellation() async {
        let latch = OneShot<Int>()
        let task = Task { await latch.waitIgnoringCancellation() }
        task.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        latch.fulfil(3)
        #expect(await task.value == 3)
    }
}
