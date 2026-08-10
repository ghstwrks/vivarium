import Foundation
import Virtualization

/// The workflow's explicit states.
///
/// Orchestration is a state machine rather than a chain of callbacks so that a
/// late delegate callback cannot advance the workflow twice. Every transition
/// is appended to `logs/state.jsonl`, which makes a failed run's timeline
/// readable without reconstructing it from log prose.
enum POCState: String, Codable, Sendable {
    case idle
    case preflight
    case preparingBundle
    case preparingRestoreImage
    case creatingInstallVM
    case installing
    case releasingInstallVM
    case snapshottingTemplate
    case creatingRunVM
    case startingWithProvisioning
    case resolvingAddress
    case waitingForSSH
    case executingAcceptanceCommand
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
    static let sshReadiness = Duration.seconds(10 * 60)
    static let acceptanceCommand = Duration.seconds(120)
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
    var username = "vreadmin"
    var fullName = "VRE Administrator"
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
final class POCOrchestrator {
    private let options: OrchestratorOptions
    private var state: POCState = .idle
    private var stateLogURL: URL?
    private let startedAt = ContinuousClock.now

    private var paths: VMBundlePaths!
    private var manifest: RunManifest!
    private var credentials: GuestCredentials!
    private var report: RunReport!

    private var virtualMachine: VZVirtualMachine?
    private var eventRelay: VMEventRelay?
    private var lastReadinessGate: String?
    private var cleanupCompleted = false

    init(options: OrchestratorOptions) {
        self.options = options
    }

    // MARK: - Entry points

