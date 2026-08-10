import CryptoKit
import Foundation

enum Digest {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// Streams a file through SHA-256 so that hashing a 22 GB IPSW does not
    /// require a 22 GB allocation.
    static func sha256HexOfFile(at url: URL, stage: VivStage) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw VivError(stage, "Cannot open \(url.path) for hashing.")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 8 * 1024 * 1024
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
