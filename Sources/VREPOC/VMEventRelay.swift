import Foundation
import Virtualization

/// Bridges `VZVirtualMachineDelegate` callbacks into an async stream.
///
/// Apple's `MacOSVirtualMachineDelegate` calls `exit()` from inside the
/// delegate methods. That is fine for a sample whose only job is to install,
/// but here a guest stopping is an ordinary, *expected* event that the
/// orchestrator has to await and then act on — validating a detached disk, for
/// instance. The delegate reports; the orchestrator decides.
final class VMEventRelay: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    enum Event: Sendable, CustomStringConvertible {
        case guestDidStop
        case stoppedWithError(String)
        case networkAttachmentDisconnected(String)

        var description: String {
            switch self {
            case .guestDidStop:
                return "guest stopped the virtual machine"
            case let .stoppedWithError(message):
                return "virtual machine stopped with error: \(message)"
            case let .networkAttachmentDisconnected(message):
                return "network attachment disconnected: \(message)"
            }
        }
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    override init() {
        var capturedContinuation: AsyncStream<Event>.Continuation!
        // Buffered rather than dropping: a stop event that arrives before the
        // orchestrator starts iterating must not be lost, or the shutdown wait
        // hangs until its timeout.
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
        super.init()
    }

    /// Ends the stream so any consumer awaiting it unblocks.
    func finish() {
        continuation.finish()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log.info("Delegate: guest stopped the virtual machine.")
        continuation.yield(.guestDidStop)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = POCError.describe(error)
        log.error("Delegate: virtual machine stopped with error: \(message)")
        continuation.yield(.stoppedWithError(message))
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        let message = POCError.describe(error)
        log.warn("Delegate: network attachment disconnected: \(message)")
        continuation.yield(.networkAttachmentDisconnected(message))
    }
}
