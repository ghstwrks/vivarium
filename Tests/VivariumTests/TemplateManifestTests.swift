import Foundation
import Testing

@testable import Vivarium

@Suite("Template records")
struct TemplateManifestTests {
    private func decode(_ json: String) throws -> TemplateManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TemplateManifest.self, from: Data(json.utf8))
    }

    private func encode(_ manifest: TemplateManifest) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    @Test("a 0.1 template still reads, as macOS")
    func legacyManifest() throws {
        let manifest = try decode("""
            {
              "createdAt" : "2026-08-10T14:35:11Z",
              "createdByRunID" : "619d4c81-4d54-4b4a-af96-6aabc7ebe333",
              "ipswBuild" : "26A5388g",
              "ipswSHA256" : "4e52b0122c11ed09494c9f70c58b83d71933c6afd9980748813dbdcd575b84af",
              "ipswVersion" : "27.0.0",
              "platformIdentitySHA256" : "a62c02963ff3c25255048388a2ad8fd1785c0687929ec4b522af14fb4599c97f",
              "systemDiskByteCount" : 27302821888
            }
            """)
        #expect(manifest.os == .macOS)
        #expect(manifest.osBuild == "26A5388g")
        #expect(manifest.osVersion == "27.0.0")
        #expect(manifest.sourceSHA256?.hasPrefix("4e52b012") == true)
        #expect(manifest.systemDiskByteCount == 27_302_821_888)
    }

    @Test("a macOS template written now is still readable by 0.1")
    func macOSManifestMirrorsLegacyKeys() throws {
        let fields = try encode(
            TemplateManifest(
                os: .macOS,
                osVersion: "27.0.0",
                osBuild: "26A5416b",
                sourceSHA256: "abc123",
                source: "/Users/someone/Downloads/x.ipsw",
                createdAt: Date(timeIntervalSince1970: 0),
                platformIdentitySHA256: "deadbeef",
                systemDiskByteCount: 1,
                systemDiskSHA256: nil,
                createdByRunID: "run-1"
            )
        )
        #expect(fields["ipswBuild"] as? String == "26A5416b")
        #expect(fields["ipswVersion"] as? String == "27.0.0")
        #expect(fields["ipswSHA256"] as? String == "abc123")
        #expect(fields["os"] as? String == "macos")
    }

    @Test("a Linux template carries no IPSW fields")
    func linuxManifestOmitsLegacyKeys() throws {
        let fields = try encode(
            TemplateManifest(
                os: .fedora,
                osVersion: "44",
                osBuild: "44-1.7",
                sourceSHA256: "abc123",
                source: "https://example.invalid/image.raw.xz",
                createdAt: Date(timeIntervalSince1970: 0),
                platformIdentitySHA256: nil,
                systemDiskByteCount: 1,
                systemDiskSHA256: "def456",
                createdByRunID: nil
            )
        )
        #expect(fields["ipswBuild"] == nil)
        #expect(fields["ipswVersion"] == nil)
        #expect(fields["platformIdentitySHA256"] == nil)
        #expect(fields["os"] as? String == "fedora")
        #expect(fields["systemDiskSHA256"] as? String == "def456")
    }

    @Test("what is written is what is read", arguments: [GuestOS.macOS, .fedora])
    func roundTrip(os: GuestOS) throws {
        let original = TemplateManifest(
            os: os,
            osVersion: "1.2.3",
            osBuild: "build-9",
            sourceSHA256: "aaa",
            source: "somewhere",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            platformIdentitySHA256: os == .macOS ? "bbb" : nil,
            systemDiskByteCount: 42,
            systemDiskSHA256: "ccc",
            createdByRunID: "r"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try decode(String(decoding: try encoder.encode(original), as: UTF8.self))
        #expect(decoded.os == original.os)
        #expect(decoded.osBuild == original.osBuild)
        #expect(decoded.osVersion == original.osVersion)
        #expect(decoded.platformIdentitySHA256 == original.platformIdentitySHA256)
        #expect(decoded.systemDiskSHA256 == original.systemDiskSHA256)
    }
}
