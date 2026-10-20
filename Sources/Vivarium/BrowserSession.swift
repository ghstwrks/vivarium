import Foundation

/// Everything `viv browser` needs, after the command line has been checked.
struct BrowserSessionPlan: Sendable {
    let runID: String?
    let templateRoot: URL
    /// The directory to stage into the guest's workdir, or `nil` for an
    /// empty one.
    let codeDirectory: URL?
    /// The app under test, started detached in the workdir before the MCP
    /// server.
    let appCommand: String?
    /// A port the app is waited on before the session starts serving.
    let appPort: Int?
    let maxLifetime: Duration
    let idleTimeout: Duration
}

/// Why a browser session stopped serving.
enum SessionEndReason: String, Codable, Sendable {
    /// The MCP client closed `viv`'s standard input.
    case clientClosed
    /// The ssh child carrying the MCP server exited, or the server closed its
    /// output.
    case serverExited
    /// SIGINT, SIGTERM, or SIGHUP.
    case signal
    case maxLifetime
    case idleTimeout
    /// The virtual machine stopped underneath the session.
    case guestStopped
    /// The proxy could not carry a frame, such as one past its size limit.
    case proxyFailed

    /// Whether the client or the operator ended the session, as opposed to
    /// the server or the guest failing it. Only such a session, and only
    /// with a clean guest shutdown after it, earns the deletion of its bundle
    /// and exit status 0.
    var isOrderly: Bool {
        switch self {
        case .clientClosed, .signal, .maxLifetime, .idleTimeout: return true
        case .serverExited, .guestStopped, .proxyFailed: return false
        }
    }
}

struct SessionEnd: Codable, Sendable, Equatable {
    let reason: SessionEndReason
    /// A sentence for the log and the report.
    let detail: String
}

/// Waits for whichever of a session's ending events happens first.
///
/// Each source waits for one kind of event and returns `nil` if it is
/// cancelled, or if its event can no longer happen, before that event. The
/// first source to report an end wins and every other source is cancelled,
/// so each must honour cancellation for the race to return.
enum SessionRace {
    typealias Source = @Sendable () async -> SessionEnd?

