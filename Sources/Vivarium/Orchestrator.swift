import Foundation
import Virtualization

/// The workflow's explicit states.
///
/// Orchestration is a state machine rather than a chain of callbacks so that a
/// late delegate callback cannot advance the workflow twice. Every transition
/// is appended to `logs/state.jsonl`, which makes a failed run's timeline
/// readable without reconstructing it from log prose.
enum VivState: String, Codable, Sendable {
    case idle
    case preflight
    case preparingBundle
    case preparingRestoreImage
    case creatingInstallVM
    case installing
    case releasingInstallVM
    case snapshottingTemplate
    case stagingCode
    case creatingRunVM
    case startingWithProvisioning
    case resolvingAddress
    case waitingForSSH
    case preparingGuestWorkdir
    case executingAcceptanceCommand
    case executingTestCommand
    case harvestingArtifacts
    case validatingVirtioFS
    case requestingGuestShutdown
    case waitingForGuestStop
    case releasingRunVM
    case attachingArtifactReadOnly
    case validatingArtifact
    case ejectingArtifact
    case succeeded
    case failed
}

/// Timeouts, gathered so they are tunable in one place.
enum Timeouts {
    static let preflight = Duration.seconds(30)
    static let restoreImageLoad = Duration.seconds(120)
    static let templateClone = Duration.seconds(300)
    static let installation = Duration.seconds(90 * 60)
    static let firstBoot = Duration.seconds(15 * 60)
    static let addressDiscovery = Duration.seconds(10 * 60)
    /// The ceiling on a *single* poll attempt, as distinct from the budget for
    /// all of them. An attempt that overruns it is abandoned and retried, so a
    /// stuck one costs an interval instead of the whole run.
    static let discoveryAttempt = Duration.seconds(5 * 60)
    static let sshReadiness = Duration.seconds(10 * 60)
    static let acceptanceCommand = Duration.seconds(120)
    /// Copying the staged code out of the share into the guest workdir. Kept
    /// out of the test command's own budget: `--timeout` is what the user
    /// thinks their tests deserve, not what a large repository costs to copy.
    static let guestWorkdirPreparation = Duration.seconds(30 * 60)
    /// How long after the test command's own budget the attempt is abandoned
    /// outright. `ProcessRunner` already escalates SIGTERM to SIGKILL, so this
    /// only matters if the local ssh process cannot be killed at all — in which
    /// case the run continues with whatever output was streamed, rather than
    /// waiting forever on a process the kernel will not reap.
    static let testCommandGrace = Duration.seconds(30)
    static let harvest = Duration.seconds(10 * 60)
    /// How long `requestStop()` is given before the in-guest fallback.
    ///
    /// Deliberately short. `requestStop()` is a power-button press, and a macOS
    /// guest with a logged-in session answers it with a confirmation dialog
    /// nobody is there to click, so waiting the full shutdown budget on it just
    /// burns five minutes before trying the thing that works.
    static let stopRequestAcknowledgement = Duration.seconds(90)
    static let gracefulShutdown = Duration.seconds(5 * 60)
    static let diskAttach = Duration.seconds(120)
}

/// The machine-readable outcome of a run.
struct RunReport: Codable, Sendable {
    var runID: String
    var restoreImageVerifiedAsMacOS27OrLater: Bool
    var installSucceeded: Bool
    var firstBootProvisioningSucceeded: Bool
    var sshAuthenticationSucceeded: Bool
    var stdoutTokenMatched: Bool
    var stderrTokenMatched: Bool
    var remoteExitCodeMatched: Bool
    var observedRemoteExitCode: Int32?
    var virtioFSMarkerMatched: Bool
    var gracefulGuestStopObserved: Bool
    var destructiveStopRequired: Bool
    var artifactAttachedReadOnlyAfterRelease: Bool
    var artifactMarkerMatched: Bool
    var artifactEjected: Bool
    var systemDiskValidation: SystemDiskValidationResult?
    var guestAddress: String?
    var addressDiscoveryStrategy: String?
    var virtioFSMountPath: String?

    var allAcceptanceCriteriaPassed: Bool {
        restoreImageVerifiedAsMacOS27OrLater
            && installSucceeded
            && firstBootProvisioningSucceeded
            && sshAuthenticationSucceeded
            && stdoutTokenMatched
            && stderrTokenMatched
            && remoteExitCodeMatched
            && virtioFSMarkerMatched
            && gracefulGuestStopObserved
            && !destructiveStopRequired
            && artifactAttachedReadOnlyAfterRelease
            && artifactMarkerMatched
            && artifactEjected
    }

    var summaryText: String {
        func line(_ passed: Bool, _ label: String) -> String {
            "\(passed ? "pass" : "FAIL")  \(label)"
        }
        var lines = [
            line(restoreImageVerifiedAsMacOS27OrLater, "restore image verified as macOS 27 or later before install"),
            line(installSucceeded, "install succeeded"),
            line(firstBootProvisioningSucceeded, "first-boot provisioning succeeded without Setup Assistant"),
            line(sshAuthenticationSucceeded, "SSH authentication succeeded"),
            line(stdoutTokenMatched, "stdout token matched"),
            line(stderrTokenMatched, "stderr token matched"),
            line(remoteExitCodeMatched, "remote exit code == 23 (observed: "
                + (observedRemoteExitCode.map(String.init) ?? "none") + ")"),
            line(virtioFSMarkerMatched, "VirtioFS marker matched"),
            line(gracefulGuestStopObserved && !destructiveStopRequired, "graceful guest stop observed"),
            line(artifactAttachedReadOnlyAfterRelease, "artifact disk attached read-only after VM release"),
            line(artifactMarkerMatched, "artifact-disk marker matched"),
            line(artifactEjected, "artifact disk ejected")
        ]
        if let systemDiskValidation, systemDiskValidation.attempted {
            let passed = systemDiskValidation.markerMatched == true
            lines.append(
                "\(passed ? "pass" : "info")  optional: system-disk home marker — "
                    + systemDiskValidation.detail.trimmed(to: 200)
            )
        }
        return lines.joined(separator: "\n")
    }

    static func empty(runID: String) -> RunReport {
        RunReport(
            runID: runID,
            restoreImageVerifiedAsMacOS27OrLater: false,
            installSucceeded: false,
            firstBootProvisioningSucceeded: false,
            sshAuthenticationSucceeded: false,
            stdoutTokenMatched: false,
            stderrTokenMatched: false,
            remoteExitCodeMatched: false,
            observedRemoteExitCode: nil,
            virtioFSMarkerMatched: false,
            gracefulGuestStopObserved: false,
            destructiveStopRequired: false,
            artifactAttachedReadOnlyAfterRelease: false,
            artifactMarkerMatched: false,
            artifactEjected: false,
            systemDiskValidation: nil,
            guestAddress: nil,
            addressDiscoveryStrategy: nil,
            virtioFSMountPath: nil
        )
    }
}

