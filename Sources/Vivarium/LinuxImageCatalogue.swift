import Foundation

struct LinuxImageRelease: Sendable {
    let os: GuestOS
    let version: String
    let build: String
    let url: URL
    let sha256: String
    let summary: String
}

enum LinuxImageCatalogue {
    static let fedora = LinuxImageRelease(
        os: .fedora,
        version: "44",
        build: "44-1.7",
        url: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/44"
            + "/Cloud/aarch64/images/Fedora-Cloud-Base-AmazonEC2-44-1.7.aarch64.raw.xz")!,
        sha256: "090d3cb07b266535ff81603d12cd143626caedc51be46977fef5f9161d5117b3",
        summary: "Fedora Cloud Base 44 (compose 1.7) for aarch64, about 490 MiB compressed"
    )

    static let releases: [LinuxImageRelease] = [fedora]

    static func release(for os: GuestOS) -> LinuxImageRelease? {
        releases.first { $0.os == os }
    }
}

enum LinuxImageSource: Sendable {
    case catalogue(LinuxImageRelease)
    case remote(url: URL, sha256: String)
    case local(url: URL, sha256: String?)

    var version: String {
        switch self {
        case let .catalogue(release): return release.version
        case let .remote(url, _), let .local(url, _): return Self.derivedBuild(from: url)
        }
    }

    var build: String {
        switch self {
        case let .catalogue(release): return release.build
        case let .remote(url, _), let .local(url, _): return Self.derivedBuild(from: url)
        }
    }

    var origin: String {
        switch self {
        case let .catalogue(release): return release.url.absoluteString
        case let .remote(url, _): return url.absoluteString
        case let .local(url, _): return url.path
        }
    }

    var remoteURL: URL? {
        switch self {
        case let .catalogue(release): return release.url
        case let .remote(url, _): return url
        case .local: return nil
        }
    }

    var expectedSHA256: String? {
        switch self {
        case let .catalogue(release): return release.sha256
        case let .remote(_, sha256): return sha256
        case let .local(_, sha256): return sha256
        }
    }

    private static func derivedBuild(from url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".xz", ".raw", ".img"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        let cleaned = name.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-"
                || character == "." || character == "_") ? character : "-"
        }
        let trimmed = String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "imported" : trimmed
    }
}
