import Foundation
import Virtualization

struct LinuxPlatform: GuestPlatform {
    let os: GuestOS

    var scripts: GuestScripts {
        GuestScripts(
            dialect: .bash,
            shellExecutable: "/bin/bash",
            sharePath: CloudInitSeed.shareMountPath,
            readinessCommand: "/usr/bin/cloud-init status --wait > /dev/null 2>&1; "
                + "status=$?; [ $status -eq 0 ] || [ $status -eq 2 ] || exit $status; "
                + "/usr/bin/id -un",
            shutdownCommand: "/usr/bin/sudo -n /usr/sbin/shutdown -h now",
            shutdownWantsPasswordOnStdin: false,
            diagnosticsScript: """
                echo '--- id'; /usr/bin/id || true
                echo '--- mounts'; /usr/bin/findmnt || /usr/bin/mount || true
                echo '--- block devices'; /usr/bin/lsblk -f || true
                echo '--- share'; /usr/bin/ls -la \(ShellEscaping.singleQuoted(CloudInitSeed.shareMountPath)) || true
                echo '--- disk space'; /usr/bin/df -h || true
                echo '--- cloud-init status'; /usr/bin/cloud-init status --long || true
                echo '--- cloud-init log'; /usr/bin/tail -n 200 /var/log/cloud-init.log || true
                echo '--- sshd'; /usr/bin/systemctl --no-pager status sshd || true
                echo '--- failed units'; /usr/bin/systemctl --no-pager --failed || true
                echo '--- uptime'; /usr/bin/uptime || true
                """
        )
    }

    var templateFilenames: [String] { [VMBundlePaths.systemDiskFilename] }

    var identityDigestFilenames: [String] { [] }

    var templateSuppliesMACAddress: Bool { false }

    var hostRequirement: HostRequirement {
        HostRequirement(
            majorVersion: 13,
            reason: "VZEFIBootLoader, which is how a Linux guest boots, is a macOS 13 API"
        )
    }

    var requiredFreeBytes: Int64 { 20 * 1024 * 1024 * 1024 }

    func makeCredentials(
        username: String,
        fullName: String,
        paths: VMBundlePaths
    ) async throws -> GuestCredentials {
        let authentication = try await GuestKeyPair.generate(
            at: paths.sshPrivateKey,
            comment: "vivarium@\(paths.root.lastPathComponent)"
        )
        return GuestCredentials(
            fullName: fullName,
            username: username,
            authentication: authentication
        )
    }

    func prepareRun(_ request: ProvisioningRequest) async throws {
        guard case let .privateKey(_, publicKey) = request.credentials.authentication else {
            throw VivError(
                .provisioning,
                "A \(os.displayName) guest is provisioned with an SSH public key, and this run "
                    + "has none."
            )
        }
        try await CloudInitSeed.write(
            to: request.paths.seedImage,
            request: request,
            publicKey: publicKey
        )
    }

    @MainActor
    func makeRunConfiguration(
        _ request: RunConfigurationRequest
    ) throws -> VZVirtualMachineConfiguration {
        try VMConfigurationFactory.makeLinuxRunConfiguration(request)
    }

    @MainActor
    func makeStartOptions(_ request: ProvisioningRequest) throws -> VZVirtualMachineStartOptions? {
        nil
    }

    var runShutdownOrder: ShutdownOrder { .requestStopFirst }

    var assertsArtifactDisk: Bool { false }

    var supportsSystemDiskValidation: Bool { false }
}
