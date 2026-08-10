import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reading files the guest was free to write.
///
/// Everything the host reads back from a run — the VirtioFS marker, the
/// markers and manifests on the artifact volume — arrives at a path the guest
/// controls. A guest that replaces one of them with a symlink would otherwise
/// have a host validation read whatever it names, which is the whole shape of
/// the problem: guest-controlled data choosing which host file gets read, and
/// then quoted back into a report.
enum GuestWritableFile {
    /// Reads a file, refusing to follow a symlink at the final path component.
    ///
    /// `O_NOFOLLOW` fails the `open` outright rather than resolving the link,
    /// so a planted symlink is an error to report rather than a redirection to
    /// obey. Intermediate components are still resolved normally: they are
    /// Vivarium's own directories, not the guest's.
    static func read(at url: URL, stage: VivStage) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor != -1 else {
            let reason = String(cString: strerror(errno))
            throw VivError(
                stage,
                "Cannot read \(url.path): \(reason)",
                inspectionHints: ["ls -la \(url.deletingLastPathComponent().path)"]
            )
        }
        defer { close(descriptor) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw VivError(stage, "Failed while reading \(url.path).", underlying: error)
        }
    }
}
