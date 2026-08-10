import Foundation

/// Deleting things Vivarium created.
///
/// `FileManager.removeItem` rather than the Trash, so that a hundred gigabytes
/// of VM bundle actually goes away and no `.Trashes` residue is left on the
/// volume. Removal is retried once after clearing the immutable flags and
/// restoring write permission, because a guest writes into the share as itself
/// and can leave entries the host's first attempt cannot unlink.
///
/// `viv gc` (Phase 3) is the other caller this exists for: it deletes the same
/// kinds of directory for the same reasons.
enum RunStorage {
    /// Removes `url` if it exists. Returns whether anything was deleted.
    @discardableResult
    static func remove(_ url: URL) throws -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return false }

        do {
            try manager.removeItem(at: url)
            return true
        } catch {
            log.debug("Removing \(url.path) failed (\(VivError.describe(error))); clearing flags and retrying.")
        }

        clearRemovalObstacles(at: url)

        do {
            try manager.removeItem(at: url)
            return true
        } catch {
            throw VivError(
                .cleanup,
                "Could not delete \(url.path), even after clearing read-only flags.",
                underlying: error,
                inspectionHints: ["ls -laO \(url.path)", "rm -rf \(url.path)"]
            )
        }
    }

    /// Bytes actually occupied, for saying how much a deletion returned.
    ///
    /// `du`'s exit status is ignored deliberately: a guest mounts `.Trashes`
    /// into the share with mode `d-wx--x--t` (see `clearRemovalObstacles`
    /// below), which `du` cannot descend into and reports with a nonzero
    /// exit — while still printing a correct total for everything it could
    /// read. Trusting the exit code here would silently report a multi-
    /// gigabyte run as reclaiming 0 bytes.
    static func onDiskByteCount(of url: URL) async -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/du", ["-s", "-k", url.path],
            timeout: .seconds(300),
            stage: .cleanup
        ) else {
            return nil
        }
        guard let field = result.stdoutText.split(separator: "\n").first?
            .split(whereSeparator: \.isWhitespace).first,
              let kibibytes = Int64(field) else {
            return nil
        }
        return kibibytes * 1024
    }

    /// Clears `uchg`/`schg` and restores owner access across the tree, which is
    /// what a failed `removeItem` is almost always about.
    ///
    /// A directory is given read and search permission as well as write,
    /// because deleting one means listing it first: macOS creates a `.Trashes`
    /// on every volume the guest mounts, mode `d-wx--x--t`, which neither the
    /// enumerator below nor `removeItem` can descend into until it is readable.
    /// Each entry is fixed as it is visited rather than afterwards, so that
    /// making a directory readable is what allows its children to be reached.
    private static func clearRemovalObstacles(at url: URL) {
        let manager = FileManager.default
        relax(url)

        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        for case let child as URL in enumerator {
            relax(child)
        }
    }

    private static func relax(_ url: URL) {
        let manager = FileManager.default
        _ = try? manager.setAttributes([.immutable: false], ofItemAtPath: url.path)

        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return }
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        let relaxed = permissions.uint16Value | (isDirectory ? 0o700 : 0o200)
        guard relaxed != permissions.uint16Value else { return }
        _ = try? manager.setAttributes(
            [.posixPermissions: NSNumber(value: relaxed)],
            ofItemAtPath: url.path
        )
    }
}
