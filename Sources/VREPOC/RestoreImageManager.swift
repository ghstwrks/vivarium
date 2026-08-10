import Foundation
import Virtualization

/// A restore image plus the facts the run needs from it.
struct LoadedRestoreImage: @unchecked Sendable {
    let image: VZMacOSRestoreImage
    let requirements: VZMacOSConfigurationRequirements

    var url: URL { image.url }
    var buildVersion: String { image.buildVersion }
    var operatingSystemVersion: OperatingSystemVersion { image.operatingSystemVersion }

    var versionString: String {
        let version = image.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

enum RestoreImageManager {
    /// The oldest guest that honours `VZMacGuestProvisioningOptions`. Guests
    /// older than this ignore the options entirely and boot into Setup
    /// Assistant, which no acceptance criterion can satisfy.
    static let minimumGuestMajorVersion = 27

    /// Whether a recorded `major.minor.patch` string clears the version gate.
    ///
    /// Used by the runs that do not perform an install — a template clone or an
    /// adopted bundle — to answer the same acceptance criterion from what the
    /// install recorded, since `load(ipsw:)` enforced it at the time. An unknown
    /// or unparsable version is not a pass.
    static func satisfiesGuestVersionGate(_ version: String?) -> Bool {
        guard let major = version?.split(separator: ".").first.flatMap({ Int($0) }) else {
            return false
        }
        return major >= minimumGuestMajorVersion
    }

    /// Loads a local IPSW and applies the version gate.
    ///
    /// The gate runs before anything expensive so that pointing the tool at the
    /// macOS 26.6.1 image `VZMacOSRestoreImage.latestSupported` offers fails in
    /// seconds rather than after a ninety-minute install.
    static func load(ipsw url: URL, stage: POCStage = .restoreImage) async throws -> LoadedRestoreImage {
        guard url.isFileURL else {
            throw POCError(stage, "The IPSW path \(url) is not a file URL.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw POCError(stage, "No file at \(url.path).")
        }

        let image = try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { result in
                continuation.resume(with: result.map(UncheckedBox.init))
            }
        }.value

        let version = image.operatingSystemVersion
        guard version.majorVersion >= minimumGuestMajorVersion else {
            throw POCError(
                stage,
                """
                Restore image at \(url.path) is macOS \
                \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) \
                (build \(image.buildVersion)), but guest provisioning requires macOS \
                \(minimumGuestMajorVersion) or later. Earlier guests ignore \
                VZMacGuestProvisioningOptions and boot into Setup Assistant.
                """
            )
        }

        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw POCError(
                stage,
                "Restore image at \(url.path) offers no configuration supported by this host."
            )
        }

        guard requirements.hardwareModel.isSupported else {
            throw POCError(
                stage,
                "The hardware model required by \(url.path) is not supported on this host."
            )
        }

        return LoadedRestoreImage(image: image, requirements: requirements)
    }

    /// Reports what the framework would download, without downloading it.
    ///
    /// This exists so the hard requirement for a local image can be lifted the
    /// day Apple publishes a macOS 27 restore image, and so a run's log records
    /// why it was still necessary.
    static func queryLatestSupported() async -> Result<(version: String, build: String), any Error> {
        do {
            let image = try await withCheckedThrowingContinuation { continuation in
                VZMacOSRestoreImage.fetchLatestSupported { result in
                    continuation.resume(with: result.map(UncheckedBox.init))
                }
            }.value
            let version = image.operatingSystemVersion
            return .success((
                version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                build: image.buildVersion
            ))
        } catch {
            return .failure(error)
        }
    }
}
