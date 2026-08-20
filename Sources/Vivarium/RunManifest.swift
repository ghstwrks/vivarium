import Foundation

/// Everything the acceptance run asserts on, fixed before the VM starts.
///
/// Deciding the tokens, the exit code, and the marker up front is what makes
/// the assertions meaningful: a run cannot "discover" that whatever the guest
/// happened to print was correct.
struct RunExpectations: Codable, Sendable {
    let stdoutToken: String
    let stderrToken: String
    let exitCode: Int32
    let markerNonce: String
    /// `<run-id>:<nonce>:<sha256(run-id:nonce)>`. The trailing digest makes a
    /// truncated or partially written marker detectable, not just a
    /// mismatched one.
    let marker: String
    let artifactVolumeName: String

    static func generate(runID: String) -> RunExpectations {
        let nonce = Self.randomHex(byteCount: 16)
        let contentDigest = Digest.sha256Hex("\(runID):\(nonce)")
        return RunExpectations(
            stdoutToken: "VIV_STDOUT_OK",
            stderrToken: "VIV_STDERR_OK",
            exitCode: 23,
            markerNonce: nonce,
            marker: "\(runID):\(nonce):\(contentDigest)",
            artifactVolumeName: "VivArtifacts"
        )
    }

    /// The exact bytes expected in every marker file, including the newline
    /// `printf '%s\n'` writes.
    var markerFileContents: Data { Data((marker + "\n").utf8) }

    var markerFileSHA256: String { Digest.sha256Hex(markerFileContents) }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with \(status).")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The non-secret record of a run, written to `run.json`.
struct RunManifest: Codable, Sendable {
    var runID: String
    var createdAt: Date
    var bundlePath: String
    var templatePath: String?

    var hostOSVersion: String
    var hostBuild: String
    var hostArchitecture: String

    var sourcePath: String?
    var sourceSHA256: String?
    var sourceByteCount: Int64?
    var guestOSVersion: String?
    var guestOSBuild: String?

    var guestOS: GuestOS?

    var username: String
    var fullName: String
    var credentialStorage: String

    var macAddress: String
    var cpuCount: Int?
    var memorySizeBytes: UInt64?

    var expectations: RunExpectations
    /// Recorded because Phase 5 treats it as a load-bearing assumption to be
    /// re-tested, not a settled choice.
    var logsInAutomatically: Bool

    var guestAddress: String?
    var addressDiscoveryStrategy: String?
    var startedFromTemplate: Bool

    var finishedAt: Date?
    var outcome: String?

    var os: GuestOS { guestOS ?? .assumedForUnlabelledTemplates }

    static func create(
        runID: String,
        bundle: VMBundlePaths,
        guestOS: GuestOS,
        credentials: GuestCredentials,
        macAddress: String,
        logsInAutomatically: Bool
    ) -> RunManifest {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        return RunManifest(
            runID: runID,
            createdAt: Date(),
            bundlePath: bundle.root.path,
            templatePath: nil,
            hostOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            hostBuild: HostInfo.buildVersion,
            hostArchitecture: HostInfo.architecture,
            sourcePath: nil,
            sourceSHA256: nil,
            sourceByteCount: nil,
            guestOSVersion: nil,
            guestOSBuild: nil,
            guestOS: guestOS,
            username: credentials.username,
            fullName: credentials.fullName,
            credentialStorage: credentials.storageDescription,
            macAddress: macAddress,
            cpuCount: nil,
            memorySizeBytes: nil,
            expectations: RunExpectations.generate(runID: runID),
            logsInAutomatically: logsInAutomatically,
            guestAddress: nil,
            addressDiscoveryStrategy: nil,
            startedFromTemplate: false,
            finishedAt: nil,
            outcome: nil
        )
    }

    func write(to url: URL) throws {
        try JSONCoding.write(self, to: url)
    }

    static func read(from url: URL) throws -> RunManifest {
        try JSONCoding.read(RunManifest.self, from: url, stage: .bundlePreparation)
    }
}

struct TemplateManifest: Codable, Sendable {
    let os: GuestOS
    let osVersion: String
    let osBuild: String
    let sourceSHA256: String?
    let source: String?
    let createdAt: Date
    let platformIdentitySHA256: String?
    let systemDiskByteCount: Int64
    let systemDiskSHA256: String?
    let createdByRunID: String?

    enum CodingKeys: String, CodingKey {
        case os, osVersion, osBuild, sourceSHA256, source, createdAt
        case platformIdentitySHA256, systemDiskByteCount, systemDiskSHA256, createdByRunID
        case ipswBuild, ipswVersion, ipswSHA256
    }

    init(
        os: GuestOS,
        osVersion: String,
        osBuild: String,
        sourceSHA256: String?,
        source: String?,
        createdAt: Date,
        platformIdentitySHA256: String?,
        systemDiskByteCount: Int64,
        systemDiskSHA256: String?,
        createdByRunID: String?
    ) {
        self.os = os
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.sourceSHA256 = sourceSHA256
        self.source = source
        self.createdAt = createdAt
        self.platformIdentitySHA256 = platformIdentitySHA256
        self.systemDiskByteCount = systemDiskByteCount
        self.systemDiskSHA256 = systemDiskSHA256
        self.createdByRunID = createdByRunID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        os = try container.decodeIfPresent(GuestOS.self, forKey: .os)
            ?? .assumedForUnlabelledTemplates
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
            ?? container.decode(String.self, forKey: .ipswVersion)
        osBuild = try container.decodeIfPresent(String.self, forKey: .osBuild)
            ?? container.decode(String.self, forKey: .ipswBuild)
        sourceSHA256 = try container.decodeIfPresent(String.self, forKey: .sourceSHA256)
            ?? container.decodeIfPresent(String.self, forKey: .ipswSHA256)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        platformIdentitySHA256 = try container.decodeIfPresent(
            String.self, forKey: .platformIdentitySHA256
        )
        systemDiskByteCount = try container.decode(Int64.self, forKey: .systemDiskByteCount)
        systemDiskSHA256 = try container.decodeIfPresent(String.self, forKey: .systemDiskSHA256)
        createdByRunID = try container.decodeIfPresent(String.self, forKey: .createdByRunID)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(os, forKey: .os)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(osBuild, forKey: .osBuild)
        try container.encodeIfPresent(sourceSHA256, forKey: .sourceSHA256)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(platformIdentitySHA256, forKey: .platformIdentitySHA256)
        try container.encode(systemDiskByteCount, forKey: .systemDiskByteCount)
        try container.encodeIfPresent(systemDiskSHA256, forKey: .systemDiskSHA256)
        try container.encodeIfPresent(createdByRunID, forKey: .createdByRunID)

        if os == .macOS {
            try container.encode(osBuild, forKey: .ipswBuild)
            try container.encode(osVersion, forKey: .ipswVersion)
            try container.encodeIfPresent(sourceSHA256, forKey: .ipswSHA256)
        }
    }
}

enum JSONCoding {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL, stage: VivStage) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            throw VivError(stage, "Cannot read \(url.path).", underlying: error)
        }
    }
}

enum HostInfo {
    /// The macOS build, for example `26A5388g`. `kern.osversion` is the build
    /// string; `kern.osrelease` would be the Darwin version.
    static var buildVersion: String {
        sysctlString("kern.osversion") ?? "unknown"
    }

    static var architecture: String {
        sysctlString("hw.machine") ?? "unknown"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl includes the terminating NUL in the returned length.
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