struct OrchestratorOptions: Sendable {
    var ipsw: URL?
    var bundle: URL?
    var template: URL?
    var fromTemplate: URL?
    var guestAddress: String?
    var keepGoing = false
    var reuse = false
    var skipIPSWDigest = false
    var validateSystemDisk = false
    var queryLatestSupported = false
    var logsInAutomatically = GuestProvisioner.defaultLogsInAutomatically
    var username = "vivadmin"
    var fullName = "Vivarium Administrator"
    /// Only the selftest needs the detached-storage proof; see
    /// `VMConfigurationFactory.makeRunConfiguration`.
    var includesArtifactDisk = true
    /// Negative-test switches. Each makes the run configuration deliberately
    /// wrong in one specific way so the expected stage can be observed failing.
    var shareReadOnly = false
    var artifactReadOnly = false
    var artifactVolumeName: String?
    var disableRemoteLogin = false
}

/// Owns the run.
///
/// Every `VZVirtualMachine` creation and state-changing call happens on the
/// main actor, which is where Virtualization requires its objects to live.
/// Process I/O, hashing, and disk inspection are ordinary async work that runs
/// off it.
@MainActor
final class Orchestrator {
    private let options: OrchestratorOptions
    private var state: VivState = .idle
    private var stateLogURL: URL?
    private let startedAt = ContinuousClock.now

    private var paths: VMBundlePaths!
    /// Set for every run Vivarium sites itself, and `nil` only when the
    /// operator named a bundle directly with `--bundle`, which has no run
    /// directory around it.
    private var layout: RunLayout?
    private var manifest: RunManifest!
    private var credentials: GuestCredentials!
    private var report: RunReport!

    private var virtualMachine: VZVirtualMachine?
    private var eventRelay: VMEventRelay?
    private var lastReadinessGate: String?
    private var cleanupCompleted = false
    /// Phase timings for `viv run`, in pipeline order.
    private var phases: [PhaseTiming] = []

    init(options: OrchestratorOptions) {
        self.options = options
    }

    // MARK: - Entry points

    /// `preflight`: every cheap check, no bundle created.
    static func preflight(options: OrchestratorOptions) async -> PreflightReport {
        await PreflightChecker.run(
            ipsw: options.ipsw,
            targetDirectory: options.bundle ?? VivariumHome.root,
            queryLatestSupported: options.queryLatestSupported
        )
    }

    /// `all`: the full acceptance path.
    func runAll() async throws -> RunReport {
        try await runPreflightGate()
        let restoreImage = try await prepareBundleAndImage()
        try await install(restoreImage: restoreImage)
        try await snapshotTemplate(restoreImage: restoreImage)
        try await provisionAndValidate()
        return report
    }

    /// `install`: restore macOS into a fresh bundle and snapshot a template.
    func runInstall() async throws {
        try await runPreflightGate()
        let restoreImage = try await prepareBundleAndImage()
        try await install(restoreImage: restoreImage)
        try await snapshotTemplate(restoreImage: restoreImage)
        finish(outcome: "installed")
    }

    /// `provision`: boot an installed or templated bundle and run the proof.
    func runProvision() async throws -> RunReport {
        try Entitlement.require(stage: .preflight)

        if let fromTemplate = options.fromTemplate {
            try await prepareBundleFromTemplate(fromTemplate)
        } else {
            try attachExistingBundle()
        }
        try await provisionAndValidate()
        return report
    }

    /// `validate`: host-side disk validation against an existing bundle.
    func runValidate() async throws -> ArtifactValidationResult {
        try attachExistingBundle()
        transition(to: .attachingArtifactReadOnly)
        let result = try await DiskImageValidator.validateArtifact(
            paths: paths,
            expectations: manifest.expectations
        )
        try JSONCoding.write(result, to: paths.validationResult)
        transition(to: result.markerMatched ? .succeeded : .failed)
        return result
    }

    // MARK: - Phases

    private func runPreflightGate() async throws {
        transition(to: .preflight)
        try Entitlement.require(stage: .preflight)

        let preflight = await PreflightChecker.run(
            ipsw: options.ipsw,
            targetDirectory: options.bundle ?? VivariumHome.root,
            queryLatestSupported: options.queryLatestSupported
        )
        log.info("Preflight:\n\(preflight.text)")
        guard preflight.passed else {
            throw VivError(
                .preflight,
                "Preflight failed:\n"
                    + preflight.checks.filter { !$0.passed }
                        .map { "  \($0.name): \($0.detail)" }
                        .joined(separator: "\n")
            )
        }
    }

    /// Creates the bundle, generates run metadata, and loads the IPSW.
    private func prepareBundleAndImage() async throws -> LoadedRestoreImage {
        guard let ipsw = options.ipsw else {
            throw VivError(
                .bundlePreparation,
                "--ipsw is required. There is no download fallback: on this host "
                    + "VZMacOSRestoreImage.latestSupported resolves to macOS 26.6.1, which would "
                    + "produce a guest that silently ignores provisioning options."
            )
        }

        transition(to: .preparingRestoreImage)
        let restoreImage = try await RestoreImageManager.load(ipsw: ipsw)
        log.info(
            "Restore image: macOS \(restoreImage.versionString) (\(restoreImage.buildVersion)) "
                + "at \(ipsw.path)."
        )
        report?.restoreImageVerifiedAsMacOS27OrLater = true

        transition(to: .preparingBundle)
        try prepareRunMetadata()
        report.restoreImageVerifiedAsMacOS27OrLater = true

        manifest.ipswPath = ipsw.path
        manifest.ipswByteCount = BundleManager.fileSize(of: ipsw)
        manifest.restoreImageVersion = restoreImage.versionString
        manifest.restoreImageBuild = restoreImage.buildVersion

        if !options.skipIPSWDigest {
            // Hashing 22 GB takes a while, which is noise against a ninety-
            // minute install but would dominate a --from-template run, hence
            // the opt-out.
            log.info("Digesting the restore image; pass --skip-ipsw-digest to skip this.")
            manifest.ipswSHA256 = try await Task.detached(priority: .utility) {
                try Digest.sha256HexOfFile(at: ipsw, stage: .restoreImage)
            }.value
            log.info("Restore image sha256: \(manifest.ipswSHA256 ?? "unknown").")
        }

        try manifest.write(to: paths.runManifest)
        return restoreImage
    }

    private func prepareRunMetadata() throws {
        let runID = UUID().uuidString.lowercased()
        if let bundleRoot = options.bundle {
            paths = VMBundlePaths(root: bundleRoot)
        } else {
            let layout = RunLayout(runID: runID)
            self.layout = layout
            paths = layout.paths
        }

        try BundleManager.createBundle(paths: paths, reuse: options.reuse)
        log.attachFile(at: paths.runLog)
        stateLogURL = paths.stateLog

        credentials = GuestCredentials.generate(
            username: options.username,
            fullName: options.fullName
        )
        let macAddress = try VMConfigurationFactory.createAndPersistMACAddress(paths: paths)

        manifest = RunManifest.create(
            runID: runID,
            bundle: paths,
            credentials: credentials,
            macAddress: macAddress.string,
            logsInAutomatically: options.logsInAutomatically
        )
        if let volumeName = options.artifactVolumeName {
            manifest.expectations = RunExpectations(
                stdoutToken: manifest.expectations.stdoutToken,
                stderrToken: manifest.expectations.stderrToken,
                exitCode: manifest.expectations.exitCode,
                markerNonce: manifest.expectations.markerNonce,
                marker: manifest.expectations.marker,
                artifactVolumeName: volumeName
            )
        }
        report = RunReport.empty(runID: runID)

        log.info("Run \(runID) in \(paths.root.path).")
        log.info("Guest account: \(credentials.username) (\(credentials.fullName)); "
            + "the password is generated per run and is never written to disk or logged.")
        log.info("MAC address: \(macAddress.string).")
    }

