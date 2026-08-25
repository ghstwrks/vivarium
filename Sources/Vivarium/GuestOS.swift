import Foundation

enum GuestOS: String, Codable, CaseIterable, Sendable {
    case macOS = "macos"
    case fedora = "fedora"

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .fedora: return "Fedora"
        }
    }

    var platform: any GuestPlatform {
        switch self {
        case .macOS: return MacOSPlatform()
        case .fedora: return LinuxPlatform(os: .fedora)
        }
    }

    static var allNames: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

extension GuestOS {
    static let assumedForUnlabelledTemplates: GuestOS = .macOS
}