    /// Returns the first end reported, or `nil` if every source gave up
    /// without one.
    static func first(of sources: [Source]) async -> SessionEnd? {
        await withTaskGroup(of: SessionEnd?.self) { group in
            for source in sources {
                group.addTask { await source() }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// Ends the session once `lifetime` has passed.
    static func deadline(_ lifetime: Duration) -> Source {
        {
            do {
                try await Task.sleep(for: lifetime)
            } catch {
                return nil
            }
            return SessionEnd(
                reason: .maxLifetime,
                detail: "the session reached its \(describe(lifetime)) maximum lifetime"
            )
        }
    }

    /// Ends the session once nothing has crossed the proxy for `timeout`,
    /// measured from `lastActivity`.
    static func idle(
        after timeout: Duration,
        lastActivity: @escaping @Sendable () -> Date
    ) -> Source {
        {
            while true {
                let remaining = idleRemaining(timeout: timeout, lastActivity: lastActivity(), now: Date())
                if remaining <= 0 {
                    return SessionEnd(
                        reason: .idleTimeout,
                        detail: "no MCP traffic in either direction for \(describe(timeout))"
                    )
                }
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    return nil
                }
            }
        }
    }

    /// Seconds left before a session whose last traffic was at
    /// `lastActivity` counts as idle; zero or less once it does.
    static func idleRemaining(timeout: Duration, lastActivity: Date, now: Date) -> TimeInterval {
        timeout.elapsedSeconds - now.timeIntervalSince(lastActivity)
    }

    /// The end a proxy's own stop implies, or `nil` when the proxy was
    /// stopped by the session, which already knows why.
    static func end(for proxyEnd: MCPProxyEnd) -> SessionEnd? {
        switch proxyEnd {
        case .clientEOF:
            return SessionEnd(reason: .clientClosed, detail: "the MCP client closed standard input")
        case .serverEOF:
            return SessionEnd(reason: .serverExited, detail: "the MCP server closed its output")
        case .stopped:
            return nil
        case let .writeFailed(.client, error):
            return SessionEnd(
                reason: .clientClosed,
                detail: "the MCP client stopped reading its output ("
                    + VivError.describe(error) + ")"
            )
        case let .writeFailed(.server, error):
            return SessionEnd(
                reason: .serverExited,
                detail: "the MCP server stopped reading its input ("
                    + VivError.describe(error) + ")"
            )
        case .frameTooLarge:
            return SessionEnd(
                reason: .proxyFailed,
                detail: "a frame was longer than the proxy accepts "
                    + "(\(Int64(MCPProxy.defaultMaxFrameBytes).formattedByteCount))"
            )
        }
    }

    static func end(forSignal signo: Int32) -> SessionEnd {
        SessionEnd(reason: .signal, detail: "received \(signalName(signo))")
    }

    static func signalName(_ signo: Int32) -> String {
        switch signo {
        case SIGINT: return "SIGINT"
        case SIGTERM: return "SIGTERM"
        case SIGHUP: return "SIGHUP"
        default: return "signal \(signo)"
        }
    }

    static func describe(_ duration: Duration) -> String {
        let seconds = Int(duration.elapsedSeconds.rounded())
        if seconds >= 3600, seconds % 3600 == 0 { return "\(seconds / 3600) h" }
        if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}

/// Agrees to every resend the proxy offers after the share refuses a write,
/// and counts them for the report.
///
/// The first write to the share from a freshly launched Safari can be
/// refused once and then succeed. The proxy offers at most one resend per
/// request, so a second refusal reaches the client. Called on the proxy's
/// response thread, so it only records.
final class ShareWriteRetryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func retry(_ denial: ShareWriteDenial) -> Bool {
        lock.lock()
        count += 1
        lock.unlock()
        log.info(
            "The share refused Safari's write for request \(denial.requestID), as it usually "
                + "does once per session; sending the request again."
        )
        return true
    }

    var retryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// The host, as a guest on the NAT network sees it.
enum GuestGateway {
    /// The gateway `GuestScripts.browserSetupScript` reported, if it reported
    /// a valid IPv4 address.
    static func parse(setupOutput: String) -> String? {
        for line in setupOutput.split(separator: "\n") {
            guard line.hasPrefix(GuestScripts.gatewayLinePrefix) else { continue }
            let candidate = line.dropFirst(GuestScripts.gatewayLinePrefix.count)
                .trimmingCharacters(in: .whitespaces)
            if isIPv4(candidate) { return candidate }
        }
        return nil
    }

    /// The `.1` of the guest's own /24, which is where the Virtualization
    /// framework's NAT puts the host.
    static func derived(fromGuestAddress address: String) -> String? {
        guard isIPv4(address) else { return nil }
        return address.split(separator: ".").dropLast().joined(separator: ".") + ".1"
    }

    static func isIPv4(_ text: String) -> Bool {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3
                && octet.allSatisfy { $0.isASCII && $0.isNumber }
                && UInt8(octet) != nil
        }
    }
}

/// One phase of a session, with when it started.
struct SessionPhaseTiming: Codable, Sendable {
    let name: String
    let startedAt: Date
    let seconds: Double
}

/// `results/session.json`.
struct BrowserSessionReport: Codable, Sendable {
    let runID: String
    let vivariumVersion: String

    let startedAt: Date
    /// When the MCP server began serving, or `nil` if it never did.
    let servingStartedAt: Date?
    let endedAt: Date
    let endReason: SessionEndReason
    let endDetail: String
    /// Whether the client or the operator ended the session and the guest
    /// then shut down cleanly. This alone decides that the bundle was deleted
    /// and that `viv browser` exits 0.
    let orderly: Bool

    let templatePath: String
    let guestOSVersion: String?
    let guestUsername: String
    let guestAddress: String?
    /// The host as the guest sees it: where Safari reaches a server running
    /// on this Mac.
    let gatewayAddress: String?

    let codeDirectory: String?
    let appCommand: String?
    let appPort: Int?
    let maxLifetimeSeconds: Double
    let idleTimeoutSeconds: Double

    let phases: [SessionPhaseTiming]
    let states: [StateTiming]

    /// Frames delivered to the MCP server, resends included.
    let framesToServer: Int
    /// Frames delivered to the MCP client.
    let framesToClient: Int
    /// Requests sent again after the share refused their write.
    let shareWriteRetries: Int

    let artifactCount: Int
    let artifacts: [ArtifactEntry]
    let warnings: [String]

    let resultsPath: String
    /// Paths deleted after an orderly end.
    let deletedPaths: [String]

    /// The lines written to standard error once the session is serving.
    static func banner(
        runID: String,
        guest: String,
        gateway: String?,
        appCommand: String?,
        appPort: Int?,
        sharedArtifacts: URL,
        maxLifetime: Duration,
        idleTimeout: Duration
    ) -> String {
        var rows: [(String, String)] = [
            ("guest", guest),
            ("host", gateway.map { "\($0) — Safari reaches a server on this Mac at http://\($0):<port>/" }
                ?? "unknown — the guest reported no default gateway")
        ]
        if let appCommand {
            rows.append(("app", appCommand + (appPort.map {
                ", listening on port \($0) — Safari reaches it at http://localhost:\($0)/"
            } ?? " — started without --app-port, so nothing waited for it or knows its URL")))
        }
        rows.append(("artifacts", sharedArtifacts.path))
        rows.append(("ends", "on stdin EOF, SIGINT/SIGTERM/SIGHUP, after "
            + SessionRace.describe(maxLifetime) + ", or after "
            + SessionRace.describe(idleTimeout) + " without traffic"))
        let width = rows.map(\.0.count).max() ?? 0
        let lines = rows.map { "  " + $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
        return (["viv browser: serving Safari's MCP server from run \(runID)"] + lines)
            .joined(separator: "\n")
    }
}