    private func install(restoreImage: LoadedRestoreImage) async throws {
        transition(to: .creatingInstallVM)
        let macAddress = try VMConfigurationFactory.loadMACAddress(paths: paths, stage: .installation)

        let installer = MacOSInstaller(paths: paths)
        try await installer.createSystemDiskImage()

        transition(to: .installing)
        let shape = try await installer.install(restoreImage: restoreImage, macAddress: macAddress)

        transition(to: .releasingInstallVM)
        manifest.cpuCount = shape.cpuCount
        manifest.memorySizeBytes = shape.memorySize
        try manifest.write(to: paths.runManifest)
        report.installSucceeded = true
    }

    private func snapshotTemplate(restoreImage: LoadedRestoreImage) async throws {
        transition(to: .snapshottingTemplate)
        let templateRoot = options.template
            ?? DefaultLocations.template(ipswBuild: restoreImage.buildVersion)
        let template = TemplatePaths(root: templateRoot)

        try await TemplateManager.snapshot(
            from: paths,
            to: template,
            restoreImage: restoreImage,
            ipswSHA256: manifest.ipswSHA256,
            runID: manifest.runID
        )
        manifest.templatePath = template.root.path
        try manifest.write(to: paths.runManifest)
    }

    private func prepareBundleFromTemplate(_ templateRoot: URL) async throws {
        transition(to: .preparingBundle)

        var expectedBuild: String?
        if let ipsw = options.ipsw {
            let image = try await RestoreImageManager.load(ipsw: ipsw)
            expectedBuild = image.buildVersion
            report?.restoreImageVerifiedAsMacOS27OrLater = true
        }

        try prepareRunMetadata()
        if expectedBuild != nil {
            report.restoreImageVerifiedAsMacOS27OrLater = true
        }
        manifest.startedFromTemplate = true

        // The template's MAC address comes with it, replacing the one just
        // generated: the platform identity must stay internally consistent.
        let templateManifest = try await TemplateManager.materialize(
            template: TemplatePaths(root: templateRoot),
            into: paths,
            expectedIPSWBuild: expectedBuild
        )
        let macAddress = try VMConfigurationFactory.loadMACAddress(paths: paths, stage: .templateSnapshot)
        manifest.macAddress = macAddress.string
        manifest.templatePath = templateRoot.path
        manifest.restoreImageBuild = templateManifest.ipswBuild
        manifest.restoreImageVersion = templateManifest.ipswVersion
        manifest.cpuCount = VMConfigurationFactory.computeCPUCount()
        manifest.memorySizeBytes = VMConfigurationFactory.computeMemorySize()
        // The version gate was enforced when the template was installed, and
        // `materialize` has just checked this clone against that build. Leaving
        // the criterion at its `false` default would fail an otherwise perfect
        // run for a check that did happen, only in an earlier process.
        report.restoreImageVerifiedAsMacOS27OrLater =
            RestoreImageManager.satisfiesGuestVersionGate(templateManifest.ipswVersion)
        report.installSucceeded = true
        try manifest.write(to: paths.runManifest)
    }

    /// Adopts an already-installed bundle, reusing its `run.json`.
    private func attachExistingBundle() throws {
        guard let bundleRoot = options.bundle else {
            throw VivError(.bundlePreparation, "--bundle is required for this subcommand.")
        }
        paths = VMBundlePaths(root: bundleRoot)
        try BundleManager.requireInstalledBundle(paths: paths, stage: .bundlePreparation)

        log.attachFile(at: paths.runLog)
        stateLogURL = paths.stateLog

        manifest = try RunManifest.read(from: paths.runManifest)
        report = RunReport.empty(runID: manifest.runID)
        report.restoreImageVerifiedAsMacOS27OrLater =
            RestoreImageManager.satisfiesGuestVersionGate(manifest.restoreImageVersion)
        report.installSucceeded = true

        // A password is generated per run and never persisted, so a bundle
        // adopted from a previous invocation cannot be logged into. The
        // credential is only reusable within one process lifetime.
        credentials = GuestCredentials(
            fullName: manifest.fullName,
            username: manifest.username,
            password: ""
        )
    }

    // MARK: - Provisioned boot and proof

    private func provisionAndValidate() async throws {
        try await startProvisionedGuest()

        do {
            let ssh = try await connectToGuest()
            let result = try await runAcceptanceCommand(ssh: ssh)
            try validateVirtioFSMarker()
            try await shutdown(ssh: ssh)
            _ = result
        } catch {
            await abandonGuest(after: error)
            throw error
        }

        try await validateDetachedArtifact()

        if options.validateSystemDisk {
            report.systemDiskValidation = await DiskImageValidator.validateSystemDisk(
                paths: paths,
                expectations: manifest.expectations,
                username: credentials.username
            )
        }

        transition(to: report.allAcceptanceCriteriaPassed ? .succeeded : .failed)
        finish(outcome: report.allAcceptanceCriteriaPassed ? "succeeded" : "failed")
    }

    /// The half of a provisioned boot that both `selftest` and `run` need:
    /// everything from the cloned bundle to a VM that is executing.
    ///
    /// Deliberately outside the caller's `catch`: nothing has been started that
    /// could need stopping, and a failure here is about the configuration, not
    /// about a guest that has to be released.
    private func startProvisionedGuest() async throws {
        guard !credentials.password.isEmpty else {
            throw VivError(
                .provisioning,
                "This bundle's guest password is not available. Passwords are generated per run "
                    + "and deliberately never persisted, so a bundle can only be provisioned by the "
                    + "same invocation that created it. Use `all`, or `provision --from-template`."
            )
        }
        try await createAndStartRunVM()
    }

    /// The other half: find the guest, and hold a runner that has authenticated
    /// to it. Everything after this point differs between the selftest's
    /// scripted proof and a user's test command.
    private func connectToGuest() async throws -> SSHCommandRunner {
        let address = try await resolveAddress()
        let ssh = SSHCommandRunner(
            username: credentials.username,
            password: credentials.password,
            address: address,
            knownHostsFile: paths.knownHosts
        )
        try await waitForSSHReadiness(ssh: ssh)
        return ssh
    }

    /// Collects what can still be collected from a guest whose run has failed,
    /// then stops it — unless the operator asked to keep it for inspection.
    private func abandonGuest(after error: any Error) async {
        await captureFailureDiagnostics(error: error)
        if options.keepGoing {
            log.warn(
                "--keep-going: leaving the VM booted at "
                    + (report.guestAddress ?? "an undiscovered address")
                    + " so the guest can be inspected. Stop it with Ctrl-C when finished."
            )
        } else {
            await forceStopForCleanup()
        }
    }

