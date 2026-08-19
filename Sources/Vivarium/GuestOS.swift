import Foundation

/// The operating systems Vivarium can run a guest of.
///
/// This is the name the outside world uses: `--os fedora`, the `os` field in a
/// template's `template.json`, the column in `viv template list`, the value in
/// `report.json`. Everything *behind* the name — how a template is built, which
/// boot loader the guest needs, which shell its scripts are written in — is
/// reached through `platform`, so that adding an operating system is a matter
/// of adding a case here and an implementation there rather than of finding
/// every place the old one was assumed.
///
/// The raw values are lowercase and stable, because they are written into files
/// that outlive the process.
enum GuestOS: String, Codable, CaseIterable, Sendable {
    case macOS = "macos"
    case fedora = "fedora"

    /// How the operating system spells its own name.
    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .fedora: return "Fedora"
        }
    }

    /// Everything about a run that depends on which of these the guest is.
    var platform: any GuestPlatform {
        switch self {
        case .macOS: return MacOSPlatform()
        case .fedora: return LinuxPlatform(os: .fedora)
        }
    }

    /// The values `--os` accepts, for help text and for error messages.
    static var allNames: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

/// A guest whose template was written before Vivarium had more than one
/// operating system to run is a macOS guest: that is the only thing it could
/// have been. Decoding a missing `os` as macOS is what lets a template built by
/// 0.1 — ninety minutes of somebody's afternoon — keep working.
extension GuestOS {
    static let assumedForUnlabelledTemplates: GuestOS = .macOS
}
