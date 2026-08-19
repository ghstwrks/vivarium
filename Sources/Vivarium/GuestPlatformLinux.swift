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

    /// Writes the seed, and nothing else.
    ///
    /// The share needs no preparation, which is worth recording because it is
    /// not obvious and was measured rather than assumed: Apple's VirtioFS
    /// presents every file in the share to the guest as owned by the guest's
    /// own uid and gid, whatever the host's ownership is. A directory this host
    /// user owns at mode 0700 is writable by the guest's unprivileged account.
    /// Nothing here therefore has to reconcile a host uid with a guest one —
    /// and if that ever changes, the workdir preparation script already refuses
    /// with "the artifact directory is not writable by vivadmin", which is the
    /// failure saying exactly what happened.
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
