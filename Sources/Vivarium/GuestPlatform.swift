import Foundation
import Virtualization

/// Everything about a run that depends on which operating system the guest is.
///
/// The pipeline in `Orchestrator` is the same for every guest: clone a
/// template, prepare the run directory, configure a virtual machine, start it,
/// find it, authenticate to it, run a command in it, harvest what the command
/// produced, and shut it down. What differs is the detail of each step — which
/// boot loader boots, how an account comes to exist, where the share appears,
/// which shell reads the scripts — and that detail lives here.
///
/// One conformance per operating system, so that adding one is a matter of
/// writing a file rather than of finding every place the existing one was
/// assumed. The two that exist are deliberately asymmetric where the operating
/// systems are: macOS is provisioned by the framework at first boot from a
/// restored disk, and Linux is provisioned by cloud-init at first boot from a
/// prebuilt one. Pretending those are the same mechanism would cost more in
/// indirection than it saved in lines.
protocol GuestPlatform: Sendable {
    var os: GuestOS { get }

    /// Every command this guest is asked to run.
    var scripts: GuestScripts { get }

    // MARK: - Templates

    /// The files a run's bundle clones out of a template.
    ///
    /// A template holds exactly what a guest needs to exist and nothing that
    /// belongs to a run: the restored or imported system disk, plus whatever
    /// identity the operating system will not boot without.
    var templateFilenames: [String] { get }

    /// The subset of `templateFilenames` a template's identity digest covers.
    ///
    /// Empty for a guest whose template is a system disk and nothing else: a
    /// digest over no files would be a constant, and asserting a constant is
    /// worse than not asserting.
    var identityDigestFilenames: [String] { get }

    /// Whether a run inherits the template's MAC address.
    ///
    /// True for macOS, where the address is part of a platform identity that
    /// has to stay internally consistent with the auxiliary storage beside it.
    /// False for a guest that takes a fresh one every run, which is the better
    /// default: a unique address per run is what keeps ARP-based discovery
    /// unambiguous when two of them are running.
    var templateSuppliesMACAddress: Bool { get }

    // MARK: - Preflight

    /// The host macOS version this guest needs, and why it needs it.
    var hostRequirement: HostRequirement { get }

    /// Free space a template plus one run should not start without.
    var requiredFreeBytes: Int64 { get }

    // MARK: - Running

    /// Creates the credential this run will authenticate with.
    ///
    /// The bundle exists by the time this is called, because a guest that
    /// authenticates by key needs somewhere to keep the private half.
    func makeCredentials(username: String, fullName: String, paths: VMBundlePaths) async throws
        -> GuestCredentials

    /// Writes whatever the guest needs that the template did not carry.
    ///
    /// The cloud-init seed for a Linux guest; nothing at all for macOS, which
    /// is provisioned through start options instead. Called after the template
    /// has been materialised and before the machine is configured.
    func prepareRun(_ request: ProvisioningRequest) async throws

    /// The configuration a run boots from.
    @MainActor
    func makeRunConfiguration(_ request: RunConfigurationRequest) throws
        -> VZVirtualMachineConfiguration

    /// The start options that provision a first boot, or `nil` for a guest that
    /// provisions itself from something already in its configuration.
    @MainActor
    func makeStartOptions(_ request: ProvisioningRequest) throws -> VZVirtualMachineStartOptions?

    // MARK: - Shutdown

    /// Which shutdown mechanism `viv run` tries first.
    var runShutdownOrder: ShutdownOrder { get }

    // MARK: - Acceptance

    /// Whether `viv selftest` asserts on a separate, detachable artifact disk.
    ///
    /// The proof is that a guest's write to a block device survives the machine
    /// being released — a property of the Virtualization framework rather than
    /// of any guest — and it costs a host-formatted volume the guest has to
    /// find and mount. A platform that does not claim it says so, and the
    /// report records the criteria as not asserted rather than as passed.
    var assertsArtifactDisk: Bool { get }

    /// Whether `viv selftest --validate-system-disk` can inspect this guest's
    /// system disk from the host afterwards.
    var supportsSystemDiskValidation: Bool { get }
}

/// The host macOS version a guest needs, with the reason attached.
///
/// The reason travels with the number because the numbers are not comparable:
/// a macOS guest needs macOS 27 because `VZMacGuestProvisioningOptions` does
/// not exist before it, while a Linux guest needs only what EFI booting needs.
/// A preflight that printed the number alone would make the stricter of the two
/// look arbitrary.
struct HostRequirement: Sendable {
    let majorVersion: Int
    let reason: String
}

/// Which shutdown mechanism gets the first attempt.
///
/// `selftest` keeps `requestStop()` first for every guest: its "graceful guest
/// stop observed" criterion documents that exact, measured behaviour.
/// `viv run` asks the platform, because the answer differs: on a macOS guest
/// with auto-login on, POC-RESULTS.md is unequivocal that `requestStop()` has
/// never once stopped a provisioned guest — it is a power-button press answered
/// by a confirmation dialog nobody is there to click — while a Linux guest
/// running systemd treats the same press as a request to power off and does.
enum ShutdownOrder: Sendable {
    case requestStopFirst
    case inGuestFirst
}

/// What a platform needs in order to give a run an account it can log in to.
struct ProvisioningRequest: Sendable {
    let paths: VMBundlePaths
    let credentials: GuestCredentials
    let runID: String
    /// A name the guest may take as its own. Already reduced to something a
    /// hostname is allowed to be.
    let hostname: String
    /// macOS only: whether the provisioned account is logged in at startup.
    let logsInAutomatically: Bool
    /// Negative test, macOS only: provision without Remote Login, so the run
    /// must fail at the SSH readiness gate rather than at boot.
    let disablesRemoteLogin: Bool
    /// Whether this run has an artifact directory on the share, which a guest
    /// that cannot write as the host user needs opened to it.
    let hasArtifactDirectory: Bool

    /// A hostname built from a run identifier.
    ///
    /// Run identifiers may contain dots and underscores and may be long; a
    /// hostname may contain neither and may not exceed 63 octets. Anything a
    /// label cannot hold becomes a dash, which is not reversible and is not
    /// meant to be: this is a label for a machine that exists for minutes, and
    /// its only job is to be different from the one next to it.
    static func hostname(forRunID runID: String) -> String {
        let allowed = runID.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let trimmed = String(allowed.prefix(59))
        return "viv-" + (trimmed.isEmpty ? "guest" : trimmed)
    }
}

/// What a platform needs in order to build the configuration a run boots from.
///
/// Not `Sendable`: `VZMACAddress` is a framework object, and everything built
/// from this stays on the main actor with the machine it configures.
struct RunConfigurationRequest {
    let paths: VMBundlePaths
    let macAddress: VZMACAddress
    let cpuCount: Int
    let memorySize: UInt64
    /// Whether to attach the separate block device the detached-storage proof
    /// needs. False for `viv run`, which harvests through the share.
    let includesArtifactDisk: Bool
    /// Negative test: attach the VirtioFS share read-only, so the guest's write
    /// to it must fail.
    let shareReadOnly: Bool
    /// Negative test: attach the artifact disk read-only.
    let artifactReadOnly: Bool
}
