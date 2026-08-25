import Compression
import Foundation
import Testing

@testable import Vivarium

@Suite("Cloud-init seed")
struct CloudInitSeedTests {
    private func userData(username: String = "vivadmin", fullName: String = "Vivarium Administrator")
        -> String {
        let request = ProvisioningRequest(
            paths: VMBundlePaths(root: URL(fileURLWithPath: "/tmp/viv-test")),
            credentials: GuestCredentials(
                fullName: fullName,
                username: username,
                authentication: .privateKey(
                    path: URL(fileURLWithPath: "/tmp/viv-test/id_ed25519"),
                    publicKey: "ssh-ed25519 AAAAC3Nz test"
                )
            ),
            runID: "run-1",
            hostname: "viv-run-1",
            logsInAutomatically: true,
            disablesRemoteLogin: false
        )
        return CloudInitSeed.userData(request: request, publicKey: "ssh-ed25519 AAAAC3Nz test")
    }

    @Test("the seed carries a public key and no password")
    func noSecrets() {
        let text = userData()
        #expect(text.contains("ssh-ed25519 AAAAC3Nz test"))
        #expect(text.contains("lock_passwd: true"))
        #expect(text.contains("ssh_pwauth: false"))
        #expect(!text.lowercased().contains("chpasswd"))
        #expect(!text.lowercased().contains("plain_text_passwd"))
    }

    @Test("the seed mounts the share the host exported")
    func mountsTheShare() {
        let text = userData()
        #expect(text.contains("[mount, -t, virtiofs, \"viv\", \"/mnt/viv\"]"))
        #expect(CloudInitSeed.shareTag == "viv")
        #expect(CloudInitSeed.shareMountPath == LinuxPlatform(os: .fedora).scripts.sharePath)
    }

    @Test("the seed grows the root filesystem")
    func growsTheRoot() {
        let text = userData()
        #expect(text.contains("growpart:"))
        #expect(text.contains("resize_rootfs: true"))
    }

    @Test("values are quoted as YAML scalars")
    func quoting() {
        let text = userData(username: "odd:name", fullName: "A \"quoted\" name: with punctuation")
        #expect(text.contains(#"name: "odd:name""#))
        #expect(text.contains(#"gecos: "A \"quoted\" name: with punctuation""#))
    }

    @Test("hostnames are reduced to something a label can be")
    func hostnames() {
        #expect(ProvisioningRequest.hostname(forRunID: "smoke1") == "viv-smoke1")
        #expect(ProvisioningRequest.hostname(forRunID: "CI_2026.08.19/attempt 3")
            == "viv-ci-2026-08-19-attempt-3")
        #expect(ProvisioningRequest.hostname(forRunID: "...") == "viv----")
        #expect(ProvisioningRequest.hostname(forRunID: String(repeating: "a", count: 200)).count <= 63)
    }
}

@Suite("Disk image decompression")
struct DiskImageDecompressorTests {
    private func compress(_ data: Data) throws -> Data {
        var output = Data()
        let capacity = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var stream = compression_stream(
            dst_ptr: buffer, dst_size: capacity,
            src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!, src_size: 0, state: nil
        )
        #expect(compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZMA)
            == COMPRESSION_STATUS_OK)
        defer { compression_stream_destroy(&stream) }

        try data.withUnsafeBytes { raw in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = data.count
            var status = COMPRESSION_STATUS_OK
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = capacity
                status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                output.append(buffer, count: capacity - stream.dst_size)
                if status == COMPRESSION_STATUS_ERROR {
                    throw VivError(.templateSnapshot, "could not compress the fixture")
                }
            } while status == COMPRESSION_STATUS_OK
        }
        return output
    }

    @Test("an xz stream decompresses to exactly what went in")
    func roundTrip() throws {
        let directory = try temporaryDirectory("viv-decompress")
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = Data((0..<200_000).map { UInt8($0 % 251) })
        let source = directory.appendingPathComponent("image.raw.xz")
        let destination = directory.appendingPathComponent("Disk.img")
        try compress(original).write(to: source)

        #expect(try DiskImageCompression.detect(at: source, stage: .templateSnapshot) == .xz)
        let result = try DiskImageDecompressor.decompress(
            from: source, to: destination, stage: .templateSnapshot
        )
        #expect(result.byteCount == Int64(original.count))
        #expect(result.sha256 == Digest.sha256Hex(original))
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("a multi-stream file is refused rather than truncated")
    func refusesConcatenatedStreams() throws {
        let directory = try temporaryDirectory("viv-decompress")
        defer { try? FileManager.default.removeItem(at: directory) }

        let half = Data(repeating: 0xAB, count: 50_000)
        let source = directory.appendingPathComponent("two.raw.xz")
        try (compress(half) + compress(half)).write(to: source)

        #expect(throws: VivError.self) {
            try DiskImageDecompressor.decompress(
                from: source,
                to: directory.appendingPathComponent("Disk.img"),
                stage: .templateSnapshot
            )
        }
    }

    @Test("a raw image is recognised as raw")
    func detectsRaw() throws {
        let directory = try temporaryDirectory("viv-decompress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("image.raw.xz")
        try Data(repeating: 0, count: 4096).write(to: source)
        #expect(try DiskImageCompression.detect(at: source, stage: .templateSnapshot) == .none)
    }
}

@Suite("Image sources")
struct LinuxImageSourceTests {
    @Test("the pinned image is a Fedora one, with a digest")
    func catalogue() throws {
        let release = try #require(LinuxImageCatalogue.release(for: .fedora))
        #expect(release.os == .fedora)
        #expect(release.sha256.count == 64)
        #expect(release.url.scheme == "https")
        #expect(release.url.host()?.hasSuffix("fedoraproject.org") == true)
    }

    @Test("an imported file's name becomes its build")
    func derivedBuilds() {
        let cases: [(String, String)] = [
            ("/tmp/Fedora-Cloud-Base-44-1.7.aarch64.raw.xz", "Fedora-Cloud-Base-44-1.7.aarch64"),
            ("/tmp/my image.img", "my-image"),
            ("/tmp/....", "imported")
        ]
        for (path, expected) in cases {
            let source = LinuxImageSource.local(url: URL(fileURLWithPath: path), sha256: nil)
            #expect(source.build == expected)
        }
    }

    @Test("a catalogue source keeps the publisher's version and build")
    func catalogueSource() throws {
        let release = try #require(LinuxImageCatalogue.release(for: .fedora))
        let source = LinuxImageSource.catalogue(release)
        #expect(source.version == release.version)
        #expect(source.build == release.build)
        #expect(source.expectedSHA256 == release.sha256)
    }
}
