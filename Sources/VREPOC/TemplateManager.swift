import Foundation

/// Clones post-restore bundles so that provisioning can be iterated on.
///
/// macOS evaluates `VZMacGuestProvisioningOptions` only on the first boot after
/// restore, and the framework cannot use them to reconfigure a guest it has
/// already provisioned. Every failed provisioning experiment therefore consumes
/// one restore. Without a template that is roughly ninety minutes per attempt,
/// which is the difference between a POC that can be iterated on in an
/// afternoon and one that cannot.
enum TemplateManager {
    /// Snapshots a freshly restored bundle.
    ///
    /// Must be called after installation and strictly *before* the first
    /// provisioned start: booting first burns the one provisionable boot the
    /// template exists to preserve.
    static func snapshot(
        from bundle: VMBundlePaths,
        to template: TemplatePaths,
        restoreImage: LoadedRestoreImage,
        ipswSHA256: String?,
        runID: String
    ) async throws {
        let manager = FileManager.default

        if manager.fileExists(atPath: template.root.path) {
            log.info("Template \(template.root.path) already exists; leaving it untouched.")
            return
        }

        do {
            try manager.createDirectory(at: template.root, withIntermediateDirectories: true)
        } catch {
            throw POCError(
                .templateSnapshot,
                "Failed to create \(template.root.path).",
                underlying: error
            )
        }

        // Only the platform identity and the restored system disk. Artifact.raw,
        // Shared/, and every result file are per-run and are recreated by
        // `provision`; copying them would make the template a stale run.
        for filename in VMBundlePaths.platformIdentityFilenames {
            let source = bundle.root.appendingPathComponent(filename)
            let destination = template.root.appendingPathComponent(filename)
            guard manager.fileExists(atPath: source.path) else {
                throw POCError(
                    .templateSnapshot,
                    "Cannot snapshot \(bundle.root.path): \(filename) is missing."
                )
            }
            try await clone(from: source, to: destination, stage: .templateSnapshot)
        }

        let manifest = TemplateManifest(
            ipswBuild: restoreImage.buildVersion,
            ipswVersion: restoreImage.versionString,
            ipswSHA256: ipswSHA256,
            createdAt: Date(),
            platformIdentitySHA256: try platformIdentityDigest(root: template.root),
            systemDiskByteCount: BundleManager.fileSize(
                of: template.root.appendingPathComponent("Disk.img")
            ),
            createdByRunID: runID
        )
        try JSONCoding.write(manifest, to: template.manifest)

        log.info("Template snapshot written to \(template.root.path).")
    }

    /// Clones a template into a fresh run bundle.
    ///
    /// The template is treated as immutable and is never booted in place.
    static func materialize(
        template: TemplatePaths,
        into bundle: VMBundlePaths,
        expectedIPSWBuild: String?
    ) async throws -> TemplateManifest {
        let manager = FileManager.default
        guard manager.fileExists(atPath: template.manifest.path) else {
            throw POCError(
                .templateSnapshot,
                "\(template.root.path) has no template.json; it is not a template bundle.",
                inspectionHints: ["ls -la \(template.root.path)"]
            )
        }

        let manifest = try JSONCoding.read(
            TemplateManifest.self, from: template.manifest, stage: .templateSnapshot
        )

        if let expectedIPSWBuild, manifest.ipswBuild != expectedIPSWBuild {
            throw POCError(
                .templateSnapshot,
                "Template \(template.root.path) was restored from IPSW build "
                    + "\(manifest.ipswBuild), but this run requested build \(expectedIPSWBuild). "
                    + "Booting a mismatched template would test a different guest than the one asked for."
            )
        }

        for filename in VMBundlePaths.platformIdentityFilenames {
            let source = template.root.appendingPathComponent(filename)
            let destination = bundle.root.appendingPathComponent(filename)
            guard manager.fileExists(atPath: source.path) else {
                throw POCError(
                    .templateSnapshot,
                    "Template \(template.root.path) is incomplete: \(filename) is missing."
                )
            }
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try await clone(from: source, to: destination, stage: .templateSnapshot)
        }

        let digest = try platformIdentityDigest(root: bundle.root)
        guard digest == manifest.platformIdentitySHA256 else {
            throw POCError(
                .templateSnapshot,
                "The cloned platform identity digest (\(digest)) does not match the template's "
                    + "recorded digest (\(manifest.platformIdentitySHA256)). The clone is not trustworthy."
            )
        }

        log.info("Materialized template \(template.root.path) into \(bundle.root.path).")
        return manifest
    }

    /// Copies with APFS cloning.
    ///
    /// `cp -c` requests `clonefile`, which makes a 128 GiB sparse system disk
    /// cost seconds and near-zero space instead of a full duplication. It is
    /// requested explicitly rather than relying on `FileManager` doing it,
    /// because a silent fall back to a byte copy would turn a "seconds" step
    /// into a "minutes and tens of gigabytes" step without saying so.
    private static func clone(from source: URL, to destination: URL, stage: POCStage) async throws {
        let result = try await ProcessRunner.run(
            "/bin/cp", ["-c", "-R", source.path, destination.path],
            timeout: .seconds(300),
            stage: stage
        )
        if result.succeeded { return }

        log.warn(
            "clonefile copy of \(source.lastPathComponent) failed "
                + "(\(result.stderrText.trimmed(to: 300))); falling back to a full copy."
        )
        try await ProcessRunner.runChecked(
            "/bin/cp", ["-R", source.path, destination.path],
            timeout: .seconds(1800),
            stage: stage
        )
    }

    /// A digest over the small identity files.
    ///
    /// The system disk is excluded on purpose: it is a sparse image whose full
    /// hash costs minutes per check, and it is not what determines whether a
    /// platform identity is internally consistent. Its size is recorded in the
    /// manifest separately as a coarse integrity signal.
    private static func platformIdentityDigest(root: URL) throws -> String {
        var combined = Data()
        for filename in ["AuxiliaryStorage", "HardwareModel", "MachineIdentifier", "MACAddress"] {
            let url = root.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url) else {
                throw POCError(.templateSnapshot, "Cannot read \(url.path) for digesting.")
            }
            combined.append(Data(filename.utf8))
            combined.append(data)
        }
        return Digest.sha256Hex(combined)
    }
}
