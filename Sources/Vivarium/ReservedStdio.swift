import Foundation

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

    /// Call once, before anything else in the process could write to
    /// standard output.
    static func reserve() throws -> ReservedStdio {
        // Close-on-exec, so no child is handed the client's streams.
        let input = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
        let output = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3)
        guard input >= 0, output >= 0 else {
            throw VivError(
                .preflight,
                "Cannot take standard input and output for the MCP client: errno \(errno)."
            )
        }

        fflush(stdout)
        let null = open("/dev/null", O_RDONLY)
        guard null >= 0,
              dup2(null, STDIN_FILENO) >= 0,
              dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw VivError(
                .preflight,
                "Cannot redirect standard input and output away from the MCP client: errno \(errno)."
            )
        }
        close(null)

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
