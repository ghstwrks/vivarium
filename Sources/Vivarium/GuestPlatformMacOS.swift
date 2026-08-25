import Foundation
import Virtualization

struct MacOSPlatform: GuestPlatform {
    let os: GuestOS = .macOS

    var scripts: GuestScripts {
        GuestScripts(
            dialect: .zsh,
            shellExecutable: "/bin/zsh",
            sharePath: "/Volumes/My Shared Files",
            readinessCommand: "/usr/bin/id -un",
            shutdownCommand: "/usr/bin/sudo -S -p '' /sbin/shutdown -h now",
            shutdownWantsPasswordOnStdin: true,
            diagnosticsScript: """
                echo '--- id'; /usr/bin/id || true
                echo '--- mounts'; /sbin/mount || true
                echo '--- volumes'; /bin/ls -la /Volumes || true
                echo '--- diskutil list'; /usr/sbin/diskutil list || true
                echo '--- remote login'; /usr/sbin/systemsetup -getremotelogin 2>/dev/null || true
                echo '--- sshd access group'; /usr/bin/dscl . -read /Groups/com.apple.access_ssh 2>/dev/null || true
                echo '--- admin membership'; /usr/sbin/dseditgroup -o checkmember -m "$(/usr/bin/id -un)" admin 2>&1 || true
                echo '--- uptime'; /usr/bin/uptime || true
                """
        )
    }

    var templateFilenames: [String] {
        ["AuxiliaryStorage", VMBundlePaths.systemDiskFilename,
         "HardwareModel", "MachineIdentifier", "MACAddress"]
    }

    var identityDigestFilenames: [String] {
        ["AuxiliaryStorage", "HardwareModel", "MachineIdentifier", "MACAddress"]
    }

    var templateSuppliesMACAddress: Bool { true }

    var hostRequirement: HostRequirement {
        HostRequirement(
            majorVersion: 27,
            reason: "VZMacGuestProvisioningOptions is a macOS 27 API, and a guest older than "
                + "that ignores it and boots into Setup Assistant"
        )
    }

    var requiredFreeBytes: Int64 { 80 * 1024 * 1024 * 1024 }

    func makeCredentials(
        username: String,
        fullName: String,
        paths: VMBundlePaths
    ) async throws -> GuestCredentials {
        GuestCredentials(
            fullName: fullName,
            username: username,
            authentication: .password(GuestPassword.generate())
        )
    }

    func prepareRun(_ request: ProvisioningRequest) async throws {}

    @MainActor
    func makeRunConfiguration(
        _ request: RunConfigurationRequest
    ) throws -> VZVirtualMachineConfiguration {
        try VMConfigurationFactory.makeMacRunConfiguration(request)
    }

    @MainActor
    func makeStartOptions(_ request: ProvisioningRequest) throws -> VZVirtualMachineStartOptions? {
        guard case let .password(password) = request.credentials.authentication else {
            throw VivError(
                .provisioning,
                "A macOS guest is provisioned with an account password, and this run has none."
            )
        }
        return try GuestProvisioner.makeStartOptions(
            fullName: request.credentials.fullName,
            username: request.credentials.username,
            password: password,
            logsInAutomatically: request.logsInAutomatically,
            enablesRemoteLogin: !request.disablesRemoteLogin
        )
    }

    var runShutdownOrder: ShutdownOrder { .inGuestFirst }

    var assertsArtifactDisk: Bool { true }
    var supportsSystemDiskValidation: Bool { true }
}
