import Foundation
import Virtualization

/// A macOS guest, restored from an IPSW and provisioned by the framework on its
/// first boot.
///
/// Everything here is what Vivarium did before it could run anything else; the
/// point of gathering it behind `GuestPlatform` is that none of it is assumed
/// any more.
struct MacOSPlatform: GuestPlatform {
    let os: GuestOS = .macOS

    var scripts: GuestScripts {
        GuestScripts(
            dialect: .zsh,
            shellExecutable: "/bin/zsh",
            // Expected, not assumed: the scripts locate the real mount and fail
            // loudly if it is somewhere else, because confirming this path on
            // the selected guest build was one of the POC's open questions;
            // POC-RESULTS.md records macOS 27 mounting the share exactly here.
            sharePath: "/Volumes/My Shared Files",
            readinessCommand: "/usr/bin/id -un",
            // `sudo -S` reads the password from standard input, so it never
            // appears in the guest's process list.
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

    // MARK: - Templates

    /// The files that together constitute the VM's platform identity, plus the
    /// restored disk. They are cloned as a set, because a hardware model paired
    /// with someone else's auxiliary storage does not boot.
    var templateFilenames: [String] {
        ["AuxiliaryStorage", VMBundlePaths.systemDiskFilename,
         "HardwareModel", "MachineIdentifier", "MACAddress"]
    }

    /// The system disk is excluded on purpose: it is a sparse image whose full
    /// hash costs minutes per check, and it is not what determines whether a
    /// platform identity is internally consistent. Its size is recorded in the
    /// manifest separately as a coarse integrity signal.
    var identityDigestFilenames: [String] {
        ["AuxiliaryStorage", "HardwareModel", "MachineIdentifier", "MACAddress"]
    }

    var templateSuppliesMACAddress: Bool { true }

    // MARK: - Preflight

    var hostRequirement: HostRequirement {
        HostRequirement(
            majorVersion: 27,
            reason: "VZMacGuestProvisioningOptions is a macOS 27 API, and a guest older than "
                + "that ignores it and boots into Setup Assistant"
        )
    }

    /// Headroom for the restored system disk plus the artifact disk. The system
    /// disk is a 128 GiB sparse image whose actual consumption after a restore
    /// is far smaller, but a run that fills the volume mid-install leaves an
    /// unusable bundle, so the check is deliberately conservative.
    var requiredFreeBytes: Int64 { 80 * 1024 * 1024 * 1024 }

    // MARK: - Running

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

    /// Nothing: a macOS guest is provisioned through start options, which are
    /// handed to `start` rather than written into the bundle.
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

    // MARK: - Shutdown

    /// `viv run` leads with the in-guest shutdown because POC-RESULTS.md is
    /// unequivocal that with auto-login on, `requestStop()` has never once
    /// stopped a provisioned macOS guest, while `shutdown -h now` works every
    /// time in around six seconds.
    var runShutdownOrder: ShutdownOrder { .inGuestFirst }

    // MARK: - Acceptance

    var assertsArtifactDisk: Bool { true }
    var supportsSystemDiskValidation: Bool { true }
}
