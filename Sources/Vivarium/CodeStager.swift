import Foundation

/// Copies the user's project into the run's share.
///
/// The original directory is never mounted into a guest and never written to.
/// That costs a copy, and buys the guarantee that a test which deletes its
/// working tree — or a guest that panics mid-write — cannot touch the only copy
/// of anyone's work.
enum CodeStager {
    /// Refuses to stage rather than fill the volume.
    ///
    /// Left over and above the copy, because the run has not yet booted a guest
    /// whose system disk grows as it writes, and a volume with no room left is
    /// a far worse failure than a run that never started.
    static let requiredHeadroomBytes: Int64 = 5 * 1024 * 1024 * 1024

    struct StagedCode: Sendable {
        let source: URL
        let destination: URL
        let byteCount: Int64
        /// Whether the copy was an APFS clone. False means the bytes were
        /// really duplicated, which is what a cross-volume run costs.
        let cloned: Bool
    }

    static func stage(from source: URL, to destination: URL) async throws -> StagedCode {
        let manager = FileManager.default

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VivError(
                .codeStaging,
                "\(source.path) is not a directory, so there is nothing to run tests against."
            )
        }

        let byteCount = await onDiskByteCount(of: source) ?? 0
        try checkSpace(for: byteCount, stagingInto: destination, from: source)

        try remove(destination)
        try createParent(of: destination)

        let cloned = try await copy(from: source, to: destination)
        log.info(
            "Staged \(byteCount.formattedByteCount) of code from \(source.path) into "
                + "\(destination.path)\(cloned ? " (APFS clone)" : " (full copy)")."
        )
        return StagedCode(
            source: source,
            destination: destination,
            byteCount: byteCount,
            cloned: cloned
        )
    }

    /// `cp -c` asks for `clonefile`, which on one APFS volume costs almost
    /// nothing. It is requested explicitly, and its failure logged, because a
    /// silent fall back to a byte copy turns a step measured in milliseconds
    /// into one measured in minutes — the operator should be told which of the
    /// two they are waiting for.
    private static func copy(from source: URL, to destination: URL) async throws -> Bool {
        let clone = try await ProcessRunner.run(
            "/bin/cp", ["-c", "-R", source.path, destination.path],
            timeout: .seconds(900),
            stage: .codeStaging
        )
        if clone.succeeded { return true }

        log.warn(
            "Cloning \(source.path) failed (\(clone.stderrText.trimmed(to: 300))); "
                + "falling back to a full copy, which is slower and costs the space."
        )
        // A partial clone may have been left behind, and a full copy onto it
        // would merge two trees rather than replace one — `cp -R` descends into
        // an existing destination and nests the project inside it. Failing to
        // clear it is therefore fatal: continuing would stage something that is
        // not the project and blame the test for whatever came of it.
        try remove(destination)
        try await ProcessRunner.runChecked(
            "/bin/cp", ["-R", source.path, destination.path],
            timeout: .seconds(3600),
            stage: .codeStaging,
            inspectionHints: ["du -sh \(source.path)"]
        )
        return false
    }

    private static func checkSpace(for byteCount: Int64, stagingInto destination: URL, from source: URL) throws {
        let probe = destination.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }

        // A clone within one volume shares its blocks, so only a copy that
        // really has to move the bytes is measured against the free space.
        let willClone = sameVolume(source, probe)
        let needed = (willClone ? 0 : byteCount) + requiredHeadroomBytes
        if available >= needed { return }

        throw VivError(
            .codeStaging,
            "Not enough room to stage \(source.path). It holds "
                + "\(byteCount.formattedByteCount)"
                + (willClone
                    ? ", which clones for free on this volume, but "
                    : ", which must be copied because \(probe.path) is on a different volume, and ")
                + "\(Int64(available).formattedByteCount) is free where the run would go — less "
                + "than the \(requiredHeadroomBytes.formattedByteCount) a booting guest needs on "
                + "top of it. Free some space, or set VIVARIUM_HOME to a volume that has it.",
            inspectionHints: ["df -h \(probe.path)", "du -sh \(source.path)"]
        )
    }

    private static func sameVolume(_ left: URL, _ right: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let leftID = try? left.resourceValues(forKeys: keys).volumeIdentifier,
              let rightID = try? right.resourceValues(forKeys: keys).volumeIdentifier else {
            return false
        }
        return leftID.isEqual(rightID)
    }

    /// Space actually consumed, via `du`. See `TemplateInventory` for why the
    /// apparent size is not what is wanted.
    private static func onDiskByteCount(of url: URL) async -> Int64? {
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/du", ["-s", "-k", url.path],
            timeout: .seconds(300),
            stage: .codeStaging
        ), result.succeeded else {
            return nil
        }
        guard let field = result.stdoutText.split(separator: "\n").first?
            .split(whereSeparator: \.isWhitespace).first,
              let kibibytes = Int64(field) else {
            return nil
        }
        return kibibytes * 1024
    }

    /// Removes `url` if there is anything there, including a dangling symlink,
    /// which `fileExists` would deny the existence of.
    private static func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw VivError(
                .codeStaging,
                "Cannot replace the previously staged code at \(url.path).",
                underlying: error
            )
        }
    }

    private static func createParent(of url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw VivError(
                .codeStaging,
                "Cannot create \(url.deletingLastPathComponent().path).",
                underlying: error
            )
        }
    }
}
