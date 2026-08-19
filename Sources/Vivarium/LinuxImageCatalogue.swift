import Foundation

/// A published disk image, pinned by digest.
struct LinuxImageRelease: Sendable {
    let os: GuestOS
    /// The distribution's own version, as it names it.
    let version: String
    /// The exact compose this image came from, which is what distinguishes two
    /// templates of the same version.
    let build: String
    let url: URL
    /// The digest the publisher records for the file at `url`, copied here so
    /// that Vivarium checks the bytes it got rather than trusting the transport
    /// or the mirror that served them.
    let sha256: String
    /// What this image is, in one line, for the operator who is about to spend
    /// half a gigabyte of somebody's bandwidth on it.
    let summary: String
}

/// The images `viv template create --os <name>` fetches when told nothing else.
///
/// Pinned in source, digest and all, for the same reason
/// `Scripts/action/expected-signer.txt` pins who may sign a release: it makes
/// the supply chain a reviewable line in a diff rather than whatever a redirect
/// resolved to this morning. Fedora's own download redirector picks a mirror,
/// and a hostile one cannot do anything with that: the digest below is what the
/// file has to hash to, and a file that does not is refused before it is
/// unpacked.
///
/// Pins go stale, and deliberately: Fedora replaces a compose when it respins,
/// and the old URL stops resolving. That is a release-time update to this file,
/// and until it happens `--image-url` with `--image-sha256` gets anyone
/// unblocked without waiting for one.
enum LinuxImageCatalogue {
    /// Fedora's only raw, aarch64, cloud-init-bearing published image.
    ///
    /// Not the image the feature request named, and the difference is worth
    /// recording. Fedora Server publishes two disk images: `Server-Guest-Generic`,
    /// which is the one meant to run as a virtual machine, in qcow2 — a format
    /// the Virtualization framework cannot attach and macOS has no tool to
    /// convert; and `Server-Host-Generic`, which is raw but ships
    /// `initial-setup` and no cloud-init, so its first boot waits at a console
    /// prompt for a human. Vivarium's whole premise is that no human touches
    /// the guest, so that image cannot be provisioned at all.
    ///
    /// Fedora Cloud Base is the same Fedora, built to be started by a machine:
    /// GPT with an EFI system partition the firmware can boot unaided, a btrfs
    /// root that grows to fill whatever disk it is given, and cloud-init with
    /// the NoCloud datasource that reads the seed. The `AmazonEC2` in the name
    /// is which flavour of the Cloud Base image is published raw rather than a
    /// statement about where it runs; it carries EC2's udev rules, which match
    /// nothing here and cost nothing.
    ///
    /// Anyone who wants the Server image specifically can convert it themselves
    /// and pass `--image`; nothing above this line assumes which image it got.
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

/// Where a template's disk image is coming from.
///
/// Three sources, in the order an operator reaches for them: the pinned one,
/// which needs no flags; a file already on this machine, which is what somebody
/// who converted an image themselves or downloaded it once has; and a URL with
/// a digest, which is what unblocks anyone when the pin above has gone stale.
enum LinuxImageSource: Sendable {
    case catalogue(LinuxImageRelease)
    case remote(url: URL, sha256: String)
    case local(url: URL, sha256: String?)

    /// The version recorded in the template's manifest.
    var version: String {
        switch self {
        case let .catalogue(release): return release.version
        case let .remote(url, _), let .local(url, _): return Self.derivedBuild(from: url)
        }
    }

    /// The build recorded in the template's manifest, and the half of the
    /// template's directory name that says which image it holds.
    var build: String {
        switch self {
        case let .catalogue(release): return release.build
        case let .remote(url, _), let .local(url, _): return Self.derivedBuild(from: url)
        }
    }

    /// What `template.json` records about where the image came from.
    var origin: String {
        switch self {
        case let .catalogue(release): return release.url.absoluteString
        case let .remote(url, _): return url.absoluteString
        case let .local(url, _): return url.path
        }
    }

    /// The URL to fetch, for a source that is not already on this machine.
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

    /// A build name for an image nobody told us the version of.
    ///
    /// The file name is all there is, so it is what gets used, with the
    /// extensions removed and anything a directory name should not carry
    /// replaced. It is a label, not an identifier: two different images with
    /// the same name would want two different templates, and `viv template
    /// create` refuses to write over one that already exists rather than
    /// guessing which was meant.
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
