import Foundation

enum LinuxTemplateBuilder {
    static let defaultDiskSizeGiB = 64

    struct Request: Sendable {
        let os: GuestOS
        let source: LinuxImageSource
        let template: TemplatePaths
        let diskSizeGiB: Int
        let workingDirectory: URL
    }

    static func create(_ request: Request) async throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: request.template.root.path) else {
            throw VivError(
                .templateSnapshot,
                "\(request.template.root.path) already exists. Delete it, or pass --template to "
                    + "build somewhere else.",
                inspectionHints: ["ls -la \(request.template.root.path)"]
            )
        }

        try manager.createDirectory(at: request.workingDirectory, withIntermediateDirectories: true)

        let staging = request.template.root
            .deletingLastPathComponent()
            .appendingPathComponent(".\(request.template.root.lastPathComponent).partial")
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let image = try await obtainImage(request)
            defer { image.discardIfTemporary() }

            let disk = staging.appendingPathComponent(VMBundlePaths.systemDiskFilename)
            let digest = try await materialize(image.url, to: disk, request: request)
            try grow(disk, toGiB: request.diskSizeGiB)

            try TemplateManager.writeManifest(
                to: TemplatePaths(root: staging),
                platform: request.os.platform,
                osVersion: request.source.version,
                osBuild: request.source.build,
                source: request.source.origin,
                sourceSHA256: image.sha256,
                systemDiskSHA256: digest,
                runID: nil
            )

            try manager.moveItem(at: staging, to: request.template.root)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }

        log.info("Template written to \(request.template.root.path).")
    }

    private struct ObtainedImage {
        let url: URL
        let sha256: String
        let isTemporary: Bool

        func discardIfTemporary() {
            guard isTemporary else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func obtainImage(_ request: Request) async throws -> ObtainedImage {
        switch request.source {
        case let .local(url, expected):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VivError(.templateSnapshot, "No disk image at \(url.path).")
            }
            log.info("Hashing \(url.path).")
            let digest = try await Task.detached(priority: .utility) {
                try Digest.sha256HexOfFile(at: url, stage: .templateSnapshot)
            }.value
            if let expected {
                try require(digest: digest, matches: expected, describing: url.path)
            } else {
                log.info("Image sha256: \(digest). No --image-sha256 was given, so it is recorded "
                    + "rather than checked.")
            }
            return ObtainedImage(url: url, sha256: digest, isTemporary: false)

        case .catalogue, .remote:
            guard let expected = request.source.expectedSHA256,
                  let url = request.source.remoteURL else {
                throw VivError(.templateSnapshot, "No image URL to download.")
            }
            let destination = request.workingDirectory
                .appendingPathComponent(url.lastPathComponent)
            let digest = try await LinuxImageDownloader.download(from: url, to: destination)
            do {
                try require(digest: digest, matches: expected, describing: url.absoluteString)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return ObtainedImage(url: destination, sha256: digest, isTemporary: true)
        }
    }

    private static func require(digest: String, matches expected: String, describing what: String) throws {
        guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
            throw VivError(
                .templateSnapshot,
                "\(what) hashes to \(digest), but \(expected) was expected. Nothing was unpacked. "
                    + "Either the file is not the one that was pinned, or it did not arrive "
                    + "intact."
            )
        }
        log.info("Image sha256 \(digest) matches what was expected.")
    }

    private static func materialize(
        _ image: URL,
        to disk: URL,
        request: Request
    ) async throws -> String? {
        switch try DiskImageCompression.detect(at: image, stage: .templateSnapshot) {
        case .xz:
            log.info("Decompressing \(image.lastPathComponent).")
            let result = try await Task.detached(priority: .utility) {
                try DiskImageDecompressor.decompress(
                    from: image,
                    to: disk,
                    stage: .templateSnapshot,
                    onProgress: { written in
                        log.info("Decompressed \(written.formattedByteCount) so far.")
                    }
                )
            }.value
            log.info(
                "Decompressed \(result.byteCount.formattedByteCount) to \(disk.path) "
                    + "(sha256 \(result.sha256))."
            )
            return result.sha256

        case .none:
            log.info("\(image.lastPathComponent) is already raw; copying it into the template.")
            try await TemplateManager.clone(from: image, to: disk, stage: .templateSnapshot)
            return nil
        }
    }

    private static func grow(_ disk: URL, toGiB sizeGiB: Int) throws {
        let target = off_t(sizeGiB) * 1024 * 1024 * 1024
        let current = BundleManager.fileSize(of: disk)
        guard Int64(target) > current else {
            log.info(
                "The imported disk is already \(current.formattedByteCount), which is at least "
                    + "the \(sizeGiB) GiB asked for; leaving it as it is."
            )
            return
        }

        let descriptor = open(disk.path, O_WRONLY)
        guard descriptor != -1 else {
            throw VivError(
                .templateSnapshot,
                "Cannot open \(disk.path) to resize it: \(String(cString: strerror(errno)))."
            )
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, target) == 0 else {
            throw VivError(
                .templateSnapshot,
                "Cannot grow \(disk.path) to \(sizeGiB) GiB: \(String(cString: strerror(errno)))."
            )
        }
        log.info("Grew the disk image to \(sizeGiB) GiB; the space is not allocated until it is used.")
    }
}

enum LinuxImageDownloader {
    static func download(from url: URL, to destination: URL) async throws -> String {
        log.info("Downloading \(url.absoluteString).")
        try? FileManager.default.removeItem(at: destination)

        let observer = DownloadProgress()
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await URLSession.shared.download(from: url, delegate: observer)
        } catch {
            throw VivError(
                .templateSnapshot,
                "Could not download \(url.absoluteString).",
                underlying: error,
                inspectionHints: ["curl -fsSLI \(url.absoluteString)"]
            )
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw VivError(
                .templateSnapshot,
                "\(url.absoluteString) returned HTTP \(http.statusCode). A pinned image whose "
                    + "compose has been replaced returns 404; pass --image-url and --image-sha256 "
                    + "to name the current one."
            )
        }

        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw VivError(
                .templateSnapshot,
                "Could not move the downloaded image to \(destination.path).",
                underlying: error
            )
        }

        log.info(
            "Downloaded \(BundleManager.fileSize(of: destination).formattedByteCount) to "
                + "\(destination.path)."
        )
        return try await Task.detached(priority: .utility) {
            try Digest.sha256HexOfFile(at: destination, stage: .templateSnapshot)
        }.value
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastLoggedTenth = -1

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let tenth = Int(totalBytesWritten * 10 / totalBytesExpectedToWrite)
        lock.lock()
        let shouldLog = tenth > lastLoggedTenth
        if shouldLog { lastLoggedTenth = tenth }
        lock.unlock()
        guard shouldLog, tenth < 10 else { return }
        log.info(
            "Downloaded \(tenth * 10)% "
                + "(\(totalBytesWritten.formattedByteCount) of "
                + "\(totalBytesExpectedToWrite.formattedByteCount))."
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
    }
}
