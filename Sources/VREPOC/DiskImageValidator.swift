import Foundation

struct ArtifactValidationResult: Codable, Sendable {
    let artifactAttachedReadOnly: Bool
    let volumeName: String
    let markerMatched: Bool
    let markerSHA256: String
    let expectedMarkerSHA256: String
    let markerByteCount: Int
    let markerText: String
    let mountPoint: String
    let deviceIdentifiers: [String]
    let ejected: Bool
}

struct SystemDiskValidationResult: Codable, Sendable {
    let attempted: Bool
    let succeeded: Bool
    let markerMatched: Bool?
    let dataVolumeName: String?
    let mountPoint: String?
    let deviceIdentifiers: [String]
    let ejected: Bool
    let detail: String
}

/// Validates disk images on the host after the VM has released them.
///
/// The whole point is that these checks run against a disk nothing is writing
/// to. A marker read from an image still attached to a live VM would prove
/// nothing about persistence, so every entry point here assumes — and the
/// orchestrator enforces — that the VM is stopped and released first.
enum DiskImageValidator {
    /// Attaches the artifact image read-only and verifies its marker.
    static func validateArtifact(
        paths: VMBundlePaths,
        expectations: RunExpectations
    ) async throws -> ArtifactValidationResult {
        let attachment = try await DiskUtil.attachImage(
            at: paths.artifactDisk,
            readOnly: true,
            mount: true,
            stage: .artifactAttach
        )

        guard let imageDevice = attachment.imageDeviceIdentifier else {
            throw POCError(
                .artifactAttach,
                "diskutil attached the artifact image but reported no whole-disk device: "
                    + attachment.summary
            )
        }

        // Ejection has to happen on every path out of here, including the
        // failure paths, or a failed run leaves a stray device attached and
        // the next run's attach behaves differently.
        var ejected = false
        defer {
            if !ejected {
                let device = imageDevice
                Task.detached { await DiskUtil.ejectQuietly(deviceIdentifier: device) }
            }
        }

        guard let volume = attachment.entity(volumeNamed: expectations.artifactVolumeName) else {
            throw POCError(
                .artifactValidation,
                "No volume named \(expectations.artifactVolumeName) on the artifact image. "
                    + "Devices: \(attachment.summary)",
                inspectionHints: ["diskutil list \(imageDevice)"]
            )
        }

        let mountPoint: String
        if let existing = volume.mountPoint, !existing.isEmpty {
            mountPoint = existing
        } else {
            mountPoint = try await DiskUtil.mount(
                deviceIdentifier: volume.deviceIdentifier,
                readOnly: true,
                stage: .artifactValidation
            )
        }

        try await assertReadOnly(mountPoint: mountPoint)

        let markerURL = URL(fileURLWithPath: mountPoint).appendingPathComponent("vre-result.txt")
        let contents = try readWithoutFollowingSymlinks(at: markerURL, stage: .artifactValidation)

        let digest = Digest.sha256Hex(contents)
        let expected = expectations.markerFileContents
        let matched = contents == expected

        if !matched {
            log.error(
                "Artifact marker mismatch. Expected \(expected.count) bytes "
                    + "(sha256 \(expectations.markerFileSHA256)), found \(contents.count) bytes "
                    + "(sha256 \(digest))."
            )
        }

        try await DiskUtil.eject(deviceIdentifier: imageDevice, stage: .artifactValidation)
        ejected = true

        return ArtifactValidationResult(
            artifactAttachedReadOnly: true,
            volumeName: expectations.artifactVolumeName,
            markerMatched: matched,
            markerSHA256: digest,
            expectedMarkerSHA256: expectations.markerFileSHA256,
            markerByteCount: contents.count,
            markerText: String(decoding: contents, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            mountPoint: mountPoint,
            deviceIdentifiers: attachment.allDeviceIdentifiers,
            ejected: true
        )
    }

    /// Attaches the installed system disk read-only and looks for the marker in
    /// the provisioned user's home directory.
    ///
    /// This is the optional stronger assertion. It is more fragile than the
    /// artifact disk — the system disk is ASIF, and whether current `diskutil
    /// image attach` handles ASIF read-only is an open question — so a failure
    /// here is reported rather than thrown. The artifact disk deliberately does
    /// not share that dependency.
    static func validateSystemDisk(
        paths: VMBundlePaths,
        expectations: RunExpectations,
        username: String
    ) async -> SystemDiskValidationResult {
        var devices: [String] = []
        var imageDevice: String?

        do {
            let attachment = try await DiskUtil.attachImage(
                at: paths.systemDisk,
                readOnly: true,
                mount: false,
                stage: .artifactValidation
            )
            devices = attachment.allDeviceIdentifiers
            imageDevice = attachment.imageDeviceIdentifier

            // Identify the Data volume by APFS role rather than by display
            // name: the name is localised and the Signed System Volume must not
            // be touched. Only the writable Data volume can hold a user home.
            guard let dataVolume = try await findAPFSDataVolume(
                among: attachment,
                stage: .artifactValidation
            ) else {
                throw POCError(
                    .artifactValidation,
                    "No APFS Data volume found on the system disk. Devices: \(attachment.summary)"
                )
            }

            let mountPoint = try await DiskUtil.mount(
                deviceIdentifier: dataVolume.deviceIdentifier,
                readOnly: true,
                stage: .artifactValidation
            )

            let markerURL = URL(fileURLWithPath: mountPoint)
                .appendingPathComponent("Users")
                .appendingPathComponent(username)
                .appendingPathComponent("vre-result.txt")
            let contents = try readWithoutFollowingSymlinks(at: markerURL, stage: .artifactValidation)
            let matched = contents == expectations.markerFileContents

            var ejected = false
            if let imageDevice {
                ejected = (try? await DiskUtil.eject(
                    deviceIdentifier: imageDevice, stage: .artifactValidation
                )) ?? false
            }

            return SystemDiskValidationResult(
                attempted: true,
                succeeded: true,
                markerMatched: matched,
                dataVolumeName: dataVolume.volumeName,
                mountPoint: mountPoint,
                deviceIdentifiers: devices,
                ejected: ejected,
                detail: matched
                    ? "Marker in /Users/\(username)/vre-result.txt matched."
                    : "Marker present but did not match the expected bytes."
            )
        } catch {
            if let imageDevice {
                await DiskUtil.ejectQuietly(deviceIdentifier: imageDevice)
            }
            return SystemDiskValidationResult(
                attempted: true,
                succeeded: false,
                markerMatched: nil,
                dataVolumeName: nil,
                mountPoint: nil,
                deviceIdentifiers: devices,
                ejected: imageDevice != nil,
                detail: POCError.describe(error)
            )
        }
    }

    /// Finds the APFS volume whose role is Data.
    private static func findAPFSDataVolume(
        among attachment: DiskAttachment,
        stage: POCStage
    ) async throws -> DiskSystemEntity? {
        for entity in attachment.entities where entity.contentHint == "Apple_APFS_Volume" {
            let result = try? await ProcessRunner.run(
                DiskUtil.executable, ["info", "-plist", entity.deviceIdentifier],
                timeout: .seconds(60),
                stage: stage
            )
            guard let result, result.succeeded,
                  let plist = try? PropertyListSerialization.propertyList(
                      from: result.stdout, options: [], format: nil
                  ) as? [String: Any] else { continue }

            // APFSVolumeRoles is an array of role strings; "Data" identifies
            // the writable half of a macOS system volume group.
            if let roles = plist["APFSVolumeRoles"] as? [String], roles.contains("Data") {
                return entity
            }
        }
        return nil
    }

    /// Confirms the mount really is read-only.
    ///
    /// The attach was requested read-only, but "requested" and "enforced by the
    /// filesystem" are different claims, and this validation is only meaningful
    /// if the host cannot have modified what it is reading.
    private static func assertReadOnly(mountPoint: String) async throws {
        guard let result = try? await ProcessRunner.run(
            "/sbin/mount", [],
            timeout: .seconds(30),
            stage: .artifactValidation
        ), result.succeeded else {
            log.warn("Could not run mount(8) to confirm the read-only flag.")
            return
        }

        for line in result.stdoutText.split(separator: "\n") where line.contains(" on \(mountPoint) (") {
            guard line.contains("read-only") else {
                throw POCError(
                    .artifactValidation,
                    "\(mountPoint) is mounted but not read-only: \(line)"
                )
            }
            return
        }
        log.warn("mount(8) did not list \(mountPoint); cannot confirm the read-only flag.")
    }

    /// Reads a file, refusing to follow a symlink at the final path component.
    ///
    /// The guest controls the contents of these volumes, so the marker path
    /// could be a link pointing anywhere on the host. `O_NOFOLLOW` keeps a
    /// validation read from becoming a way for guest-controlled data to
    /// redirect a host read.
    private static func readWithoutFollowingSymlinks(at url: URL, stage: POCStage) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor != -1 else {
            let reason = String(cString: strerror(errno))
            throw POCError(
                stage,
                "Cannot read \(url.path): \(reason)",
                inspectionHints: ["ls -la \(url.deletingLastPathComponent().path)"]
            )
        }
        defer { close(descriptor) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw POCError(stage, "Failed while reading \(url.path).", underlying: error)
        }
    }
}
