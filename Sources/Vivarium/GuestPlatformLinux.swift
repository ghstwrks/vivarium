import Foundation
import Virtualization

/// A Linux guest, imported from a published disk image and provisioned by
/// cloud-init on its first boot.
///
/// Parameterised by `os` rather than written once per distribution, because
/// every distribution that publishes a cloud image is provisioned the same way
/// and differs only in which image it publishes — which is a catalogue entry,
/// not a code path. Ubuntu, when it arrives, is expected to be one case in
/// `GuestOS`, one entry in `LinuxImageCatalogue`, and nothing here.
struct LinuxPlatform: GuestPlatform {
    let os: GuestOS

    var scripts: GuestScripts {
        GuestScripts(
            dialect: .bash,
            shellExecutable: "/bin/bash",
            sharePath: CloudInitSeed.shareMountPath,
            // The guest is not ready when sshd answers: cloud-init is still
            // creating the account and mounting the share, and a run that
            // started work between those two moments would fail complaining
            // that its own code was missing. `--wait` blocks until cloud-init
            // has finished; status 2 is "finished, with a warning", which is
            // still finished, and a run should not be thrown away for one.
            readinessCommand: "/usr/bin/cloud-init status --wait > /dev/null 2>&1; "
                + "status=$?; [ $status -eq 0 ] || [ $status -eq 2 ] || exit $status; "
                + "/usr/bin/id -un",
            // The account has passwordless sudo and no password at all, so
            // there is nothing to feed this on stdin.
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

    // MARK: - Templates

    /// A Linux template is a disk image and nothing else.
    ///
    /// There is no platform identity to keep consistent with it: the firmware's
    /// variable store is created fresh with each run, and the MAC address is
    /// generated per run so that two guests are never confusable in the ARP
    /// cache. That leaves the disk, which is the whole guest.
    var templateFilenames: [String] { [VMBundlePaths.systemDiskFilename] }

    /// Nothing to digest. A digest over an empty set of files is a constant,
    /// and a constant asserted every run is a check that cannot fail — which is
    /// worse than no check, because it reads like one.
    var identityDigestFilenames: [String] { [] }

    var templateSuppliesMACAddress: Bool { false }

    // MARK: - Preflight

    var hostRequirement: HostRequirement {
        HostRequirement(
            majorVersion: 13,
            reason: "VZEFIBootLoader, which is how a Linux guest boots, is a macOS 13 API"
        )
    }

    /// Room for the published image on its way in, the template it becomes, and
    /// a run's worth of writing on top. An order of magnitude less than a macOS
    /// guest needs, because a Fedora cloud image is an order of magnitude
    /// smaller than a macOS install.
    var requiredFreeBytes: Int64 { 20 * 1024 * 1024 * 1024 }

    // MARK: - Running

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
        try openShareToTheGuest(request)
    }

    /// Opens the share to whatever account the guest ends up running as.
    ///
    /// VirtioFS presents the host's own ownership to the guest — a directory
    /// this user owns arrives in the guest owned by this user's numeric uid,
    /// which is a number the guest has no account for. The guest's account is
    /// therefore "other" on every file in the share, and mode 0755 leaves it
    /// unable to write the marker or an artifact. The two directories the guest
    /// is supposed to write are opened to it; the staged code stays as it was,
    /// because the guest only reads it.
    ///
    /// The sticky bit is set for the same reason `ArtifactDiskManager` sets it
    /// on the artifact volume: it costs nothing and keeps one account from
    /// deleting another's file, which preserves the meaning of a file found
    /// there later. Both directories are inside one run's own directory under
    /// the Vivarium home, and both go when the run does.
    private func openShareToTheGuest(_ request: ProvisioningRequest) throws {
        var directories = [request.paths.sharedDirectory]
        if request.hasArtifactDirectory {
            directories.append(
                VMBundlePaths.sharedArtifacts(inShare: request.paths.sharedDirectory)
            )
        }
        for directory in directories {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o1777))],
                    ofItemAtPath: directory.path
                )
            } catch {
                throw VivError(
                    .provisioning,
                    "Cannot open \(directory.path) to the guest. Without it the guest cannot "
                        + "write to the share, and nothing would be harvested.",
                    underlying: error,
                    inspectionHints: ["ls -ld \(directory.path)"]
                )
            }
        }
    }

    @MainActor
    func makeRunConfiguration(
        _ request: RunConfigurationRequest
    ) throws -> VZVirtualMachineConfiguration {
        try VMConfigurationFactory.makeLinuxRunConfiguration(request)
    }

    /// None. Everything a Linux guest is told about itself is on the seed image
    /// its configuration already carries, so `start` has nothing to add.
    @MainActor
    func makeStartOptions(_ request: ProvisioningRequest) throws -> VZVirtualMachineStartOptions? {
        nil
    }

    // MARK: - Shutdown

    /// `requestStop()` is an ACPI power-button press, and systemd answers one
    /// by powering off. Unlike a macOS guest — where the same press raises a
    /// confirmation dialog nobody is there to click — this is the mechanism
    /// designed for the job, and it works without a live SSH session, which is
    /// exactly when a shutdown is most needed.
    var runShutdownOrder: ShutdownOrder { .requestStopFirst }

    // MARK: - Acceptance

    /// The detached-storage proof is a statement about the Virtualization
    /// framework — that a guest's write to a block device survives the machine
    /// being released — and not about the guest, so it is asserted once, by the
    /// macOS selftest, rather than reimplemented against a filesystem both a
    /// Linux guest and `diskutil` can agree on. `RunReport` records the three
    /// criteria as not asserted rather than as passed.
    var assertsArtifactDisk: Bool { false }

    /// The system disk is btrfs, which the host cannot mount.
    var supportsSystemDiskValidation: Bool { false }
}
