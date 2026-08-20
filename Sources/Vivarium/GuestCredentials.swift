import Foundation

enum GuestAuthentication: Sendable {
    case password(String)
    case privateKey(path: URL, publicKey: String)
    case unavailable
}

struct GuestCredentials: Sendable {
    let fullName: String
    let username: String
    let authentication: GuestAuthentication

    var isUsable: Bool {
        if case .unavailable = authentication { return false }
        return true
    }

    var password: String? {
        if case let .password(password) = authentication { return password }
        return nil
    }

    var storageDescription: String {
        switch authentication {
        case .password:
            return "in-memory only; not persisted"
        case let .privateKey(path, _):
            return "ed25519 private key at \(path.lastPathComponent) in this bundle, mode 0600"
        case .unavailable:
            return "none: this bundle was adopted, and the original credential was not persisted"
        }
    }

    func inspectionAdvice(username: String, address: String, bundle: URL) -> String {
        switch authentication {
        case .password:
            return """
                The password is generated per run and lives only in this process's \
                memory: it is never printed, logged, or written down, so there is no \
                new SSH session to be had. What is inspectable is the run directory \
                above and any session already open.
                """
        case let .privateKey(path, _):
            return """
                The guest's key pair belongs to this run and goes when the run \
                directory does, so a second session is a command away:

                  ssh -i \(path.path) -o UserKnownHostsFile=\(bundle.appendingPathComponent("ssh_known_hosts").path) \(username)@\(address)
                """
        case .unavailable:
            return "This bundle carries no usable credential, so there is no session to be had."
        }
    }
}

enum GuestPassword {
    static func generate() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var password = ""
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with \(status).")
        for byte in bytes {
            password.append(alphabet[Int(byte) % alphabet.count])
        }
        return password
    }
}

enum GuestKeyPair {
    static func generate(at path: URL, comment: String) async throws -> GuestAuthentication {
        for candidate in [path, path.appendingPathExtension("pub")] {
            try? FileManager.default.removeItem(at: candidate)
        }

        try await ProcessRunner.runChecked(
            "/usr/bin/ssh-keygen",
            ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", path.path],
            timeout: .seconds(60),
            stage: .provisioning,
            inspectionHints: ["ls -la \(path.deletingLastPathComponent().path)"]
        )

        let publicKeyURL = path.appendingPathExtension("pub")
        guard let text = try? String(contentsOf: publicKeyURL, encoding: .utf8) else {
            throw VivError(
                .provisioning,
                "ssh-keygen reported success but wrote no public key at \(publicKeyURL.path)."
            )
        }
        let publicKey = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard publicKey.hasPrefix("ssh-ed25519 ") else {
            throw VivError(
                .provisioning,
                "\(publicKeyURL.path) does not look like an ed25519 public key."
            )
        }

        let mode = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.posixPermissions]
        if let mode = (mode as? NSNumber)?.uint16Value, mode & 0o077 != 0 {
            throw VivError(
                .provisioning,
                "\(path.path) is mode \(String(mode, radix: 8)); OpenSSH will refuse a private "
                    + "key that others can read."
            )
        }

        return .privateKey(path: path, publicKey: publicKey)
    }
}
