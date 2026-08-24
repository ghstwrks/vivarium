import Foundation
import XCTest
@testable import Vivarium

final class RunStorageTests: XCTestCase {
    func testRemoveDeletesDanglingSymlinkWithoutFollowingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivarium-run-storage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let link = root.appendingPathComponent("dangling-run")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: root.appendingPathComponent("missing-target").path
        )

        XCTAssertTrue(try RunStorage.remove(link))

        var info = stat()
        XCTAssertEqual(lstat(link.path, &info), -1)
        XCTAssertEqual(errno, ENOENT)
    }

    func testRemoveReturnsFalseForMissingPath() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivarium-missing-\(UUID().uuidString)")
        XCTAssertFalse(try RunStorage.remove(missing))
    }
}
