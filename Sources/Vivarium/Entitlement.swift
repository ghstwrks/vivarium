import Foundation
import Security

enum Entitlement {
    static let virtualization = "com.apple.security.virtualization"

    /// Whether this binary carries the virtualization entitlement.
    ///
    /// Without it, `VZVirtualMachine(configuration:)` raises an Objective-C
    /// exception that Swift cannot catch. Checking before installation turns
    /// that process-ending exception into an actionable error.
    static func hasVirtualizationEntitlement() -> Bool {
        value(for: virtualization) as? Bool ?? false
    }

    static func value(for entitlement: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) else {
            return nil
        }
        return value as Any
    }

    /// Throws with the exact command that fixes the problem.
    static func require(stage: VivStage) throws {
        guard hasVirtualizationEntitlement() else {
            throw VivError(
                stage,
                """
                This binary is missing the \(virtualization) entitlement, so it cannot \
                create a virtual machine. Sign it before running:
                  codesign -s - --entitlements Vivarium.entitlements -f \(CommandLine.arguments[0])
                or build with `just build`, which signs as part of every build.
                """,
                inspectionHints: ["codesign -d --entitlements - \(CommandLine.arguments[0])"]
            )
        }
    }
}
