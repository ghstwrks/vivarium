import Foundation
import Testing

@testable import Vivarium

@Suite("How a browser session ends")
struct SessionRaceTests {
    /// A source that never reports, and returns `nil` once cancelled.
    static let never: SessionRace.Source = {
        try? await Task.sleep(for: .seconds(3600))
        return nil
    }

    @Test("the first source to report wins, and the others are cancelled")
    func firstWins() async {
        let clock = ContinuousClock()
        let started = clock.now
        let end = await SessionRace.first(of: [
            Self.never,
            SessionRace.deadline(.milliseconds(50)),
            Self.never
        ])
        #expect(end?.reason == .maxLifetime)
        #expect(started.duration(to: clock.now) < .seconds(5))
    }

    @Test("a source that gives up without an end does not end the session")
    func givingUpIsNotAnEnd() async {
        let end = await SessionRace.first(of: [
            { nil },
            SessionRace.deadline(.milliseconds(50))
        ])
        #expect(end?.reason == .maxLifetime)
    }

    @Test("a race in which every source gives up has no end")
    func noEnd() async {
        #expect(await SessionRace.first(of: [{ nil }, { nil }]) == nil)
    }

    @Test("an idle session ends once its quiet period reaches the timeout")
    func idleEnds() async {
        let quietSince = Date().addingTimeInterval(-10)
        let end = await SessionRace.first(of: [
            SessionRace.idle(after: .milliseconds(10_050), lastActivity: { quietSince }),
            Self.never
        ])
        #expect(end?.reason == .idleTimeout)
    }

    @Test("traffic moves the idle deadline")
    func idleRemaining() {
        let now = Date()
        #expect(SessionRace.idleRemaining(timeout: .seconds(60), lastActivity: now, now: now) == 60)
        #expect(SessionRace.idleRemaining(
            timeout: .seconds(60), lastActivity: now.addingTimeInterval(-45), now: now
        ) == 15)
        #expect(SessionRace.idleRemaining(
            timeout: .seconds(60), lastActivity: now.addingTimeInterval(-61), now: now
        ) < 0)
    }

    @Test("each way the proxy stops maps to a reason, except a stop the session asked for")
    func proxyEnds() {
        struct Broken: Error {}
        #expect(SessionRace.end(for: .clientEOF)?.reason == .clientClosed)
        #expect(SessionRace.end(for: .serverEOF)?.reason == .serverExited)
        #expect(SessionRace.end(for: .writeFailed(.client, Broken()))?.reason == .clientClosed)
        #expect(SessionRace.end(for: .writeFailed(.server, Broken()))?.reason == .serverExited)
        #expect(SessionRace.end(for: .frameTooLarge)?.reason == .proxyFailed)
        #expect(SessionRace.end(for: .stopped) == nil)
    }

    @Test("only the client and the operator end a session in an orderly way")
    func orderliness() {
        let orderly: Set<SessionEndReason> = [.clientClosed, .signal, .maxLifetime, .idleTimeout]
        for reason in [SessionEndReason.clientClosed, .serverExited, .signal, .maxLifetime,
                       .idleTimeout, .guestStopped, .proxyFailed] {
            #expect(reason.isOrderly == orderly.contains(reason))
        }
    }

    @Test("signals are named in the report")
    func signalNames() {
        #expect(SessionRace.end(forSignal: SIGTERM).detail == "received SIGTERM")
        #expect(SessionRace.end(forSignal: SIGINT).reason == .signal)
    }

    @Test("durations read in the largest whole unit")
    func durations() {
        #expect(SessionRace.describe(.seconds(7200)) == "2 h")
        #expect(SessionRace.describe(.seconds(1200)) == "20 min")
        #expect(SessionRace.describe(.seconds(90)) == "90 s")
    }
}

