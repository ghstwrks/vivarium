import Foundation
import Testing

@testable import Vivarium

@Suite("The template inventory")
struct TemplateInventoryTests {
    /// A template bundle on disk, with a `template.json` unless `manifest` is
    /// nil — a directory that looks like a template but cannot be read as one.
    @discardableResult
    private func makeTemplate(
        _ name: String,
        in directory: URL,
        os: GuestOS? = .macOS,
        createdAt: String = "2026-08-10T14:35:11Z"
    ) throws -> URL {
        let root = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let os else { return root }

        let manifest = TemplateManifest(
            os: os,
            osVersion: "27.0.0",
            osBuild: "26A5388g",
            sourceSHA256: nil,
            source: nil,
            createdAt: try #require(ISO8601DateFormatter().date(from: createdAt)),
            platformIdentitySHA256: nil,
            systemDiskByteCount: 4096,
            systemDiskSHA256: nil,
            createdByRunID: nil
        )
        try JSONCoding.write(manifest, to: TemplatePaths(root: root).manifest)
        return root
    }

    @Test("only .bundle directories count as templates")
    func listsBundlesOnly() async throws {
        let directory = try temporaryDirectory("viv-templates")
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeTemplate("macos-26A5388g.bundle", in: directory)
        try makeTemplate("notes", in: directory, os: nil)
        try Data("stray".utf8).write(to: directory.appendingPathComponent("readme.bundle"))

        let summaries = await TemplateInventory.summaries(in: directory)
        #expect(summaries.map(\.name) == ["macos-26A5388g"])
    }

    @Test("a template directory with no readable manifest is still listed")
    func listsUnreadableTemplate() async throws {
        // Saying a directory looks like a template but cannot be trusted as one
        // is more use than hiding it.
        let directory = try temporaryDirectory("viv-templates")
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeTemplate("broken.bundle", in: directory, os: nil)

        let summaries = await TemplateInventory.summaries(in: directory)
        #expect(summaries.map(\.name) == ["broken"])
        #expect(summaries.first?.manifest == nil)
    }

    @Test("templates are listed newest first")
    func ordersNewestFirst() async throws {
        let directory = try temporaryDirectory("viv-templates")
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeTemplate("old.bundle", in: directory, createdAt: "2026-01-01T00:00:00Z")
        try makeTemplate("new.bundle", in: directory, createdAt: "2026-08-10T00:00:00Z")
        try makeTemplate("middle.bundle", in: directory, createdAt: "2026-05-01T00:00:00Z")

        let summaries = await TemplateInventory.summaries(in: directory)
        #expect(summaries.map(\.name) == ["new", "middle", "old"])
    }

    @Test("the newest template is the one a run takes by default")
    func picksNewest() async throws {
        let directory = try temporaryDirectory("viv-templates")
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeTemplate("old.bundle", in: directory, createdAt: "2026-01-01T00:00:00Z")
        try makeTemplate("new.bundle", in: directory, createdAt: "2026-08-10T00:00:00Z")

        let newest = await TemplateInventory.newest(in: directory)
        #expect(newest?.name == "new")
    }

    @Test("--os narrows the choice to one guest, newest of that guest")
    func picksNewestOfOneGuest() async throws {
        let directory = try temporaryDirectory("viv-templates")
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeTemplate("fedora-42.bundle", in: directory, os: .fedora, createdAt: "2026-01-01T00:00:00Z")
        try makeTemplate("macos-26A5388g.bundle", in: directory, os: .macOS, createdAt: "2026-08-10T00:00:00Z")

        #expect(await TemplateInventory.newest(in: directory, os: .fedora)?.name == "fedora-42")
        #expect(await TemplateInventory.newest(in: directory, os: .macOS)?.name == "macos-26A5388g")
    }

    @Test("a template that cannot be read is never picked to run")
    func neverPicksUnreadableTemplate() async throws {
        let directory = try temporaryDirectory("viv-templates")
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeTemplate("broken.bundle", in: directory, os: nil)

        #expect(await TemplateInventory.newest(in: directory) == nil)
    }

    @Test("a home with no templates directory yields nothing, not an error")
    func toleratesMissingDirectory() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("viv-absent-\(UUID().uuidString)")
        #expect(await TemplateInventory.summaries(in: missing).isEmpty)
        #expect(await TemplateInventory.newest(in: missing) == nil)
    }

    @Test("a template is named for its guest and build")
    func namesTemplateForGuestAndBuild() {
        #expect(
            DefaultLocations.template(os: .macOS, build: "26A5388g").lastPathComponent
                == "macos-26A5388g.bundle"
        )
        #expect(
            DefaultLocations.template(os: .fedora, build: "42").lastPathComponent
                == "fedora-42.bundle"
        )
    }
}

@Suite("Sizes for humans")
struct ByteCountFormattingTests {
    @Test("a size is rendered in the binary units du and Finder use", arguments: [
        (Int64(0), "0 B"),
        (Int64(512), "512 B"),
        (Int64(1024), "1.0 KiB"),
        (Int64(1536), "1.5 KiB"),
        (Int64(1024 * 1024), "1.0 MiB"),
        (Int64(3) * 1024 * 1024 * 1024, "3.0 GiB"),
        (Int64(2) * 1024 * 1024 * 1024 * 1024, "2.0 TiB"),
    ])
    func formats(_ pair: (bytes: Int64, text: String)) {
        #expect(pair.bytes.formattedByteCount == pair.text)
    }

    @Test("a size beyond the largest unit stays in that unit")
    func staysInLargestUnit() {
        #expect((Int64(5000) * 1024 * 1024 * 1024 * 1024).formattedByteCount.hasSuffix("TiB"))
    }
}
