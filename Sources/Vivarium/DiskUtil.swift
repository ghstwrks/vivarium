import Foundation

/// One element of `diskutil`'s `system-entities` array.
struct DiskSystemEntity: Sendable {
    let devEntry: String
    let contentHint: String?
    let volumeName: String?
    let filesystemType: String?
    let mountPoint: String?

    /// `disk16s1` for `/dev/disk16s1`.
    var deviceIdentifier: String {
        devEntry.hasPrefix("/dev/") ? String(devEntry.dropFirst(5)) : devEntry
    }

    /// Whether this is a whole disk rather than a slice.
    var isWholeDisk: Bool {
        !deviceIdentifier.dropFirst(4).contains("s")
    }
}

/// The result of attaching a disk image.
struct DiskAttachment: Sendable {
    let entities: [DiskSystemEntity]

    /// The device node representing the image itself.
    ///
    /// Attaching an APFS image produces *two* whole disks — the image's own
    /// device carrying the partition map, and a synthesised device for the APFS
    /// container — usually with different numbers. `diskutil eject` must target
    /// the image's device, which is the first whole disk `diskutil` reports.
    var imageDeviceIdentifier: String? {
        entities.first(where: \.isWholeDisk)?.deviceIdentifier
    }

    var allDeviceIdentifiers: [String] {
        entities.map(\.deviceIdentifier)
    }

    func entity(volumeNamed name: String) -> DiskSystemEntity? {
        entities.first { $0.volumeName == name && $0.contentHint == "Apple_APFS_Volume" }
            ?? entities.first { $0.volumeName == name }
    }

    var summary: String {
        entities.map { entity in
            var text = "\(entity.deviceIdentifier) \(entity.contentHint ?? "-")"
            if let volumeName = entity.volumeName { text += " volume-name=\(volumeName)" }
            if let mountPoint = entity.mountPoint { text += " mount-point=\(mountPoint)" }
            return text
        }.joined(separator: "; ")
    }
}

enum DiskUtil {
    static let executable = "/usr/sbin/diskutil"

    /// Attaches a disk image and returns its parsed device layout.
    ///
    /// Note the flag position: `--plist` is an option of the `image` verb, so
    /// `diskutil --plist image attach` is rejected outright.
    static func attachImage(
        at url: URL,
        readOnly: Bool,
        mount: Bool,
        stage: VivStage
    ) async throws -> DiskAttachment {
        var arguments = ["image", "--plist", "attach"]
        if readOnly { arguments.append("--readOnly") }
        if !mount { arguments.append("--noMount") }
        arguments.append(url.path)

        let result = try await ProcessRunner.run(
            executable, arguments,
            timeout: .seconds(120),
            stage: stage
        )

        guard result.succeeded else {
            throw VivError(
                stage,
                "Failed to attach \(url.path): \(result.summary)\n"
                    + "  stderr: \(result.stderrText.trimmed(to: 2000))",
                inspectionHints: [
                    "diskutil list",
                    "\(executable) \(arguments.joined(separator: " "))"
                ]
            )
        }

        let attachment = try parseAttachPlist(result.stdout, stage: stage)
        log.info("Attached \(url.lastPathComponent): \(attachment.summary)")
        return attachment
    }

    static func parseAttachPlist(_ data: Data, stage: VivStage) throws -> DiskAttachment {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw VivError(stage, "diskutil returned output that is not a property list.", underlying: error)
        }

        guard let root = plist as? [String: Any],
              let rawEntities = root["system-entities"] as? [[String: Any]] else {
            throw VivError(stage, "diskutil's plist has no system-entities array.")
        }

        let entities = rawEntities.compactMap { raw -> DiskSystemEntity? in
            guard let devEntry = raw["dev-entry"] as? String else { return nil }
            return DiskSystemEntity(
                devEntry: devEntry,
                contentHint: raw["content-hint"] as? String,
                volumeName: raw["volume-name"] as? String,
                filesystemType: raw["filesystem-type"] as? String,
                mountPoint: raw["mount-point"] as? String
            )
        }

        guard !entities.isEmpty else {
            throw VivError(stage, "diskutil attached the image but reported no devices.")
        }

