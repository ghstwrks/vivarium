import Foundation

/// The provisioned guest account.
///
/// The password never reaches `run.json`, a log line, or an argument vector.
/// It lives in this value and in the child environment of the askpass helper,
/// and nowhere else.
struct GuestCredentials: Sendable {
    let fullName: String
    let username: String
    let password: String

    /// Generates a password from the system CSPRNG.
    ///
    /// The alphabet excludes characters that macOS account creation has
    /// historically rejected or that would complicate shell handling, and the
    /// length is chosen so the result is well beyond guessing even though the
    /// VM is only reachable on a host-local NAT.
    static func generate(username: String, fullName: String) -> GuestCredentials {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var password = ""
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with \(status).")
        for byte in bytes {
            password.append(alphabet[Int(byte) % alphabet.count])
        }
        // macOS requires a password that is not trivially weak; a 32-character
        // mixed-case alphanumeric satisfies every policy the installer applies.
        return GuestCredentials(fullName: fullName, username: username, password: password)
    }
}

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

    var ipswPath: String?
    var ipswSHA256: String?
    var ipswByteCount: Int64?
    var restoreImageVersion: String?
    var restoreImageBuild: String?

    var username: String
    var fullName: String
    /// How to recover the password for a multi-command workflow. The password
    /// itself is never stored here.
    var passwordStorage: String

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

    static func create(
        runID: String,
        bundle: VMBundlePaths,
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
            ipswPath: nil,
            ipswSHA256: nil,
            ipswByteCount: nil,
            restoreImageVersion: nil,
            restoreImageBuild: nil,
            username: credentials.username,
            fullName: credentials.fullName,
            passwordStorage: "in-memory only; not persisted",
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
struct TemplateManifest: Codable, Sendable {
    let ipswBuild: String
    let ipswVersion: String
    let ipswSHA256: String?
    let createdAt: Date
    /// A digest over the small platform-identity files. The system disk is
    /// deliberately excluded: it is a 128 GiB sparse image whose full hash
    /// would cost minutes per template check, and the identity files are what
    /// determine whether a template is internally consistent.
    let platformIdentitySHA256: String
    let systemDiskByteCount: Int64
    let createdByRunID: String
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