    private func createAndStartRunVM() async throws {
        transition(to: .creatingRunVM)

        if options.includesArtifactDisk,
           !FileManager.default.fileExists(atPath: paths.artifactDisk.path) {
            try await ArtifactDiskManager.create(
                paths: paths,
                volumeName: manifest.expectations.artifactVolumeName
            )
        }

        let macAddress = try VMConfigurationFactory.loadMACAddress(paths: paths, stage: .runConfiguration)
        let configuration = try VMConfigurationFactory.makeRunConfiguration(
            paths: paths,
            macAddress: macAddress,
            cpuCount: manifest.cpuCount ?? VMConfigurationFactory.computeCPUCount(),
            memorySize: manifest.memorySizeBytes ?? VMConfigurationFactory.computeMemorySize(),
            includesArtifactDisk: options.includesArtifactDisk,
            shareReadOnly: options.shareReadOnly,
            artifactReadOnly: options.artifactReadOnly
        )

        let relay = VMEventRelay()
        eventRelay = relay
        let machine = VZVirtualMachine(configuration: configuration)
        machine.delegate = relay
        virtualMachine = machine

        transition(to: .startingWithProvisioning)
        let startOptions = try makeStartOptions()
        try await GuestProvisioner.start(virtualMachine: machine, options: startOptions)

        guard machine.state == .running || machine.state == .starting else {
            throw VivError(
                .provisioning,
                "The virtual machine is \(VMStateDescription.describe(machine.state)) immediately "
                    + "after start."
            )
        }
        report.firstBootProvisioningSucceeded = true
    }

    private func makeStartOptions() throws -> VZMacOSVirtualMachineStartOptions {
        if options.disableRemoteLogin {
            // Negative test 2: provisioning without Remote Login. The account
            // is still created, so the expected failure is at the SSH readiness
            // gate rather than at boot.
            log.warn("--disable-remote-login: provisioning without Remote Login, as a negative test.")
            let provisioning = VZMacGuestProvisioningOptions()
            provisioning.fullName = credentials.fullName
            provisioning.username = credentials.username
            provisioning.password = credentials.password
            provisioning.logsInAutomatically = options.logsInAutomatically
            provisioning.enablesRemoteLogin = false
            let startOptions = VZMacOSVirtualMachineStartOptions()
            try startOptions.setGuestProvisioning(provisioning)
            return startOptions
        }
        return try GuestProvisioner.makeStartOptions(
            credentials: credentials,
            logsInAutomatically: options.logsInAutomatically
        )
    }

    private func resolveAddress() async throws -> String {
        transition(to: .resolvingAddress)
        lastReadinessGate = "VM reached .running"

        let resolver = GuestAddressResolver(
            macAddress: manifest.macAddress,
            override: options.guestAddress
        )

        let deadline = ContinuousClock.now.advanced(by: Timeouts.addressDiscovery)
        var delay = Duration.seconds(2)
        var attempt = 0

        while ContinuousClock.now < deadline {
            attempt += 1
            guard let candidates = await withTimeout(Timeouts.discoveryAttempt, operation: {
                await resolver.candidates()
            }) else {
                log.warn(
                    "Attempt \(attempt) did not finish within \(Timeouts.discoveryAttempt); "
                        + "abandoning it and retrying."
                )
                continue
            }
            if let best = candidates.first {
                log.info("Guest address \(best.address) found by \(best.strategy) after \(attempt) attempts.")
                manifest.guestAddress = best.address
                manifest.addressDiscoveryStrategy = best.strategy
                report.guestAddress = best.address
                report.addressDiscoveryStrategy = best.strategy
                try? manifest.write(to: paths.runManifest)
                lastReadinessGate = "guest address resolved"
                return best.address
            }

            // The guest leaves no ARP entry until it has talked to the host, so
            // the cache is primed with bounded traffic confined to the NAT
            // bridge subnet. Priming starts on the second attempt rather than
            // later: ARP is the only strategy that matches the persisted MAC,
            // so the sooner it can answer, the less weight falls on Bonjour,
            // which can only ever produce candidates.
            if attempt >= 2 {
                log.debug("No ARP entry for \(manifest.macAddress) yet; priming the ARP cache.")
                if await withTimeout(Timeouts.discoveryAttempt, operation: {
                    await resolver.primeARPCache()
                }) == nil {
                    log.warn("ARP priming did not finish within \(Timeouts.discoveryAttempt).")
                }
            }

            log.debug("Attempt \(attempt): no address for \(manifest.macAddress) yet.")
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(15))
        }