@Suite("Browser session bookkeeping")
struct BrowserSessionBookkeepingTests {
    @Test("every resend the proxy offers is taken, and counted")
    func retriesCounted() {
        let counter = ShareWriteRetryCounter()
        #expect(counter.retry(ShareWriteDenial(requestID: .int(4), originalRequest: Data())))
        #expect(counter.retry(ShareWriteDenial(requestID: .string("4"), originalRequest: Data())))
        #expect(counter.retryCount == 2)
    }

    @Test("the gateway is read from the setup script's own line")
    func gatewayParsed() {
        #expect(GuestGateway.parse(setupOutput: "noise\ngateway 192.168.64.1\n") == "192.168.64.1")
        #expect(GuestGateway.parse(setupOutput: "gateway \n") == nil)
        #expect(GuestGateway.parse(setupOutput: "gateway 999.1.1.1\n") == nil)
        #expect(GuestGateway.parse(setupOutput: "gateway +1.2.3.4\n") == nil)
        #expect(GuestGateway.parse(setupOutput: "") == nil)
    }

    @Test("without a reported gateway, the host is the .1 of the guest's network")
    func gatewayDerived() {
        #expect(GuestGateway.derived(fromGuestAddress: "192.168.64.23") == "192.168.64.1")
        #expect(GuestGateway.derived(fromGuestAddress: "fe80::1") == nil)
    }

    @Test("the banner names the host address and how the session ends")
    func banner() {
        let text = BrowserSessionReport.banner(
            runID: "r1",
            guest: "vivadmin@192.168.64.23",
            gateway: "192.168.64.1",
            appCommand: "npm run dev",
            appPort: 5173,
            sharedArtifacts: URL(fileURLWithPath: "/runs/r1/Shared/artifacts"),
            maxLifetime: .seconds(7200),
            idleTimeout: .seconds(1200)
        )
        #expect(text.contains("http://192.168.64.1:<port>/"))
        #expect(text.contains("npm run dev, listening on port 5173"))
        #expect(text.contains("http://localhost:5173/"))
        #expect(text.contains("/runs/r1/Shared/artifacts"))
        #expect(text.contains("after 2 h"))
        #expect(text.contains("after 20 min without traffic"))
    }

    @Test("the session report round-trips with its end reason as a word")
    func reportEncoding() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let report = BrowserSessionReport(
            runID: "r1",
            vivariumVersion: Viv.releaseVersion,
            startedAt: started,
            servingStartedAt: started.addingTimeInterval(20),
            endedAt: started.addingTimeInterval(600),
            endReason: .idleTimeout,
            endDetail: "no MCP traffic in either direction for 20 min",
            templatePath: "/templates/macos-26B118.bundle",
            guestOSVersion: "27.2",
            guestUsername: "vivadmin",
            guestAddress: "192.168.64.23",
            gatewayAddress: "192.168.64.1",
            codeDirectory: nil,
            appCommand: nil,
            appPort: nil,
            maxLifetimeSeconds: 7200,
            idleTimeoutSeconds: 1200,
            phases: [SessionPhaseTiming(name: "boot to ssh", startedAt: started, seconds: 15.5)],
            states: [],
            framesToServer: 12,
            framesToClient: 11,
            shareWriteRetries: 1,
            artifactCount: 1,
            artifacts: [ArtifactEntry(path: "screenshot-1.png", byteCount: 89_000)],
            warnings: [],
            resultsPath: "/runs/r1/results",
            deletedPaths: ["VM.bundle", "Shared"]
        )
        let url = try temporaryDirectory().appendingPathComponent("session.json")
        try JSONCoding.write(report, to: url)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["endReason"] as? String == "idleTimeout")
        #expect(object["gatewayAddress"] as? String == "192.168.64.1")
        #expect(object["framesToServer"] as? Int == 12)
        #expect(object["artifactCount"] as? Int == 1)

        let decoded = try JSONCoding.read(BrowserSessionReport.self, from: url, stage: .cleanup)
        #expect(decoded.endReason == .idleTimeout)
        #expect(decoded.servingStartedAt == report.servingStartedAt)
        #expect(decoded.phases.first?.name == "boot to ssh")
    }
}
