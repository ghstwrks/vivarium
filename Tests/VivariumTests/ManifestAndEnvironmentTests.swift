import Foundation
import XCTest
@testable import Vivarium

final class ManifestAndEnvironmentTests: XCTestCase {
    func testManifestReadsAllDocumentedFields() throws {
        let manifest = try readManifest("""
            {
              "name": "example",
              "test": "swift test",
              "artifacts": ["logs/**/*"],
              "timeout": 30,
              "env": { "CI": "1" }
            }
            """)

        XCTAssertEqual(manifest.name, "example")
        XCTAssertEqual(manifest.test, "swift test")
        XCTAssertEqual(manifest.artifacts, ["logs/**/*"])
        XCTAssertEqual(manifest.timeout, 30)
        XCTAssertEqual(manifest.environment, ["CI": "1"])
    }

    func testManifestRejectsUnknownKey() throws {
        XCTAssertThrowsError(try readManifest(#"{ "artefacts": ["result.txt"] }"#)) { error in
            XCTAssertTrue(VivError.describe(error).contains("unrecognised key"))
        }
    }

    func testManifestRejectsLineBreakingArtifactPattern() throws {
        XCTAssertThrowsError(try readManifest(#"{ "artifacts": ["logs\rother"] }"#)) { error in
            XCTAssertTrue(VivError.describe(error).contains("line break"))
        }
    }

    func testManifestRejectsNULInShellValues() throws {
        XCTAssertThrowsError(try readManifest(#"{ "test": "echo\u0000bad" }"#)) { error in
            XCTAssertTrue(VivError.describe(error).contains("NUL byte"))
        }
        XCTAssertThrowsError(try readManifest(#"{ "env": { "TOKEN": "a\u0000b" } }"#)) { error in
            XCTAssertTrue(VivError.describe(error).contains("NUL byte"))
        }
    }

    func testEnvironmentFileParsingIsLiteral() throws {
        let environment = try readEnvironment("""
              # comment
            TOKEN=a"b$c
            EMPTY=
            SPACED= leading and trailing 
            """)

        XCTAssertEqual(environment["TOKEN"], "a\"b$c")
        XCTAssertEqual(environment["EMPTY"], "")
        XCTAssertEqual(environment["SPACED"], " leading and trailing ")
    }

    func testEnvironmentFileRejectsDuplicateAndReservedNames() throws {
        XCTAssertThrowsError(try readEnvironment("A=1\nA=2\n"))
        XCTAssertThrowsError(try readEnvironment("VIV_RUN_ID=other\n"))
    }

    private func readManifest(_ contents: String) throws -> VivManifest {
        let url = try temporaryFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        return try VivManifest.read(from: url)
    }

    private func readEnvironment(_ contents: String) throws -> [String: String] {
        let url = try temporaryFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        return try GuestEnvironment.read(envFile: url)
    }

    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivarium-tests-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }
}