        return DiskAttachment(entities: entities)
    }

    /// Mounts one device, optionally read-only.
    static func mount(
        deviceIdentifier: String,
        readOnly: Bool,
        stage: VivStage
    ) async throws -> String {
        var arguments = ["mount"]
        if readOnly { arguments.append("readOnly") }
        arguments.append(deviceIdentifier)

        let result = try await ProcessRunner.runChecked(
            executable, arguments,
            timeout: .seconds(120),
            stage: stage,
            inspectionHints: ["diskutil info \(deviceIdentifier)"]
        )

        // "Volume VivArtifacts on <device> mounted"; the authoritative mount
        // point comes from `diskutil info`, not from parsing this sentence.
        _ = result
        return try await mountPoint(deviceIdentifier: deviceIdentifier, stage: stage)
    }

    static func mountPoint(deviceIdentifier: String, stage: VivStage) async throws -> String {
        let result = try await ProcessRunner.runChecked(
            executable, ["info", "-plist", deviceIdentifier],
            timeout: .seconds(60),
            stage: stage
        )
        guard let plist = try? PropertyListSerialization.propertyList(
            from: result.stdout, options: [], format: nil
        ) as? [String: Any],
            let path = plist["MountPoint"] as? String,
            !path.isEmpty else {
            throw VivError(stage, "\(deviceIdentifier) reports no mount point.")
        }
        return path
    }

    /// Partitions a freshly attached blank image with a single APFS volume.
    static func partitionAsAPFS(
        deviceIdentifier: String,
        volumeName: String,
        stage: VivStage
    ) async throws {
        try await ProcessRunner.runChecked(
            executable,
            ["partitionDisk", deviceIdentifier, "GPT", "APFS", volumeName, "100%"],
            timeout: .seconds(300),
            stage: stage,
            inspectionHints: ["diskutil list \(deviceIdentifier)"]
        )
    }

    /// Locates the single APFS volume created on a freshly partitioned image.
    ///
    /// Resolved by following the image's own partition to its container rather
    /// than by asking `diskutil` for the volume name: names are not unique
    /// across attached disks, and this result is used to change permissions, so
    /// picking a same-named volume belonging to something else would be a
    /// destructive mistake. The name is still checked, as an assertion that the
    /// chain led where it was supposed to.
    static func apfsVolume(
        onWholeDisk deviceIdentifier: String,
        named expectedVolumeName: String,
        stage: VivStage
    ) async throws -> (deviceIdentifier: String, mountPoint: String) {
        let partition = "\(deviceIdentifier)s1"
        let partitionInfo = try await infoPlist(deviceIdentifier: partition, stage: stage)
        guard let container = partitionInfo["APFSContainerReference"] as? String,
              !container.isEmpty else {
            throw VivError(
                stage,
                "\(partition) reports no APFS container reference.",
                inspectionHints: ["diskutil info \(partition)"]
            )
        }

        let volume = "\(container)s1"
        let volumeInfo = try await infoPlist(deviceIdentifier: volume, stage: stage)
        guard let name = volumeInfo["VolumeName"] as? String, name == expectedVolumeName else {
            throw VivError(
                stage,
                "\(volume) is named \(volumeInfo["VolumeName"] as? String ?? "<none>"), "
                    + "not \(expectedVolumeName).",
                inspectionHints: ["diskutil list \(container)"]
            )
        }
        guard let mountPoint = volumeInfo["MountPoint"] as? String, !mountPoint.isEmpty else {
            throw VivError(
                stage,
                "\(volume) (\(expectedVolumeName)) is not mounted.",
                inspectionHints: ["diskutil info \(volume)"]
            )
        }
        return (volume, mountPoint)
    }

    private static func infoPlist(
        deviceIdentifier: String,
        stage: VivStage
    ) async throws -> [String: Any] {
        let result = try await ProcessRunner.runChecked(
            executable, ["info", "-plist", deviceIdentifier],
            timeout: .seconds(60),
            stage: stage
        )
        guard let plist = try? PropertyListSerialization.propertyList(
            from: result.stdout, options: [], format: nil
        ) as? [String: Any] else {
            throw VivError(stage, "Could not parse `diskutil info -plist \(deviceIdentifier)`.")
        }
        return plist
    }

    /// Ejects a device, retrying while the resource is still busy.
    ///
    /// A disk image released by the Virtualization framework moments earlier is
    /// routinely still held for a short while, and treating that transient
    /// state as a hard failure would make validation flaky for no good reason.
    @discardableResult
    static func eject(
        deviceIdentifier: String,
        stage: VivStage,
        attempts: Int = 10
    ) async throws -> Bool {
        for attempt in 1...attempts {
            let result = try await ProcessRunner.run(
                executable, ["eject", deviceIdentifier],
                timeout: .seconds(60),
                stage: stage
            )
            if result.succeeded {
                log.info("Ejected \(deviceIdentifier).")
                return true
            }
            let message = (result.stderrText + result.stdoutText).trimmed(to: 400)
            log.warn("Eject attempt \(attempt)/\(attempts) for \(deviceIdentifier) failed: \(message)")
            if attempt < attempts {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        throw VivError(
            stage,
            "Could not eject \(deviceIdentifier) after \(attempts) attempts.",
            inspectionHints: [
                "diskutil info \(deviceIdentifier)",
                "lsof | grep \(deviceIdentifier)"
            ]
        )
    }

    /// Ejects without throwing, for `defer` cleanup paths.
    static func ejectQuietly(deviceIdentifier: String) async {
        _ = try? await eject(deviceIdentifier: deviceIdentifier, stage: .cleanup, attempts: 5)
    }
}
