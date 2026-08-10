import Foundation

/// The stage of the workflow a failure belongs to. Every failure the tool
/// reports is attributed to exactly one stage so that a failed run says *where*
/// it broke, not just that it broke.
enum POCStage: String, Codable, Sendable {
    case preflight
    case bundlePreparation
    case restoreImage
    case installation
    case templateSnapshot
    case runConfiguration
    case provisioning
    case addressDiscovery
    case sshReadiness
    case sshCommand
    case guestShutdown
    case virtioFSValidation
    case artifactAttach
    case artifactValidation
    case cleanup
}

/// The tool's single error type.
///
/// The Apple sample this is derived from calls `fatalError` on every failure
/// path, which destroys the context a first-boot-automation experiment exists
/// to collect. Every failure here carries the stage, a human-readable message,
/// the underlying error if there was one, and — where a next step is known — a
/// concrete command the operator can run to investigate.
struct POCError: Error, CustomStringConvertible, Sendable {
    let stage: POCStage
    let message: String
    let underlying: (any Error)?
    /// Commands or paths worth inspecting by hand after this failure.
    let inspectionHints: [String]

    init(
        _ stage: POCStage,
        _ message: String,
        underlying: (any Error)? = nil,
        inspectionHints: [String] = []
    ) {
        self.stage = stage
        self.message = message
        self.underlying = underlying
        self.inspectionHints = inspectionHints
    }

    var description: String {
        var text = "[\(stage.rawValue)] \(message)"
        if let underlying {
            text += "\n  underlying: \(Self.describe(underlying))"
        }
        for hint in inspectionHints {
            text += "\n  inspect: \(hint)"
        }
        return text
    }

    /// Renders an arbitrary error with its domain and code, which
    /// `localizedDescription` alone routinely omits for `NSError`s from
    /// Virtualization.
    static func describe(_ error: any Error) -> String {
        if let pocError = error as? POCError {
            return pocError.description
        }
        let nsError = error as NSError
        var text = "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
        if let failureReason = nsError.localizedFailureReason {
            text += " (\(failureReason))"
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " <- \(underlying.domain) code \(underlying.code): \(underlying.localizedDescription)"
        }
        return text
    }
}

/// A machine-readable record of a failed run, written next to the run's other
/// results so a failure is as inspectable as a success.
struct FailureReport: Codable, Sendable {
    let stage: String
    let message: String
    let underlyingDescription: String?
    let underlyingDomain: String?
    let underlyingCode: Int?
    let vmState: String?
    let elapsedSeconds: Double
    let bundlePath: String
    let cleanupCompleted: Bool
    let inspectionHints: [String]
    let lastReadinessGate: String?

    init(
        error: any Error,
        stage: POCStage,
        vmState: String?,
        elapsedSeconds: Double,
        bundlePath: String,
        cleanupCompleted: Bool,
        lastReadinessGate: String?
    ) {
        let pocError = error as? POCError
        self.stage = pocError?.stage.rawValue ?? stage.rawValue
        self.message = pocError?.message ?? error.localizedDescription
        let underlying = pocError?.underlying ?? (pocError == nil ? error : nil)
        if let underlying {
            let nsError = underlying as NSError
            self.underlyingDescription = POCError.describe(underlying)
            self.underlyingDomain = nsError.domain
            self.underlyingCode = nsError.code
        } else {
            self.underlyingDescription = nil
            self.underlyingDomain = nil
            self.underlyingCode = nil
        }
        self.vmState = vmState
        self.elapsedSeconds = elapsedSeconds
        self.bundlePath = bundlePath
        self.cleanupCompleted = cleanupCompleted
        self.inspectionHints = pocError?.inspectionHints ?? []
        self.lastReadinessGate = lastReadinessGate
    }
}
