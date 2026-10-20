import Foundation
import Synchronization

/// The process's standard input and output, taken for an MCP client.
///
/// `reserve()` moves both to private descriptors that only the holder
/// uses, then points descriptor 0 at `/dev/null` and descriptor 1 at
/// standard error. From then on nothing else in the process can read the
/// client's frames or write into its stream: `print`, a `FileHandle` for
/// standard output, and every child that inherits descriptors 0 and 1 read
/// nothing and write to standard error instead.
struct ReservedStdio: Sendable {
    let clientInput: FileHandle
    let clientOutput: FileHandle

    /// Set by the first `reserve()`, which a second call cannot repeat: by
    /// then descriptors 0 and 1 are no longer the client's.
    private static let taken = Mutex(false)

    /// Call once, before anything else in the process could write to
    /// standard output. A failure leaves descriptors 0 and 1 as they were.
    static func reserve() throws -> ReservedStdio {
        let alreadyTaken = taken.withLock { taken in
            defer { taken = true }
            return taken
        }
        guard !alreadyTaken else {
            throw VivError(.preflight, "Standard input and output have already been taken for an MCP client.")
        }

        func failure(_ what: String) -> VivError {
            VivError(.preflight, "Cannot \(what) for the MCP client: errno \(errno).")
        }

        // Close-on-exec, so no child is handed the client's streams.
        let input = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
        guard input >= 0 else { throw failure("take standard input") }
        let output = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3)
        guard output >= 0 else {
            close(input)
            throw failure("take standard output")
        }
        let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard null >= 0 else {
            close(input)
            close(output)
            throw failure("open /dev/null")
        }

        fflush(stdout)
        guard dup2(null, STDIN_FILENO) >= 0 else {
            close(null)
            close(input)
            close(output)
            throw failure("point standard input at /dev/null")
        }
        close(null)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            // Standard input goes back to the client's, so the failure leaves
            // the process as it found it.
            _ = dup2(input, STDIN_FILENO)
            close(input)
            close(output)
            throw failure("point standard output at standard error")
        }

        // A client that goes away usually takes the reading end of standard
        // error with it. A write there is then an error the logger ignores,
        // rather than a SIGPIPE that kills the process, and its guest, in
        // the middle of the teardown.
        _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1)

        return ReservedStdio(
            clientInput: FileHandle(fileDescriptor: input, closeOnDealloc: true),
            clientOutput: FileHandle(fileDescriptor: output, closeOnDealloc: true)
        )
    }
}
