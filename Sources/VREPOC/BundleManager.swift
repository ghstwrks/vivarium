import Foundation

/// Creates and inspects run bundles.
enum BundleManager {
    /// Creates the bundle directory tree.
    ///
    /// A non-empty existing bundle is refused unless `reuse` is set: silently
    /// installing over a previous run's disk image would destroy the evidence
    /// the previous run was kept for.
    static func createBundle(paths: VMBundlePaths, reuse: Bool) throws {
        let manager = FileManager.default

        if manager.fileExists(atPath: paths.root.path) {
            let contents = (try? manager.contentsOfDirectory(atPath: paths.root.path)) ?? []
            let meaningful = contents.filter { $0 != ".DS_Store" }
            if !meaningful.isEmpty && !reuse {
                throw POCError(
                    .bundlePreparation,
                    "\(paths.root.path) already exists and is not empty "
                        + "(\(meaningful.count) entries). Pass --reuse to write into it anyway, "
                        + "or choose a different --bundle.",
                    inspectionHints: ["ls -la \(paths.root.path)"]
                )
            }
        }

        for directory in [paths.root, paths.sharedDirectory, paths.sharedInput,
                          paths.sharedOutput, paths.logsDirectory, paths.diagnosticsDirectory] {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw POCError(
                    .bundlePreparation,
                    "Failed to create \(directory.path).",
                    underlying: error
                )
            }
        }
    }

    /// Confirms a bundle holds a complete, installed VM.
    static func requireInstalledBundle(paths: VMBundlePaths, stage: POCStage) throws {
        let required = [
            paths.auxiliaryStorage, paths.systemDisk,
            paths.hardwareModel, paths.machineIdentifier, paths.macAddress
        ]
        let missing = required.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            throw POCError(
                stage,
                "\(paths.root.path) is not an installed VM bundle; missing: "
                    + missing.map(\.lastPathComponent).joined(separator: ", "),
                inspectionHints: ["ls -la \(paths.root.path)"]
            )
        }
    }

    static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Bytes actually occupied on disk, which for a sparse 128 GiB image is far
    /// smaller than its logical size.
    static func allocatedSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }
}
