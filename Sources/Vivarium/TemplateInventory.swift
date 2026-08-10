import Foundation

/// One template bundle, described for display and for defaulting.
struct TemplateSummary: Sendable {
    let paths: TemplatePaths
    /// `nil` when `template.json` is missing or unreadable — the directory
    /// looks like a template but cannot be trusted as one, and saying so is
    /// more useful than hiding it from the listing.
    let manifest: TemplateManifest?
    /// Bytes actually occupied on disk, not the apparent size.
    let onDiskByteCount: Int64?

    var name: String {
        paths.root.deletingPathExtension().lastPathComponent
    }

    var createdAt: Date? {
        manifest?.createdAt ?? fileSystemCreationDate
    }

    private var fileSystemCreationDate: Date? {
        try? paths.root.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}

/// Reads the templates in a Vivarium home.
///
/// The home is the source of truth rather than an index file: templates are
/// created, copied in from another machine, and deleted with `rm`, and an index
/// would be wrong the first time someone did any of those.
enum TemplateInventory {
    /// Every `*.bundle` directory in `directory`, newest first.
    static func summaries(in directory: URL = VivariumHome.templates) async -> [TemplateSummary] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var summaries: [TemplateSummary] = []
        for entry in entries where entry.pathExtension == "bundle" {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            guard isDirectory == true else { continue }
            let paths = TemplatePaths(root: entry)
            summaries.append(
                TemplateSummary(
                    paths: paths,
                    manifest: try? JSONCoding.read(
                        TemplateManifest.self, from: paths.manifest, stage: .templateSnapshot
                    ),
                    onDiskByteCount: await onDiskByteCount(of: entry)
                )
            )
        }

        return summaries.sorted { left, right in
            (left.createdAt ?? .distantPast) > (right.createdAt ?? .distantPast)
        }
    }

    /// The template a command should use when the operator named none.
    static func newest(in directory: URL = VivariumHome.templates) async -> TemplateSummary? {
        await summaries(in: directory).first { $0.manifest != nil }
    }

    /// Space actually consumed, via `du`.
    ///
    /// The apparent size is meaningless here: the system disk is a 128 GiB
    /// sparse image, and a template materialised with `clonefile` shares most
    /// of its blocks with the bundle it came from. Summing `st_size` would
    /// report hundreds of gigabytes for a home that occupies a few.
    private static func onDiskByteCount(of url: URL) async -> Int64? {
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/du", ["-s", "-k", url.path],
            timeout: .seconds(120),
            stage: .templateSnapshot
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
}

extension Int64 {
    /// A size for humans, in the binary units `du -h` and Finder both use.
    var formattedByteCount: String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(self)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0
            ? "\(self) B"
            : String(format: "%.1f %@", value, units[unit])
    }
}
