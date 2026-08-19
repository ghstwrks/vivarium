import Foundation

/// Builds a Linux template out of a published disk image.
///
/// This is the Linux counterpart of restoring an IPSW, and it is deliberately
/// not made to look like one. A macOS template costs ninety minutes because the
/// installer has to run; a Linux template costs a download and a decompression
/// because the distribution already ran it. What the two have in common is the
/// only thing that matters downstream: what they leave behind is an immutable,
/// never-booted disk that a run clones.
///
/// Nothing in here boots the image, and that is the answer to the state
/// question. An imported image used directly as a base would accumulate every
/// run's host keys, logs, package cache, and leftovers; a template that is
/// cloned and never started cannot, because no run ever writes to it. The
/// cloning is `clonefile` where the filesystem has it and a byte copy where it
/// does not, so the isolation is a property of the design rather than of APFS.
enum LinuxTemplateBuilder {
    /// The size the imported disk is grown to.
    ///
    /// A published cloud image is sized to be downloaded, not to be worked in:
    /// Fedora's is five gigabytes with about four free, which is not enough to
    /// install a toolchain and build anything with it. The file is grown by
    /// `ftruncate`, so the space costs nothing until the guest writes to it, and
    /// cloud-init grows the partition and the filesystem into the new room on
    /// first boot.
    static let defaultDiskSizeGiB = 64

    struct Request: Sendable {
        let os: GuestOS
        let source: LinuxImageSource
        let template: TemplatePaths
        let diskSizeGiB: Int
        /// Where to keep the downloaded file. The template's own parent, so a
        /// download lands on the volume the template will live on rather than
        /// crossing one on the way.
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

        // Built beside the template under a name `viv template list` ignores,
        // and moved into place only once it is complete. An import that fails
        // half way leaves something to delete rather than a template that looks
        // usable and is not.
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
                source: request.source.description,
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

    // MARK: - The image

    /// A published image on this machine, and whether Vivarium put it there.
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
                  let url = URL(string: request.source.description) else {
                throw VivError(.templateSnapshot, "No image URL to download.")
            }
            let destination = request.workingDirectory
                .appendingPathComponent(url.lastPathComponent)
            let digest = try await LinuxImageDownloader.download(from: url, to: destination)
            do {
                try require(digest: digest, matches: expected, describing: url.absoluteString)
            } catch {
                // A file that failed its digest is not kept: leaving it invites
                // somebody to pass it back with --image and skip the check that
                // just refused it.
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

    // MARK: - Unpacking

    /// Puts the raw disk where the template wants it, decompressing on the way
    /// if it arrived compressed.
    ///
    /// Returns the digest of the raw image, which is recorded in the template's
    /// manifest. It costs nothing to compute here — the bytes are going past
    /// anyway — and it is the only description of the template's contents that
    /// does not depend on remembering what it was made from.
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

    /// Grows the disk image, sparsely.
    ///
    /// `ftruncate` moves the end of the file without allocating anything, so a
    /// sixty-four gigabyte disk costs what the five gigabytes in it cost until
    /// the guest starts writing. A disk that is already larger than asked for is
    /// left alone: shrinking one would cut the partition table's backup header
    /// off the end and leave an image that does not boot.
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

/// Fetches a published image over HTTPS.
///
/// A plain download, with two things it will not do: it does not resume, and it
/// does not cache. Both are deliberate for now — a template is built rarely, and
/// a cache is a directory with a lifetime, an eviction policy, and a `viv gc`
/// flag, which is a feature rather than a detail. `--image` is the answer for
/// anyone who would rather keep the file: download it once, keep it, and point
/// at it.
enum LinuxImageDownloader {
    /// Downloads `url` to `destination`, returning the digest of what arrived.
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

/// Logs download progress at ten-percent granularity.
///
/// A five-hundred-megabyte download with no output for two minutes is
/// indistinguishable from one that has stalled, and the operator watching it
/// has no way to tell. Ten lines is enough to answer "is it moving?" without
/// being a progress bar in a log file.
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
        // Required by the protocol; the async `download(from:)` moves the file
        // itself and hands back the URL it moved it to.
    }
}