        await GuestAddressResolver.captureDiagnostics(into: paths.diagnosticsDirectory)
        throw VivError(
            .addressDiscovery,
            "Could not find an address for MAC \(manifest.macAddress) within "
                + "\(Timeouts.addressDiscovery). Last gate passed: \(lastReadinessGate ?? "none"). "
                + "Pass --guest-address to bypass discovery.",
            inspectionHints: [
                "arp -an | grep -i \(manifest.macAddress)",
                "cat \(paths.diagnosticsDirectory.path)/arp.txt"
            ]
        )
    }

    /// Independent readiness gates.
    ///
    /// `.running` means virtual CPUs are executing; it says nothing about
    /// provisioning, networking, or sshd. Each gate is checked and reported
    /// separately so a timeout can name the last one that passed.
    private func waitForSSHReadiness(ssh: SSHCommandRunner) async throws {
        transition(to: .waitingForSSH)

        let deadline = ContinuousClock.now.advanced(by: Timeouts.sshReadiness)
        var delay = Duration.seconds(3)
        var attempt = 0
        var lastReason = "no attempt made"

        while ContinuousClock.now < deadline {
            attempt += 1

            if !(await TCPProbe.portIsOpen(host: ssh.address, port: 22, timeout: .seconds(5))) {
                lastReason = "TCP 22 is not accepting connections"
                log.debug("Readiness attempt \(attempt): \(lastReason).")
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(15))
                continue
            }
            lastReadinessGate = "TCP 22 accepted a connection"

            let attempted = await withTimeout(Timeouts.discoveryAttempt) { () -> Result<SSHResult, any Error> in
                do {
                    return .success(
                        try await ssh.run(
                            remoteCommand: AcceptanceScript.readinessCommand,
                            timeout: .seconds(30)
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }
            guard let attempted else {
                lastReason = "the readiness probe did not return within \(Timeouts.discoveryAttempt)"
                log.warn("Readiness attempt \(attempt): \(lastReason); retrying.")
                continue
            }
            let result = try attempted.get()

            switch result.outcome {
            case let .remoteExit(code) where code == 0:
                let whoami = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard whoami == credentials.username else {
                    lastReason = "authenticated but `id -un` returned \(whoami), not \(credentials.username)"
                    throw VivError(
                        .sshReadiness,
                        "SSH connected to \(ssh.address) but the session belongs to \(whoami), "
                            + "not the provisioned user \(credentials.username). The address may "
                            + "belong to a different machine."
                    )
                }
                lastReadinessGate = "SSH authenticated as \(whoami)"
                report.sshAuthenticationSucceeded = true
                log.info("SSH ready: authenticated to \(ssh.address) as \(whoami) after \(attempt) attempts.")
                return

            case let .remoteExit(code):
                lastReason = "readiness command exited \(code)"
            case let .transportFailure(detail):
                lastReason = "transport/auth failure: \(detail.trimmed(to: 200))"
            case let .localFailure(detail):
                lastReason = "local ssh failure: \(detail)"
            }

            log.debug("Readiness attempt \(attempt): \(lastReason).")
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(15))
        }

        await GuestAddressResolver.captureDiagnostics(into: paths.diagnosticsDirectory)
        throw VivError(
            .sshReadiness,
            "The guest at \(ssh.address) did not become SSH-ready within \(Timeouts.sshReadiness). "
                + "Last gate passed: \(lastReadinessGate ?? "none"). Last reason: \(lastReason).",
            inspectionHints: [
                "ssh \(credentials.username)@\(ssh.address)",
                "cat \(paths.diagnosticsDirectory.path)/arp.txt"
            ]
        )
    }

    private func runAcceptanceCommand(ssh: SSHCommandRunner) async throws -> SSHResult {
        transition(to: .executingAcceptanceCommand)

        let script = AcceptanceScript.acceptanceScript(
            expectations: manifest.expectations,
            username: credentials.username
        )
        let remoteCommand = ShellEscaping.base64RemoteCommand(script: script)

        let result = try await ssh.run(
            remoteCommand: remoteCommand,
            timeout: Timeouts.acceptanceCommand,
            redactedCommand: "<base64-encoded acceptance script, \(script.count) characters>"
        )

        try JSONCoding.write(
            AcceptanceResultReport(
                outcome: describe(result.outcome),
                expectedExitCode: manifest.expectations.exitCode,
                expectedStdoutToken: manifest.expectations.stdoutToken,
                expectedStderrToken: manifest.expectations.stderrToken,
                marker: manifest.expectations.marker,
                command: CommandResultReport(result.command)
            ),
            to: paths.sshResult
        )

        switch result.outcome {
        case let .transportFailure(detail):
            throw VivError(
                .sshCommand,
                "The acceptance command did not run: SSH transport or authentication failed. "
                    + "This is distinct from a remote command failure. Detail: \(detail.trimmed(to: 500))"
            )
        case let .localFailure(detail):
            throw VivError(.sshCommand, "The local ssh process failed: \(detail)")
        case let .remoteExit(code):
            report.observedRemoteExitCode = code
            report.remoteExitCodeMatched = code == manifest.expectations.exitCode
        }

        report.stdoutTokenMatched = result.stdoutText.contains(manifest.expectations.stdoutToken)
        report.stderrTokenMatched = result.stderrText.contains(manifest.expectations.stderrToken)

        log.info(
            "Acceptance command: exit \(report.observedRemoteExitCode.map(String.init) ?? "?") "
                + "(expected \(manifest.expectations.exitCode)), "
                + "stdout token \(report.stdoutTokenMatched ? "matched" : "MISSING"), "
                + "stderr token \(report.stderrTokenMatched ? "matched" : "MISSING")."
        )

        guard report.remoteExitCodeMatched, report.stdoutTokenMatched, report.stderrTokenMatched else {
            throw VivError(
                .sshCommand,
                """
                The acceptance command did not produce the expected result.
                  exit code: \(report.observedRemoteExitCode.map(String.init) ?? "none") \
                (expected \(manifest.expectations.exitCode))
                  stdout: \(result.stdoutText.trimmed(to: 1000))
                  stderr: \(result.stderrText.trimmed(to: 1000))
                """,
                inspectionHints: ["cat \(paths.sshResult.path)"]
            )
        }

        return result
    }

    /// Reads the VirtioFS marker directly on the host, while the VM still runs.
    ///
    /// A matching stdout token is not evidence the share worked. The host has
    /// to see the bytes in its own directory, otherwise the command "succeeded"
    /// without proving anything about directory sharing.
    private func validateVirtioFSMarker() throws {
        transition(to: .validatingVirtioFS)

        let markerURL = paths.sharedMarker
        guard let contents = try? Data(contentsOf: markerURL) else {
            throw VivError(
                .virtioFSValidation,
                "The guest reported success, but \(markerURL.path) does not exist on the host. "
                    + "The VirtioFS share did not carry the write.",
                inspectionHints: ["ls -la \(paths.sharedDirectory.path)"]
            )
        }

        let expected = manifest.expectations.markerFileContents
        report.virtioFSMarkerMatched = contents == expected
        report.virtioFSMountPath = AcceptanceScript.expectedSharePath

        guard report.virtioFSMarkerMatched else {
            throw VivError(
                .virtioFSValidation,
                "The VirtioFS marker at \(markerURL.path) does not match: expected "
                    + "\(expected.count) bytes (sha256 \(manifest.expectations.markerFileSHA256)), "
                    + "found \(contents.count) bytes (sha256 \(Digest.sha256Hex(contents)))."
            )
        }
        log.info("VirtioFS marker matched on the host at \(markerURL.path).")
    }

    // MARK: - Shutdown

    private func shutdown(ssh: SSHCommandRunner) async throws {
        transition(to: .requestingGuestShutdown)
        guard let machine = virtualMachine, let relay = eventRelay else {
            throw VivError(.guestShutdown, "No running virtual machine to stop.")
        }

        var requested = false
        if machine.canRequestStop {
            do {
                try machine.requestStop()
                requested = true
                log.info("Requested a graceful guest stop.")
            } catch {
                log.warn("requestStop() failed: \(VivError.describe(error))")
            }
        } else {
            log.warn("The guest cannot be asked to stop in its current state.")
        }

        transition(to: .waitingForGuestStop)
        if requested, await awaitGuestStop(relay: relay, timeout: Timeouts.stopRequestAcknowledgement) {
            try confirmStopped(machine)
            report.gracefulGuestStopObserved = true
            releaseRunVM()
            return
        }

        // Fall back to shutting down from inside the guest. The password goes
        // to sudo's stdin, never into the command line, so it never appears in
        // the guest's process list.
        log.warn("Falling back to an in-guest `sudo shutdown -h now`.")
        let result = try? await ssh.run(
            remoteCommand: AcceptanceScript.shutdownCommand,
            stdinData: Data((credentials.password + "\n").utf8),
            timeout: .seconds(60),
            redactedCommand: "sudo -S /sbin/shutdown -h now <password on stdin>"
        )
        if let result {
            // A transport failure here is the *expected* result, not a problem:
            // sshd goes down with the machine, so the connection is closed from
            // under the command that asked for the shutdown. Whether it worked
            // is decided by the guest actually stopping, below — never by this
            // exit status.
            log.info("In-guest shutdown returned \(describe(result.outcome)).")
        }

        if await awaitGuestStop(relay: relay, timeout: Timeouts.gracefulShutdown) {
            try confirmStopped(machine)
            report.gracefulGuestStopObserved = true
            releaseRunVM()
            return
        }

        // Destructive stop is a cleanup measure only. The run is marked failed
        // because a guest that was killed rather than shut down may not have
        // flushed, which makes the persistence result untrustworthy — which is
        // exactly the thing being measured.
        log.error("The guest did not stop gracefully; forcing a destructive stop.")
        report.destructiveStopRequired = true
        await forceStopForCleanup()
        throw VivError(
            .guestShutdown,
            "The guest did not stop gracefully — neither within "
                + "\(Timeouts.stopRequestAcknowledgement) of `requestStop()` nor within "
                + "\(Timeouts.gracefulShutdown) of an in-guest `shutdown -h now` — so a "
                + "destructive stop was used. Disk-persistence validation after a destructive "
                + "stop cannot distinguish a guest that never wrote from one that never flushed, "
                + "so this run is failed rather than validated.",
            inspectionHints: ["cat \(paths.runLog.path)"]
        )
    }

    private func awaitGuestStop(relay: VMEventRelay, timeout: Duration) async -> Bool {
        let outcome = await withTimeout(timeout, operation: { await relay.awaitStop() })
        switch outcome {
        case .some(.some(.guestDidStop)):
            return true
        case let .some(.some(.stoppedWithError(message))):
            log.warn("The guest stopped reporting an error: \(message)")
            return false
        case .some(.none):
            return false
        case .none:
            log.warn("The guest had not stopped after \(timeout).")
            return false
        }
    }

    private func confirmStopped(_ machine: VZVirtualMachine) throws {
        for _ in 0..<50 where machine.state != .stopped {
            // The delegate callback can arrive fractionally before the state
            // property settles.
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard machine.state == .stopped else {
            throw VivError(
                .guestShutdown,
                "The guest reported a stop but the VM is \(VMStateDescription.describe(machine.state))."
            )
        }
        log.info("The virtual machine reached .stopped.")
    }

    private func forceStopForCleanup() async {
        guard let machine = virtualMachine else { return }
        if machine.canStop {
            try? await machine.stop()
        }
        releaseRunVM()
    }

    /// Drops every object that could still hold the disk images open.
    ///
    /// Host validation must never attach an image a live VM can still write to,
    /// so this runs before any attach and the artifact eject is retried against
    /// transient busy errors.
    private func releaseRunVM() {
        transition(to: .releasingRunVM)
        virtualMachine?.delegate = nil
        virtualMachine = nil
        eventRelay?.finish()
        eventRelay = nil
        cleanupCompleted = true
    }

    // MARK: - Detached validation

    private func validateDetachedArtifact() async throws {
        guard virtualMachine == nil else {
            throw VivError(
                .artifactAttach,
                "Refusing to attach the artifact image while a virtual machine object still holds it."
            )
        }

        transition(to: .attachingArtifactReadOnly)
        let result = try await DiskImageValidator.validateArtifact(
            paths: paths,
            expectations: manifest.expectations
        )

        transition(to: .validatingArtifact)
        report.artifactAttachedReadOnlyAfterRelease = result.artifactAttachedReadOnly
        report.artifactMarkerMatched = result.markerMatched
        report.artifactEjected = result.ejected
        try JSONCoding.write(result, to: paths.validationResult)

        transition(to: .ejectingArtifact)
        guard result.markerMatched else {
            throw VivError(
                .artifactValidation,
                "The artifact disk's marker did not match: expected sha256 "
                    + "\(result.expectedMarkerSHA256), found \(result.markerSHA256).",
                inspectionHints: ["cat \(paths.validationResult.path)"]
            )
        }
        log.info("Artifact disk marker matched after detachment.")
    }

    // MARK: - Test runs

    /// `run`: the core pipeline.
    ///
    /// Returns a report for every outcome the guest is capable of producing —
    /// a passing test, a failing one, a timed-out one — and throws only when
    /// Vivarium itself could not do its job. That split is what makes the exit
    /// codes meaningful: the caller turns the report into 0 or 1, and a thrown
    /// error into 70.
    func runTest(plan: TestPlan) async throws -> TestRunReport {
        try Entitlement.require(stage: .preflight)
        let startedAt = Date()

        try await measure("materialise") {
            try await prepareBundleFromTemplate(plan.templateRoot)
        }
        guard let layout else {
            throw VivError(
                .bundlePreparation,
                "A test run needs a run directory under \(VivariumHome.runs.path); "
                    + "--bundle is not supported by `viv run`."
            )
        }

        try await measure("stage code") {
            transition(to: .stagingCode)
            _ = try await CodeStager.stage(from: plan.codeDirectory, to: layout.sharedCode)
            // Created before the guest boots, so the share the guest mounts
            // already has somewhere to put artifacts. A directory created
            // later on the host does appear in the guest, but relying on that
            // makes the run depend on VirtioFS invalidation timing for no
            // reason.
            try createDirectory(layout.sharedArtifacts, stage: .codeStaging)
            try createDirectory(layout.results, stage: .codeStaging)
        }

        try await startProvisionedGuest()

        let execution: TestExecution
        var artifacts: [ArtifactEntry] = []
        var warnings: [String] = []
        var shutdownError: (any Error)?
        do {
            let ssh = try await measure("boot to ssh") { try await connectToGuest() }

            try await measure("prepare guest") { try await prepareGuestWorkdir(ssh: ssh) }
            execution = try await measure("test") { try await executeTest(ssh: ssh, plan: plan) }
            (artifacts, warnings) = await measure("harvest") {
                await harvest(ssh: ssh, plan: plan, layout: layout, execution: execution)
            }

            // A guest that will not shut down is reported, not fatal: the test
            // has already produced its verdict, and throwing here would throw
            // the report away with it.
            do {
                try await measure("shutdown") { try await shutdown(ssh: ssh) }
            } catch {
                shutdownError = error
                log.error("The guest did not shut down cleanly: \(VivError.describe(error))")
            }
        } catch {
            await abandonGuest(after: error)
            throw error
        }

        let status: TestRunStatus = execution.timedOut
            ? .timedOut
            : (execution.exitCode == 0 ? .passed : .failed)

        // Everything that writes inside the bundle happens before the bundle is
        // deleted, and everything that writes inside `results/` happens after,
        // so that a successful run does not resurrect the directory it just
        // removed. The run log is copied across first: it is the only record of
        // how the guest was reached, and on a passing run its original goes
        // with the bundle.
        transition(to: status == .passed ? .succeeded : .failed)
        finish(outcome: status.rawValue)
        preserveRunLog(in: layout)
        let deleted = await cleanUp(status: status, plan: plan, layout: layout)

        let report = TestRunReport(
            runID: manifest.runID,
            vivariumVersion: Viv.releaseVersion,
            status: status,
            startedAt: startedAt,
            finishedAt: Date(),
            codeDirectory: plan.codeDirectory.path,
            manifestPath: plan.manifestPath?.path,
            projectName: plan.projectName,
            command: plan.command,
            commandSource: plan.commandSource,
            templatePath: plan.templateRoot.path,
            templateBuild: manifest.restoreImageBuild,
            guestUsername: credentials.username,
            guestAddress: self.report.guestAddress,
            guestWorkdir: GuestTestScript.workdirDisplayPath,
            timeoutSeconds: plan.timeout.elapsedSeconds,
            timedOut: execution.timedOut,
            testExitCode: execution.exitCode,
            phases: phases,
            totalSeconds: startedAt.distance(to: Date()),
            artifacts: artifacts,
            artifactByteCount: artifacts.reduce(0) { $0 + $1.byteCount },
            harvestWarnings: warnings
                + (shutdownError.map { ["the guest did not shut down cleanly: " + VivError.describe($0)] } ?? []),
            resultsPath: layout.results.path,
            deletedPaths: deleted,
            keptForInspection: deleted.isEmpty
        )

        try JSONCoding.write(report, to: layout.reportJSON)
        try Data(report.markdownText.utf8).write(to: layout.reportMarkdown, options: .atomic)
        return report
    }

    /// Copies the run log into `results/`, which is the one directory a run
    /// promises to keep.
    private func preserveRunLog(in layout: RunLayout) {
        guard FileManager.default.fileExists(atPath: paths.runLog.path) else { return }
        let destination = layout.results.appendingPathComponent("run.log")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: paths.runLog, to: destination)
        } catch {
            log.warn("Could not copy the run log into results/: \(VivError.describe(error))")
        }
    }

    /// What the test command did, whether or not it got to decide.
    private struct TestExecution {
        /// `nil` when the command never reached an exit: a timeout, or a
        /// connection that went away underneath it.
        let exitCode: Int32?
        let timedOut: Bool
        let stdout: Data
        let stderr: Data
    }

    /// Copies the staged code out of the share and into a guest-local workdir.
    private func prepareGuestWorkdir(ssh: SSHCommandRunner) async throws {
        transition(to: .preparingGuestWorkdir)

        let script = GuestTestScript.prepareScript
        let result = try await ssh.run(
            remoteCommand: ShellEscaping.base64RemoteCommand(script: script),
            timeout: Timeouts.guestWorkdirPreparation,
            redactedCommand: "<base64-encoded workdir preparation script>"
        )

        guard case let .remoteExit(code) = result.outcome, code == 0 else {
            throw VivError(
                .sshCommand,
                "The guest could not prepare its workdir from the share: \(describe(result.outcome)).\n"
                    + "  stdout: \(result.stdoutText.trimmed(to: 1000))\n"
                    + "  stderr: \(result.stderrText.trimmed(to: 1000))",
                inspectionHints: ["cat \(paths.runLog.path)"]
            )
        }
        log.info("Guest workdir \(GuestTestScript.workdirDisplayPath) is ready.")
    }

    /// Runs the user's command, streaming both of its streams to the terminal
    /// as they arrive and capturing them in full.
    private func executeTest(ssh: SSHCommandRunner, plan: TestPlan) async throws -> TestExecution {
        transition(to: .executingTestCommand)
        log.info("Running in the guest: \(plan.command)")

        let script = GuestTestScript.testScript(
            command: plan.command,
            environment: plan.environment,
            runID: manifest.runID
        )
        let remoteCommand = ShellEscaping.base64RemoteCommand(script: script)
        let redacted = "<base64-encoded test script, \(script.count) characters>"

        let echo = GuestEcho()
        let stdout = LineStream { echo.stdout($0) }
        let stderr = LineStream { echo.stderr($0) }

        // Two bounds on one attempt, per the rule the POC paid for: the ssh
        // process gets the user's budget and is killed at it, and the attempt
        // as a whole gets a short grace period on top so that a child the
        // kernel will not reap cannot hang the run. The streams are held here
        // rather than inside the attempt, so an abandoned attempt still leaves
        // its partial output where it can be reported.
        let attempted = await withTimeout(plan.timeout + Timeouts.testCommandGrace) {
            () -> Result<SSHResult, any Error> in
            do {
                return .success(try await ssh.runStreaming(
                    remoteCommand: remoteCommand,
                    timeout: plan.timeout,
                    redactedCommand: redacted,
                    onStdout: { stdout.append($0) },
                    onStderr: { stderr.append($0) }
                ))
            } catch {
                return .failure(error)
            }
        }
        stdout.finish()
        stderr.finish()

        guard let attempted else {
            log.error(
                "The test command did not return within \(plan.timeout) plus a "
                    + "\(Timeouts.testCommandGrace) grace period; abandoning it."
            )
            return TestExecution(exitCode: nil, timedOut: true, stdout: stdout.data, stderr: stderr.data)
        }
        let result = try attempted.get()

        switch result.outcome {
        case let .remoteExit(code):
            log.info("The test command exited \(code).")
            return TestExecution(exitCode: code, timedOut: false, stdout: stdout.data, stderr: stderr.data)

        case let .localFailure(detail):
            guard result.command.timedOut else {
                throw VivError(
                    .testExecution,
                    "The ssh process running the test command failed: \(detail)"
                )
            }
            log.error("The test command exceeded its \(plan.timeout) budget and was terminated.")
            return TestExecution(exitCode: nil, timedOut: true, stdout: stdout.data, stderr: stderr.data)

        case let .transportFailure(detail):
            // ssh reserves 255 for its own errors, so a test command that
            // exits 255 is indistinguishable from a connection that broke.
            // Saying both is more honest than picking one.
            throw VivError(
                .testExecution,
                "The connection to the guest failed while the test command was running: "
                    + detail.trimmed(to: 500)
                    + "\nA test command that exits 255 is reported the same way, because OpenSSH "
                    + "uses that status for its own failures; choose another status if the "
                    + "distinction matters.",
                inspectionHints: ["cat \(paths.runLog.path)"]
            )
        }
    }

    /// Gets everything the test produced back onto the host.
    ///
    /// Two halves. The manifest's globs are resolved *in the guest*, because
    /// that is where the files are, and their matches are copied into
    /// `$VIV_ARTIFACTS` — which is on the share, so the host already has them.
    /// The host then lifts the whole of `Shared/artifacts` into
    /// `results/artifacts`, which is what survives the bundle's deletion.
    ///
    /// Never throws. A pattern that matched nothing, or a copy that failed, is
    /// a warning on a report that still says what the test did; losing the
    /// verdict over a missing log file would be a poor trade.
    private func harvest(
        ssh: SSHCommandRunner,
        plan: TestPlan,
        layout: RunLayout,
        execution: TestExecution
    ) async -> ([ArtifactEntry], [String]) {
        transition(to: .harvestingArtifacts)
        var warnings: [String] = []

        do {
            try Data(execution.stdout).write(to: layout.testStdout, options: .atomic)
            try Data(execution.stderr).write(to: layout.testStderr, options: .atomic)
        } catch {
            warnings.append("could not write the captured streams: " + VivError.describe(error))
        }

        if !plan.artifactPatterns.isEmpty {
            let script = GuestTestScript.harvestScript(patterns: plan.artifactPatterns)
            let result = try? await ssh.run(
                remoteCommand: ShellEscaping.base64RemoteCommand(script: script),
                timeout: Timeouts.harvest,
                redactedCommand: "<base64-encoded artifact harvest script>"
            )
            if let result {
                // The guest's own complaints — an unmatched pattern, a failed
                // copy — arrive on stderr, one per line, already phrased for a
                // person. Anything else on that stream came from the shell
                // rather than from the script, and is the more interesting half
                // when the harvest went wrong in a way it did not anticipate.
                var unexpected: [String] = []
                for line in result.stderrText.split(separator: "\n") {
                    if line.hasPrefix("viv: ") {
                        warnings.append(String(line.dropFirst("viv: ".count)))
                    } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        unexpected.append(String(line))
                    }
                }
                if result.remoteExitCode != 0 {
                    warnings.append(
                        "the guest-side harvest reported \(describe(result.outcome))"
                            + (unexpected.isEmpty ? "" : ": " + unexpected.joined(separator: "; ").trimmed(to: 500))
                    )
                }
            } else {
                warnings.append("the guest-side harvest could not be run")
            }
        }

        do {
            try createDirectory(layout.resultsArtifacts, stage: .harvest)
            let copy = try await ProcessRunner.run(
                "/bin/cp", ["-c", "-R", layout.sharedArtifacts.path + "/.", layout.resultsArtifacts.path],
                timeout: Timeouts.harvest,
                stage: .harvest
            )
            if !copy.succeeded {
                warnings.append(
                    "copying the share's artifacts into results/ failed: "
                        + copy.stderrText.trimmed(to: 300)
                )
            }
        } catch {
            warnings.append("could not collect artifacts: " + VivError.describe(error))
        }

        let artifacts = inventory(of: layout.resultsArtifacts)
        log.info(
            "Harvested \(artifacts.count) file(s), "
                + artifacts.reduce(0) { $0 + $1.byteCount }.formattedByteCount
                + ", into \(layout.resultsArtifacts.path)."
        )
        return (artifacts, warnings)
    }

    /// Every regular file under `root`, by path relative to it.
    private func inventory(of root: URL) -> [ArtifactEntry] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return []
        }

        let prefix = root.standardizedFileURL.path + "/"
        var entries: [ArtifactEntry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            entries.append(
                ArtifactEntry(
                    path: path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path,
                    byteCount: Int64(values?.fileSize ?? 0)
                )
            )
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Deletes what a successful run no longer needs, and returns what went.
    ///
    /// Only a passing test earns the deletion. A failed or timed-out one leaves
    /// the bundle and the share exactly as the guest left them, because the
    /// next question is always "what did it actually do in there?".
    private func cleanUp(status: TestRunStatus, plan: TestPlan, layout: RunLayout) async -> [String] {
        guard status == .passed else {
            log.info("Keeping \(layout.root.path): the test did not pass.")
            return []
        }
        guard !plan.keepVM else {
            log.info("--keep-vm: keeping \(layout.bundleRoot.path).")
            return []
        }

        // The run log lives inside the bundle, and a logger still holding it
        // open recreates the directory the moment anything else is logged —
        // which is how a deleted bundle came back as an empty one. Its contents
        // are already in `results/run.log`; the rest of this run says its piece
        // on the terminal.
        log.detachFile()

        var deleted: [String] = []
        for url in [layout.bundleRoot, layout.shared] {
            do {
                if try RunStorage.remove(url) {
                    deleted.append(url.lastPathComponent)
                }
            } catch {
                // Not fatal, and not silent. The run passed; `viv gc` exists
                // for exactly the directory this leaves behind.
                log.warn(VivError.describe(error))
                return []
            }
        }
        return deleted
    }

    private func createDirectory(_ url: URL, stage: VivStage) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VivError(stage, "Cannot create \(url.path).", underlying: error)
        }
    }

    /// Times one phase, whether or not it succeeds.
    ///
    /// A failed run's timings are the more interesting ones: they say how far
    /// it got and where it spent the time getting there.
    private func measure<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        defer { phases.append(PhaseTiming(name: name, seconds: start.duration(to: .now).elapsedSeconds)) }
        return try await body()
    }

    // MARK: - Bookkeeping

    private func transition(to newState: VivState) {
        let previous = state
        state = newState
        log.info("State: \(previous.rawValue) -> \(newState.rawValue)")

        guard let stateLogURL else { return }
        let elapsed = startedAt.duration(to: .now)
        let entry: [String: Any] = [
            "from": previous.rawValue,
            "to": newState.rawValue,
            "elapsedSeconds": Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18,
            "at": Date().formatted(.iso8601)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        appendLine(data, to: stateLogURL)
    }

    private func appendLine(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    private func finish(outcome: String) {
        guard manifest != nil, paths != nil else { return }
        manifest.finishedAt = Date()
        manifest.outcome = outcome
        try? manifest.write(to: paths.runManifest)
        if let report {
            try? JSONCoding.write(report, to: paths.root.appendingPathComponent("report.json"))
        }
    }

    /// Records a failure alongside the run's other results.
    func recordFailure(_ error: any Error) {
        guard let paths else { return }
        let elapsed = startedAt.duration(to: .now)
        let failure = FailureReport(
            error: error,
            stage: stageForCurrentState(),
            vmState: virtualMachine.map { VMStateDescription.describe($0.state) },
            elapsedSeconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18,
            bundlePath: paths.root.path,
            cleanupCompleted: cleanupCompleted,
            lastReadinessGate: lastReadinessGate
        )
        try? JSONCoding.write(failure, to: paths.failureReport)
        finish(outcome: "failed")
        log.error("Failure report written to \(paths.failureReport.path).")

        // `results/` is the one directory a run promises to keep, so a failure
        // report that only lives inside the bundle is a failure report the
        // operator has to go looking for.
        if let layout, FileManager.default.fileExists(atPath: layout.results.path) {
            try? JSONCoding.write(failure, to: layout.failureReport)
        }
    }

    private func stageForCurrentState() -> VivStage {
        switch state {
        case .idle, .preflight: return .preflight
        case .preparingBundle: return .bundlePreparation
        case .preparingRestoreImage: return .restoreImage
        case .creatingInstallVM, .installing, .releasingInstallVM: return .installation
        case .snapshottingTemplate: return .templateSnapshot
        case .creatingRunVM: return .runConfiguration
        case .startingWithProvisioning: return .provisioning
        case .resolvingAddress: return .addressDiscovery
        case .waitingForSSH: return .sshReadiness
        case .executingAcceptanceCommand: return .sshCommand
        case .validatingVirtioFS: return .virtioFSValidation
        case .stagingCode: return .codeStaging
        case .preparingGuestWorkdir: return .sshCommand
        case .executingTestCommand: return .testExecution
        case .harvestingArtifacts: return .harvest
        case .requestingGuestShutdown, .waitingForGuestStop, .releasingRunVM: return .guestShutdown
        case .attachingArtifactReadOnly: return .artifactAttach
        case .validatingArtifact, .ejectingArtifact: return .artifactValidation
        case .succeeded, .failed: return .cleanup
        }
    }

    /// Collects guest-side state before the VM goes away.
    private func captureFailureDiagnostics(error: any Error) async {
        log.error("Failure: \(VivError.describe(error))")
        await GuestAddressResolver.captureDiagnostics(into: paths.diagnosticsDirectory)

        guard report.sshAuthenticationSucceeded,
              let address = report.guestAddress,
              !credentials.password.isEmpty else { return }

        let ssh = SSHCommandRunner(
            username: credentials.username,
            password: credentials.password,
            address: address,
            knownHostsFile: paths.knownHosts
        )
        guard let result = try? await ssh.run(
            remoteCommand: ShellEscaping.base64RemoteCommand(script: AcceptanceScript.diagnosticsScript),
            timeout: .seconds(60),
            redactedCommand: "<base64-encoded guest diagnostics script>"
        ) else { return }

        let body = result.stdoutText + "\n--- stderr ---\n" + result.stderrText
        try? Data(body.utf8).write(
            to: paths.diagnosticsDirectory.appendingPathComponent("guest-state.txt")
        )
        log.info("Guest diagnostics written to \(paths.diagnosticsDirectory.path)/guest-state.txt.")
    }

    private func describe(_ outcome: SSHOutcome) -> String {
        switch outcome {
        case let .remoteExit(code): return "remote exit \(code)"
        case let .transportFailure(detail): return "transport failure: \(detail.trimmed(to: 300))"
        case let .localFailure(detail): return "local failure: \(detail)"
        }
    }
}

/// The record written to `ssh-result.json`.
struct AcceptanceResultReport: Codable, Sendable {
    let outcome: String
    let expectedExitCode: Int32
    let expectedStdoutToken: String
    let expectedStderrToken: String
    let marker: String
    let command: CommandResultReport
}
