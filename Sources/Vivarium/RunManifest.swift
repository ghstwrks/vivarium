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

    /// What the guest was built from: a restore image on disk, or the disk
    /// image a template was imported from. Optional throughout, because a run
    /// started from a template never sees the source at all.
    var sourcePath: String?
    var sourceSHA256: String?
    var sourceByteCount: Int64?
    /// The guest's own version and build, however it came to exist.
    var guestOSVersion: String?
    var guestOSBuild: String?

    /// Which operating system the guest runs. Absent in a bundle written
    /// before Vivarium ran more than one, which were all macOS.
    var guestOS: GuestOS?

    var username: String
    var fullName: String
    /// Where the credential lives, for a multi-command workflow. The credential
    /// itself is never stored here.
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

    /// The guest's operating system, defaulting a bundle that predates the
    /// field to the only thing it could have been.
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

/// The record written beside a template bundle.
///
/// The fields are named for what they hold rather than for where macOS gets it
/// from, because a Fedora template has no IPSW. Templates written by 0.1 used
/// the older names and are still read: a template is the most expensive thing
/// Vivarium makes, and refusing one over a key name would be an unkind way to
/// announce a new feature.
struct TemplateManifest: Codable, Sendable {
    /// Which operating system this template holds.
    let os: GuestOS
    /// The guest's own version, as it names it: `27.0.0`, or `44`.
    let osVersion: String
    /// The build this template was made from: an IPSW build, or a Fedora
    /// compose.
    let osBuild: String
    /// A digest of what it was built from — the restore image, or the
    /// downloaded disk image, as it arrived.
    let sourceSHA256: String?
    /// Where it came from: a path on this machine, or a URL.
    let source: String?
    let createdAt: Date
    /// A digest over the small platform-identity files, for a guest that has
    /// them. The system disk is deliberately excluded: it is a sparse image
    /// whose full hash would cost minutes per template check, and the identity
    /// files are what determine whether a template is internally consistent.
    /// `nil` for a guest whose template is a system disk and nothing else.
    let platformIdentitySHA256: String?
    let systemDiskByteCount: Int64
    /// A digest of the system disk as the template was written, recorded
    /// because it can be: an imported image is hashed on its way through
    /// decompression, where the bytes are passing anyway. Never checked on the
    /// hot path — hashing ten gigabytes per run would cost more than it caught.
    let systemDiskSHA256: String?
    let createdByRunID: String?

    enum CodingKeys: String, CodingKey {
        case os, osVersion, osBuild, sourceSHA256, source, createdAt
        case platformIdentitySHA256, systemDiskByteCount, systemDiskSHA256, createdByRunID
        /// 0.1's names for three of the above. Read always; written only for a
        /// macOS template, so that one built here stays readable by 0.1.
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

        // Mirrored under 0.1's names so that a macOS template created here can
        // still be read by a 0.1 binary. A restore is ninety minutes of
        // somebody's afternoon, which is a lot to lose to a rename.
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
