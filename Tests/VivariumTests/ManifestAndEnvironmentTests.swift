import Foundation
import Testing

@testable import Vivarium

@Suite("The viv.json manifest")
struct VivManifestTests {
    @Test("every documented field is read")
    func readsDocumentedFields() throws {
        let manifest = try readManifest("""
            {
              "name": "example",
              "test": "swift test",
              "artifacts": ["logs/**/*"],
              "timeout": 30,
              "env": { "CI": "1" }
            }
            """)

        #expect(manifest.name == "example")
        #expect(manifest.test == "swift test")
        #expect(manifest.artifacts == ["logs/**/*"])
        #expect(manifest.timeout == 30)
        #expect(manifest.environment == ["CI": "1"])
    }

    @Test("a misspelled key is refused rather than ignored")
    func refusesUnknownKey() throws {
        let error = #expect(throws: VivError.self) {
            try readManifest(#"{ "artefacts": ["result.txt"] }"#)
        }
        #expect(try #require(error).message.contains("unrecognised key"))
    }

    @Test("an artifact pattern carrying a line break is refused")
    func refusesLineBreakingArtifactPattern() throws {
        let error = #expect(throws: VivError.self) {
            try readManifest(#"{ "artifacts": ["logs\rother"] }"#)
        }
        #expect(try #require(error).message.contains("line break"))
    }

    @Test("a NUL byte is refused in the test command")
    func refusesNULByteInTestCommand() throws {
        let error = #expect(throws: VivError.self) {
            try readManifest(#"{ "test": "echo\u0000bad" }"#)
        }
        #expect(try #require(error).message.contains("NUL byte"))
    }

    @Test("a NUL byte is refused in an environment value")
    func refusesNULByteInEnvironmentValue() throws {
        let error = #expect(throws: VivError.self) {
            try readManifest(#"{ "env": { "TOKEN": "a\u0000b" } }"#)
        }
        #expect(try #require(error).message.contains("NUL byte"))
    }

    private func readManifest(_ contents: String) throws -> VivManifest {
        let url = try temporaryFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        return try VivManifest.read(from: url)
    }
}

@Suite("The --env-file")
struct GuestEnvironmentTests {
    @Test("parsing is literal, not dotenv")
    func parsingIsLiteral() throws {
        // The significant spaces are escaped rather than typed, so an editor
        // trimming the line cannot quietly change what is asserted.
        let environment = try readEnvironment(
            "  # comment\n"
                + "TOKEN=a\"b$c\n"
                + "EMPTY=\n"
                + "SPACED=\u{20}leading and trailing\u{20}\n"
        )

        #expect(environment["TOKEN"] == "a\"b$c")
        #expect(environment["EMPTY"] == "")
        #expect(environment["SPACED"] == " leading and trailing ")
    }

    @Test("a name given twice is refused rather than resolved")
    func refusesDuplicateName() throws {
        #expect(throws: VivError.self) { try readEnvironment("A=1\nA=2\n") }
    }

    @Test("a name Vivarium sets itself is refused")
    func refusesReservedName() throws {
        #expect(throws: VivError.self) { try readEnvironment("VIV_RUN_ID=other\n") }
    }

    private func readEnvironment(_ contents: String) throws -> [String: String] {
        let url = try temporaryFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        return try GuestEnvironment.read(envFile: url)
    }
}
