import Foundation

/// A bounded TCP connect probe.
///
/// Used as a readiness gate before spending an SSH invocation. Distinguishing
/// "nothing is listening on 22 yet" from "sshd answered but rejected the
/// credential" is what lets a timeout say which gate it stalled at, rather than
/// reporting a generic connection failure for ten minutes.
enum TCPProbe {
    /// Attempts a connection, returning whether it completed within `timeout`.
    ///
    /// A non-blocking connect plus `poll` is used rather than a blocking one:
    /// an unreachable guest would otherwise hold the caller for the kernel's
    /// own connect timeout, which is far longer than any gate here wants.
    static func portIsOpen(host: String, port: UInt16, timeout: Duration) async -> Bool {
        await Task.detached(priority: .utility) {
            connectSynchronously(host: host, port: port, timeout: timeout)
        }.value
    }

    private static func connectSynchronously(host: String, port: UInt16, timeout: Duration) -> Bool {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            return false
        }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var descriptors = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(clamping: timeout.components.seconds * 1000
            + timeout.components.attoseconds / 1_000_000_000_000_000)
        guard poll(&descriptors, 1, milliseconds) > 0 else { return false }

        // poll reporting POLLOUT only means the connect resolved; SO_ERROR says
        // whether it resolved into a connection or into ECONNREFUSED.
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return false
        }
        return socketError == 0
    }
}
