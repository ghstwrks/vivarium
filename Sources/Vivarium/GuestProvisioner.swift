import Foundation
import Virtualization

/// Builds the first-boot start options that provision the guest.
///
/// macOS evaluates these options only on the first boot after restore, and the
/// framework cannot use them to reconfigure a guest it has already provisioned.
/// The consequences are enforced by the caller, not by this type: start once,
/// with options, and never retry without them against the same restored disk.
@MainActor
enum GuestProvisioner {
    /// Whether the guest is logged in automatically at startup.
    ///
    /// The plan originally specified `false`. It is `true` because macOS
    /// automounts external volumes through `diskarbitrationd` in the context of
    /// a console user session, and with nobody logged in the preformatted APFS
    /// artifact volume may never appear in the guest — failing the acceptance
    /// run for a reason unrelated to what is being proved.
    ///
    /// This does not weaken any acceptance criterion. The criterion is that no
    /// human interacts with Setup Assistant, which still holds. The remote
    /// script mounts the artifact volume by name as a fallback; once that
    /// fallback is confirmed to work unaided, this can go back to `false`. The
    /// value used is recorded in `run.json` either way.
    /// `nonisolated` so option parsing, which is not on the main actor, can use
    /// it as a default.
    nonisolated static let defaultLogsInAutomatically = true

    static func makeStartOptions(
        credentials: GuestCredentials,
        logsInAutomatically: Bool
    ) throws -> VZMacOSVirtualMachineStartOptions {
        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = credentials.fullName
        provisioning.username = credentials.username
        provisioning.password = credentials.password
        provisioning.logsInAutomatically = logsInAutomatically
        provisioning.enablesRemoteLogin = true

        let options = VZMacOSVirtualMachineStartOptions()
        do {
            // The Objective-C selector is setGuestProvisioningOptions:error:,
            // but Swift drops the suffix that matches the guestProvisioningOptions
            // property and imports it as setGuestProvisioning(_:) throws.
            // Verified by compiling against the macOS 27 SDK on this host.
            //
            // It validates internally and leaves the current options unchanged
            // on failure, so a separate validate() call would be redundant. A
            // validation failure is fatal before startup rather than a warning:
            // starting anyway would burn the guest's one provisionable boot.
            try options.setGuestProvisioning(provisioning)
        } catch {
            throw VivError(
                .provisioning,
                "The Virtualization framework rejected the guest provisioning options. "
                    + "Neither the options nor the password are logged; check the username "
                    + "and full name in run.json against the error code.",
                underlying: error
            )
        }
        return options
    }

    /// Starts the VM with provisioning options.
    static func start(
        virtualMachine: VZVirtualMachine,
        options: VZMacOSVirtualMachineStartOptions
    ) async throws {
        log.info("Starting the virtual machine with guest provisioning options.")
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                virtualMachine.start(options: options) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            throw VivError(
                .provisioning,
                "The virtual machine failed to start.",
                underlying: error,
                inspectionHints: [
                    "log show --last 10m --predicate 'subsystem == \"com.apple.Virtualization\"'"
                ]
            )
        }
    }
}
