import Foundation

/// Creates the separate block device the detached-storage proof needs.
///
/// The VirtioFS share cannot stand in for this. A VirtioFS path is backed by a
/// host *directory*, so a marker found there proves directory sharing worked —
/// it says nothing about whether a guest's write reached a disk image that can
/// later be detached and mounted on its own. Hence a second, deliberately
/// small, RAW image.
enum ArtifactDiskManager {
    /// RAW rather than ASIF: RAW is trivially attachable by both Virtualization
    /// and host `diskutil`, and at 1 GiB the space cost of the simpler format
    /// is irrelevant. The system disk keeps ASIF.
    static let sizeBytes: off_t = 1024 * 1024 * 1024

    /// Creates, partitions, formats, and detaches the artifact disk.
    ///
    /// Formatting happens on the host so the guest only has to *find* a volume
    /// with a known name, keeping the remote script's job to "write a file".
    static func create(paths: VMBundlePaths, volumeName: String) async throws {
        guard !FileManager.default.fileExists(atPath: paths.artifactDisk.path) else {
            throw VivError(
                .bundlePreparation,
                "\(paths.artifactDisk.path) already exists; refusing to overwrite it."
            )
        }

        try createSparseImage(at: paths.artifactDisk)

        // Attach without mounting: the image is blank, so there is nothing to
        // mount yet, and asking to mount a blank image just produces noise.
        let attachment = try await DiskUtil.attachImage(
            at: paths.artifactDisk,
            readOnly: false,
            mount: false,
            stage: .bundlePreparation
        )

        guard let device = attachment.imageDeviceIdentifier else {
            throw VivError(
                .bundlePreparation,
                "diskutil attached \(paths.artifactDisk.path) but reported no whole-disk device: "
                    + attachment.summary
            )
        }

        do {
            try await DiskUtil.partitionAsAPFS(
                deviceIdentifier: device,
                volumeName: volumeName,
                stage: .bundlePreparation
            )
        } catch {
            await DiskUtil.ejectQuietly(deviceIdentifier: device)
            throw error
        }

        do {
            try await makeGuestWritable(wholeDisk: device, volumeName: volumeName)
        } catch {
            await DiskUtil.ejectQuietly(deviceIdentifier: device)
            throw error
        }

        // `partitionDisk` mounts the new volume; detach it so the image is free
        // for the VM to claim.
        try await DiskUtil.eject(deviceIdentifier: device, stage: .bundlePreparation)
        log.info("Artifact disk ready at \(paths.artifactDisk.path) with volume \(volumeName).")
    }

    /// Opens the new volume's root to the guest's provisioned account.
    ///
    /// `diskutil` creates an APFS volume root owned by `root:wheel` with mode
    /// 0775. The provisioned guest account is in `staff` and `admin` but not
    /// `wheel`, so the guest cannot write while ownership is enforced.
    ///
    /// The host can change the mode without privileges because image-backed
    /// volumes mount `noowners`; the mode is stored on disk and enforced when
    /// the guest mounts the volume.
    ///
    /// 1777 rather than 0777: the sticky bit keeps one account from deleting
    /// another's marker, which costs nothing and preserves the meaning of a
    /// marker found later.
    private static func makeGuestWritable(wholeDisk device: String, volumeName: String) async throws {
        let volume = try await DiskUtil.apfsVolume(
            onWholeDisk: device,
            named: volumeName,
            stage: .bundlePreparation
        )

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o1777))],
                ofItemAtPath: volume.mountPoint
            )
        } catch {
            throw VivError(
                .bundlePreparation,
                "Could not make \(volume.mountPoint) writable by the guest.",
                underlying: error,
                inspectionHints: ["ls -ld \(volume.mountPoint)"]
            )
        }
        log.debug("Set mode 1777 on \(volume.mountPoint) so the guest account can write to it.")
    }

    /// Creates a sparse file of the target size.
    ///
    /// `ftruncate` allocates no blocks on APFS, so the 1 GiB image costs
    /// nothing until the guest writes to it.
    private static func createSparseImage(at url: URL) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor != -1 else {
            throw VivError(
                .bundlePreparation,
                "Cannot create \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }

        guard ftruncate(descriptor, sizeBytes) == 0 else {
            throw VivError(
                .bundlePreparation,
                "ftruncate on \(url.path) failed: \(String(cString: strerror(errno)))"
            )
        }
    }
}
