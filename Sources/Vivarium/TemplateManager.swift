import Foundation

/// Clones pristine guest images so that runs can be cheap and identical.
///
/// The reason differs by guest and the mechanism does not. macOS evaluates
/// `VZMacGuestProvisioningOptions` only on the first boot after restore, and
/// the framework cannot use them to reconfigure a guest it has already
/// provisioned, so every failed provisioning experiment would otherwise consume
/// a ninety-minute restore. A Linux guest imported from a published disk image
/// costs minutes rather than an afternoon, but booting the imported image
/// directly would leave every run's state — its host keys, its logs, its
/// package cache, whatever the last test wrote — in the image the next run
/// starts from, which is the same problem wearing different clothes.
///
/// The answer to both is the same and is the only invariant this type has: a
/// template is immutable and is never booted in place. A run clones it, boots
/// the clone, and throws the clone away.
enum TemplateManager {
    /// Snapshots a bundle as a template.
    ///
    /// For macOS this must be called after installation and strictly *before*
    /// the first provisioned start: booting first burns the one provisionable
    /// boot the template exists to preserve.
    static func snapshot(
        from bundle: VMBundlePaths,
        to template: TemplatePaths,
        platform: any GuestPlatform,
        osVersion: String,
        osBuild: String,
        source: String?,
        sourceSHA256: String?,
        runID: String?
    ) async throws {
        let manager = FileManager.default

        if manager.fileExists(atPath: template.root.path) {
            log.info("Template \(template.root.path) already exists; leaving it untouched.")
            return
        }

        do {
            try manager.createDirectory(at: template.root, withIntermediateDirectories: true)
        } catch {
            throw VivError(
                .templateSnapshot,
                "Failed to create \(template.root.path).",
                underlying: error
            )
        }

        // Only what the platform says a guest needs to exist. Artifact.raw,
        // Shared/, the seed image, the EFI variable store, and every result
        // file are per-run and are recreated by the run that needs them;
        // copying them would make the template a stale run.
        for filename in platform.templateFilenames {
            let source = bundle.root.appendingPathComponent(filename)
            let destination = template.root.appendingPathComponent(filename)
            guard manager.fileExists(atPath: source.path) else {
                throw VivError(
                    .templateSnapshot,
                    "Cannot snapshot \(bundle.root.path): \(filename) is missing."
                )
            }
            try await clone(from: source, to: destination, stage: .templateSnapshot)
        }

        try writeManifest(
            to: template,
            platform: platform,
            osVersion: osVersion,
            osBuild: osBuild,
            source: source,
            sourceSHA256: sourceSHA256,
            systemDiskSHA256: nil,
            runID: runID
        )
        log.info("Template snapshot written to \(template.root.path).")
    }

    /// Writes a template's `template.json`.
    ///
    /// Separate from `snapshot` because a template does not have to come from a
    /// bundle: an imported disk image is written into the template directory
    /// directly, and then described by the same record.
    static func writeManifest(
        to template: TemplatePaths,
        platform: any GuestPlatform,
        osVersion: String,
        osBuild: String,
        source: String?,
        sourceSHA256: String?,
        systemDiskSHA256: String?,
        runID: String?
    ) throws {
        let manifest = TemplateManifest(
            os: platform.os,
            osVersion: osVersion,
            osBuild: osBuild,
            sourceSHA256: sourceSHA256,
            source: source,
            createdAt: Date(),
            platformIdentitySHA256: platform.identityDigestFilenames.isEmpty
                ? nil
                : try identityDigest(root: template.root, filenames: platform.identityDigestFilenames),
            systemDiskByteCount: BundleManager.fileSize(
                of: template.root.appendingPathComponent(VMBundlePaths.systemDiskFilename)
            ),
            systemDiskSHA256: systemDiskSHA256,
            createdByRunID: runID
        )
        try JSONCoding.write(manifest, to: template.manifest)
    }

    /// Reads a template's record without touching anything else in it.
    ///
    /// This is how a run learns which operating system it is about to start:
    /// the template says so, and every platform-specific decision after this
    /// point follows from the answer rather than from a flag the caller
    /// remembered to pass.
    static func readManifest(of template: TemplatePaths) throws -> TemplateManifest {
        guard FileManager.default.fileExists(atPath: template.manifest.path) else {
            throw VivError(
                .templateSnapshot,
                "\(template.root.path) has no template.json; it is not a template bundle.",
                inspectionHints: ["ls -la \(template.root.path)"]
            )
        }
        return try JSONCoding.read(
            TemplateManifest.self, from: template.manifest, stage: .templateSnapshot
        )
    }

    /// Clones a template into a fresh run bundle.
    ///
    /// The template is treated as immutable and is never booted in place.
    static func materialize(
        template: TemplatePaths,
        into bundle: VMBundlePaths,
        expectedBuild: String?
    ) async throws -> TemplateManifest {
        let manager = FileManager.default
        let manifest = try readManifest(of: template)
        let platform = manifest.os.platform

        if let expectedBuild, manifest.osBuild != expectedBuild {
            throw VivError(
                .templateSnapshot,
                "Template \(template.root.path) was built from \(manifest.os.displayName) "
                    + "\(manifest.osBuild), but this run requested \(expectedBuild). "
                    + "Booting a mismatched template would test a different guest than the one asked for."
            )
        }

        for filename in platform.templateFilenames {
            let source = template.root.appendingPathComponent(filename)
            let destination = bundle.root.appendingPathComponent(filename)
            guard manager.fileExists(atPath: source.path) else {
                throw VivError(
                    .templateSnapshot,
                    "Template \(template.root.path) is incomplete: \(filename) is missing."
                )
            }
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try await clone(from: source, to: destination, stage: .templateSnapshot)
        }

        if let recorded = manifest.platformIdentitySHA256 {
            let digest = try identityDigest(
                root: bundle.root, filenames: platform.identityDigestFilenames
            )
            guard digest == recorded else {
                throw VivError(
                    .templateSnapshot,
                    "The cloned platform identity digest (\(digest)) does not match the template's "
                        + "recorded digest (\(recorded)). The clone is not trustworthy."
                )
            }
        }

        log.info("Materialized template \(template.root.path) into \(bundle.root.path).")
        return manifest
    }

    /// Copies with APFS cloning.
    ///
    /// `cp -c` requests `clonefile`, which makes a large sparse system disk
    /// cost seconds and near-zero space instead of a full duplication. It is
    /// requested explicitly rather than relying on `FileManager` doing it,
    /// because a silent fall back to a byte copy would turn a "seconds" step
    /// into a "minutes and tens of gigabytes" step without saying so.
    ///
    /// The fall back is still there, and is the reason nothing further up
    /// depends on APFS: on a filesystem with no `clonefile` a template still
    /// materialises, only slower. That is what keeps a run's isolation a
    /// property of the design rather than of the volume it happens to be on.
    static func clone(from source: URL, to destination: URL, stage: VivStage) async throws {
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
    private static func identityDigest(root: URL, filenames: [String]) throws -> String {
        var combined = Data()
        for filename in filenames {
            let url = root.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url) else {
                throw VivError(.templateSnapshot, "Cannot read \(url.path) for digesting.")
            }
            combined.append(Data(filename.utf8))
            combined.append(data)
        }
        return Digest.sha256Hex(combined)
    }
}