    /// `preflight`: every cheap check, no bundle created.
    static func preflight(options: OrchestratorOptions) async -> PreflightReport {
        await PreflightChecker.run(
            ipsw: options.ipsw,
            targetDirectory: options.bundle ?? DefaultLocations.poc,
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
            targetDirectory: options.bundle ?? DefaultLocations.poc,
            queryLatestSupported: options.queryLatestSupported
        )
        log.info("Preflight:\n\(preflight.text)")
        guard preflight.passed else {
            throw POCError(
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
            throw POCError(
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
        let bundleRoot = options.bundle ?? DefaultLocations.runBundle(runID: runID)
        paths = VMBundlePaths(root: bundleRoot)

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
        report.installSucceeded = true
        try manifest.write(to: paths.runManifest)
    }

    /// Adopts an already-installed bundle, reusing its `run.json`.
    private func attachExistingBundle() throws {
        guard let bundleRoot = options.bundle else {
            throw POCError(.bundlePreparation, "--bundle is required for this subcommand.")
        }
        paths = VMBundlePaths(root: bundleRoot)
        try BundleManager.requireInstalledBundle(paths: paths, stage: .bundlePreparation)

        log.attachFile(at: paths.runLog)
        stateLogURL = paths.stateLog

        manifest = try RunManifest.read(from: paths.runManifest)
        report = RunReport.empty(runID: manifest.runID)
        report.restoreImageVerifiedAsMacOS27OrLater =
            (manifest.restoreImageVersion?.split(separator: ".").first).flatMap { Int($0) }
                .map { $0 >= RestoreImageManager.minimumGuestMajorVersion } ?? false
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
        guard !credentials.password.isEmpty else {
            throw POCError(
                .provisioning,
                "This bundle's guest password is not available. Passwords are generated per run "
                    + "and deliberately never persisted, so a bundle can only be provisioned by the "
                    + "same invocation that created it. Use `all`, or `provision --from-template`."
            )
        }

        try await createAndStartRunVM()

        do {
            let address = try await resolveAddress()
            let ssh = SSHCommandRunner(
                username: credentials.username,
                password: credentials.password,
                address: address,
                knownHostsFile: paths.knownHosts
            )

            try await waitForSSHReadiness(ssh: ssh)
            let result = try await runAcceptanceCommand(ssh: ssh)
            try validateVirtioFSMarker()
            try await shutdown(ssh: ssh)
            _ = result
        } catch {
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

    private func createAndStartRunVM() async throws {
        transition(to: .creatingRunVM)

        if !FileManager.default.fileExists(atPath: paths.artifactDisk.path) {
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
            throw POCError(
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
            let candidates = await resolver.candidates()
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
                await resolver.primeARPCache()
            }

            log.debug("Attempt \(attempt): no address for \(manifest.macAddress) yet.")
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(15))
        }

        await GuestAddressResolver.captureDiagnostics(into: paths.diagnosticsDirectory)
        throw POCError(
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

            let result = try await ssh.run(
                remoteCommand: AcceptanceScript.readinessCommand,
                timeout: .seconds(30)
            )

            switch result.outcome {
            case let .remoteExit(code) where code == 0:
                let whoami = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard whoami == credentials.username else {
                    lastReason = "authenticated but `id -un` returned \(whoami), not \(credentials.username)"
                    throw POCError(
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
        throw POCError(
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
            throw POCError(
                .sshCommand,
                "The acceptance command did not run: SSH transport or authentication failed. "
                    + "This is distinct from a remote command failure. Detail: \(detail.trimmed(to: 500))"
            )
        case let .localFailure(detail):
            throw POCError(.sshCommand, "The local ssh process failed: \(detail)")
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
            throw POCError(
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
            throw POCError(
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
            throw POCError(
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
            throw POCError(.guestShutdown, "No running virtual machine to stop.")
        }

        var requested = false
        if machine.canRequestStop {
            do {
                try machine.requestStop()
                requested = true
                log.info("Requested a graceful guest stop.")
            } catch {
                log.warn("requestStop() failed: \(POCError.describe(error))")
            }
        } else {
            log.warn("The guest cannot be asked to stop in its current state.")
        }

        transition(to: .waitingForGuestStop)
        if requested, await awaitGuestStop(relay: relay, timeout: Timeouts.gracefulShutdown) {
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
        throw POCError(
            .guestShutdown,
            "The guest did not stop gracefully within \(Timeouts.gracefulShutdown), so a "
                + "destructive stop was used. Disk-persistence validation after a destructive "
                + "stop cannot distinguish a guest that never wrote from one that never flushed, "
                + "so this run is failed rather than validated.",
            inspectionHints: ["cat \(paths.runLog.path)"]
        )
    }

    private func awaitGuestStop(relay: VMEventRelay, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in relay.events {
                    switch event {
                    case .guestDidStop:
                        return true
                    case .stoppedWithError:
                        return false
                    case .networkAttachmentDisconnected:
                        continue
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func confirmStopped(_ machine: VZVirtualMachine) throws {
        for _ in 0..<50 where machine.state != .stopped {
            // The delegate callback can arrive fractionally before the state
            // property settles.
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard machine.state == .stopped else {
            throw POCError(
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
            throw POCError(
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
            throw POCError(
                .artifactValidation,
                "The artifact disk's marker did not match: expected sha256 "
                    + "\(result.expectedMarkerSHA256), found \(result.markerSHA256).",
                inspectionHints: ["cat \(paths.validationResult.path)"]
            )
        }
        log.info("Artifact disk marker matched after detachment.")
    }

    // MARK: - Bookkeeping

    private func transition(to newState: POCState) {
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
    }

    private func stageForCurrentState() -> POCStage {
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
        case .requestingGuestShutdown, .waitingForGuestStop, .releasingRunVM: return .guestShutdown
        case .attachingArtifactReadOnly: return .artifactAttach
        case .validatingArtifact, .ejectingArtifact: return .artifactValidation
        case .succeeded, .failed: return .cleanup
        }
    }

    /// Collects guest-side state before the VM goes away.
    private func captureFailureDiagnostics(error: any Error) async {
        log.error("Failure: \(POCError.describe(error))")
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
