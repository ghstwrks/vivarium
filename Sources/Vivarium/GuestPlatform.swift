import Foundation
import Virtualization

protocol GuestPlatform: Sendable {
    var os: GuestOS { get }

    var scripts: GuestScripts { get }

    var templateFilenames: [String] { get }

    var identityDigestFilenames: [String] { get }

    var templateSuppliesMACAddress: Bool { get }

    var hostRequirement: HostRequirement { get }

    var requiredFreeBytes: Int64 { get }

    func makeCredentials(username: String, fullName: String, paths: VMBundlePaths) async throws
        -> GuestCredentials

    func prepareRun(_ request: ProvisioningRequest) async throws

    @MainActor
    func makeRunConfiguration(_ request: RunConfigurationRequest) throws
        -> VZVirtualMachineConfiguration

    @MainActor
    func makeStartOptions(_ request: ProvisioningRequest) throws -> VZVirtualMachineStartOptions?

    var runShutdownOrder: ShutdownOrder { get }

    var assertsArtifactDisk: Bool { get }

    var supportsSystemDiskValidation: Bool { get }
}

struct HostRequirement: Sendable {
    let majorVersion: Int
    let reason: String
}

enum ShutdownOrder: Sendable {
    case requestStopFirst
    case inGuestFirst
}

struct ProvisioningRequest: Sendable {
    let paths: VMBundlePaths
    let credentials: GuestCredentials
    let runID: String
    let hostname: String
    let logsInAutomatically: Bool
    let disablesRemoteLogin: Bool

    static func hostname(forRunID runID: String) -> String {
        let allowed = runID.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let trimmed = String(allowed.prefix(59))
        return "viv-" + (trimmed.isEmpty ? "guest" : trimmed)
    }
}

struct RunConfigurationRequest {
    let paths: VMBundlePaths
    let macAddress: VZMACAddress
    let cpuCount: Int
    let memorySize: UInt64
    let includesArtifactDisk: Bool
    let shareReadOnly: Bool
    let artifactReadOnly: Bool
}
