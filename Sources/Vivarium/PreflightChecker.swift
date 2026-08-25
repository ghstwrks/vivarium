import Foundation
import Virtualization

/// One preflight assertion and its outcome.
struct PreflightCheck: Codable, Sendable {
    let name: String
    let passed: Bool
    let detail: String
}

struct PreflightReport: Codable, Sendable {
    let checks: [PreflightCheck]
    let latestSupportedRestoreImage: String?

    var passed: Bool { checks.allSatisfy(\.passed) }

    var text: String {
        var lines = checks.map { "\($0.passed ? "pass" : "FAIL")  \($0.name): \($0.detail)" }
        if let latestSupportedRestoreImage {
            lines.append("info  VZMacOSRestoreImage.latestSupported: \(latestSupportedRestoreImage)")
        }
        lines.append(passed ? "\nPreflight passed." : "\nPreflight FAILED.")
        return lines.joined(separator: "\n")
    }
}

/// Every cheap check, run before anything expensive happens.
///
/// Runs before installation so host, entitlement, disk-space, and image
/// failures are reported without creating a bundle or starting a VM.
enum PreflightChecker {
    static func run(
        platform: any GuestPlatform,
        ipsw: URL?,
        targetDirectory: URL,
        queryLatestSupported: Bool
    ) async -> PreflightReport {
        var checks: [PreflightCheck] = []

        checks.append(PreflightCheck(
            name: "guest",
            passed: true,
            detail: platform.os.displayName
        ))
        checks.append(checkArchitecture())
        checks.append(checkHostVersion(platform.hostRequirement))
        checks.append(checkEntitlement())
        checks.append(checkFreeSpace(at: targetDirectory, required: platform.requiredFreeBytes))

        if let ipsw {
            checks.append(contentsOf: await checkRestoreImage(ipsw))
        } else if platform.os == .macOS {
            checks.append(PreflightCheck(
                name: "restore image",
                passed: true,
                detail: "not checked: no --ipsw supplied"
            ))
        }

        var latest: String?
        if queryLatestSupported {
            switch await RestoreImageManager.queryLatestSupported() {
            case let .success(image):
                latest = "macOS \(image.version) (\(image.build))"
                    + (versionMajor(image.version) >= RestoreImageManager.minimumGuestMajorVersion
                        ? " — new enough to provision; the local-IPSW requirement could be lifted"
                        : " — too old to provision; a local macOS 27 IPSW remains required")
            case let .failure(error):
                latest = "query failed: \(VivError.describe(error))"
            }
        }

        return PreflightReport(checks: checks, latestSupportedRestoreImage: latest)
    }

    private static func checkArchitecture() -> PreflightCheck {
        #if arch(arm64)
        return PreflightCheck(name: "architecture", passed: true, detail: "arm64")
        #else
        return PreflightCheck(
            name: "architecture",
            passed: false,
            detail: "macOS guests require an Apple silicon host"
        )
        #endif
    }

    private static func checkHostVersion(_ requirement: HostRequirement) -> PreflightCheck {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let text = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            + " (\(HostInfo.buildVersion))"
        let passed = version.majorVersion >= requirement.majorVersion
        return PreflightCheck(
            name: "host macOS version",
            passed: passed,
            detail: passed
                ? text
                : "\(text); macOS \(requirement.majorVersion) or later required, because "
                    + requirement.reason
        )
    }

    private static func checkEntitlement() -> PreflightCheck {
        let present = Entitlement.hasVirtualizationEntitlement()
        return PreflightCheck(
            name: "virtualization entitlement",
            passed: present,
            detail: present
                ? "\(Entitlement.virtualization) present on this binary"
                : "missing; run: codesign -s - --entitlements Vivarium.entitlements -f "
                    + CommandLine.arguments[0]
        )
    }

    private static func checkFreeSpace(at directory: URL, required: Int64) -> PreflightCheck {
        // Check the nearest existing ancestor: the run directory itself does
        // not exist yet during preflight.
        var probe = directory.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }

        do {
            let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            let gibibytes = Double(available) / Double(1 << 30)
            return PreflightCheck(
                name: "free space",
                passed: available >= required,
                detail: String(
                    format: "%.1f GiB available on %@ (need %.0f GiB)",
                    gibibytes, probe.path, Double(required) / Double(1 << 30)
                )
            )
        } catch {
            return PreflightCheck(
                name: "free space",
                passed: false,
                detail: "cannot determine free space at \(probe.path): \(VivError.describe(error))"
            )
        }
    }

    private static func checkRestoreImage(_ url: URL) async -> [PreflightCheck] {
        do {
            let loaded = try await RestoreImageManager.load(ipsw: url)
            let requirements = loaded.requirements
            var checks = [
                PreflightCheck(
                    name: "restore image loads",
                    passed: true,
                    detail: "macOS \(loaded.versionString) (\(loaded.buildVersion)) at \(url.path)"
                ),
                PreflightCheck(
                    name: "restore image major version",
                    passed: true,
                    detail: "\(loaded.operatingSystemVersion.majorVersion) >= "
                        + "\(RestoreImageManager.minimumGuestMajorVersion)"
                ),
                PreflightCheck(
                    name: "hardware model supported",
                    passed: true,
                    detail: "supported on this host"
                )
            ]

            let cpuCount = VMConfigurationFactory.computeCPUCount()
            checks.append(PreflightCheck(
                name: "CPU count",
                passed: cpuCount >= requirements.minimumSupportedCPUCount,
                detail: "\(cpuCount) configured, \(requirements.minimumSupportedCPUCount) required"
            ))

            let memory = VMConfigurationFactory.computeMemorySize()
            checks.append(PreflightCheck(
                name: "memory size",
                passed: memory >= requirements.minimumSupportedMemorySize,
                detail: "\(memory / (1 << 30)) GiB configured, "
                    + "\(requirements.minimumSupportedMemorySize / (1 << 30)) GiB required"
            ))

            return checks
        } catch {
            return [PreflightCheck(
                name: "restore image",
                passed: false,
                detail: VivError.describe(error)
            )]
        }
    }

    private static func versionMajor(_ version: String) -> Int {
        Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0
    }
}
