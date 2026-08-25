import Foundation
import Testing

@testable import Vivarium

@Suite("Run storage deletion")
struct RunStorageTests {
    @Test("a dangling symlink is removed as a link, not followed")
    func removesDanglingSymlink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let link = root.appendingPathComponent("dangling-run")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: root.appendingPathComponent("missing-target").path
        )

        #expect(try RunStorage.remove(link))

        var info = stat()
        #expect(lstat(link.path, &info) == -1)
        #expect(errno == ENOENT)
    }

    @Test("a path that was never there reports nothing removed")
    func reportsMissingPath() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivarium-missing-\(UUID().uuidString)")
        #expect(try RunStorage.remove(missing) == false)
    }
}
