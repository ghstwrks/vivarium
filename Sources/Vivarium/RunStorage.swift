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
    static func onDiskByteCount(of url: URL) async -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/du", ["-s", "-k", url.path],
            timeout: .seconds(300),
            stage: .cleanup
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

    /// Clears `uchg`/`schg` and restores owner write permission across the
    /// tree, which is what a failed `removeItem` is almost always about.
    private static func clearRemovalObstacles(at url: URL) {
        let manager = FileManager.default
        var targets = [url]
        if let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            targets.append(contentsOf: enumerator.compactMap { $0 as? URL })
        }

        for target in targets {
            _ = try? manager.setAttributes([.immutable: false], ofItemAtPath: target.path)
            guard let attributes = try? manager.attributesOfItem(atPath: target.path),
                  let permissions = attributes[.posixPermissions] as? NSNumber else { continue }
            let writable = permissions.uint16Value | 0o200
            _ = try? manager.setAttributes(
                [.posixPermissions: NSNumber(value: writable)],
                ofItemAtPath: target.path
            )
        }
    }
}
