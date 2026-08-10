import ArgumentParser
import Foundation

// MARK: - Entry point

/// The process entry point.
///
/// ArgumentParser can own `main()` itself, but its default mapping exits 64
/// (`EX_USAGE`) on a usage error, and Vivarium's contract says 2. Parsing is
/// therefore driven by hand so that every exit — usage, guest behaviour,
/// infrastructure — leaves through one place that also flushes the run log. A
/// truncated failure report is far more expensive to diagnose than the
/// microsecond the flush costs.
@main
enum VivariumMain {
    static func main() async {
        do {
            var command = try Viv.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            leave(0)
        } catch let exitCode as ExitCode {
            leave(exitCode.rawValue)
        } catch {
            // A help or version request reaches here as an error whose exit
            // code is success; the library knows how to print it, and it goes
            // to stdout because it is what was asked for.
            switch Viv.exitCode(for: error) {
            case .success:
                log.detachFile()
                Viv.exit(withError: error)
            case .validationFailure:
                write(Viv.fullMessage(for: error), to: FileHandle.standardError)
                leave(ExitStatus.usage)
            default:
                write("error: " + VivError.describe(error), to: FileHandle.standardError)
                leave(ExitStatus.of(error))
            }
        }
    }

    private static func leave(_ code: Int32) -> Never {
        log.detachFile()
        exit(code)
    }

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data((text + "\n").utf8))
    }
}

/// The exit codes Vivarium promises.
enum ExitStatus {
    /// The user's test failed, or the guest did not behave as asserted. Not a
    /// Vivarium failure.
    static let testFailure: Int32 = 1
    static let usage: Int32 = 2
    /// `EX_SOFTWARE`: Vivarium could not do its job.
    static let infrastructure: Int32 = 70

    /// Classifies a thrown error.
    ///
    /// Stage-based, because for `selftest` — the one command whose subject *is*
    /// the guest — a guest that would not boot or answer SSH is the finding,
    /// not a tooling fault. `run` means the opposite by the same errors and
    /// says so by wrapping them in `InfrastructureFailure`, which lands on the
    /// default below with everything else Vivarium could not do.
    static func of(_ error: any Error) -> Int32 {
        guard let vivError = error as? VivError else { return infrastructure }
        return vivError.stage.describesGuestBehaviour ? testFailure : infrastructure
    }
}

// MARK: - Root command

struct Viv: AsyncParsableCommand {
    /// One version string, quoted by `--version` and stamped into every
    /// `report.json`, so that a report can always be traced to a build.
    static let releaseVersion = "0.1.0-dev"

    static let configuration = CommandConfiguration(
        commandName: "viv",
        abstract: "Run tests autonomously inside a macOS virtual machine.",
        discussion: """
            Vivarium prepares a macOS 27 guest, runs a command in it, harvests \
            what the command produced, and shuts the guest down. No human \
            touches the guest at any point.

            The usual sequence is to build a template once from a local restore \
            image, then run against clones of it:

              viv template create --ipsw ~/Downloads/UniversalMac_27.0_…_Restore.ipsw
              cd ~/my-project && viv run -- swift test

            Vivarium keeps everything it owns under ~/.vivarium, or under \
            $VIVARIUM_HOME if that is set.
            """,
        version: releaseVersion,
        subcommands: [
            PreflightCommand.self,
            TemplateCommand.self,
            RunCommand.self,
            SelftestCommand.self,
            ValidateCommand.self,
            GCCommand.self
        ]
    )
}

// MARK: - Shared argument types

/// A filesystem path.
///
/// Tildes are expanded here as well as by the shell, because a path that
/// arrives quoted — or, later, out of a manifest — would otherwise be read as a
/// relative directory literally named `~`.
struct PathArgument: ExpressibleByArgument, Sendable {
    let url: URL

    init?(argument: String) {
        guard !argument.isEmpty else { return nil }
        url = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    var path: String { url.path }
}

/// The guest account and address options shared by the commands that boot a
/// guest.
struct GuestOptions: ParsableArguments {
    @Option(
        name: .customLong("guest-address"),
        help: ArgumentHelp(
            "Use this address instead of discovering one.",
            discussion: """
                Skips ARP and Bonjour discovery entirely. Useful when discovery \
                is the thing that is broken.
                """,
            valueName: "ip"
        )
    )
    var guestAddress: String?

    @Option(
        name: .customLong("username"),
        help: ArgumentHelp("Short name of the provisioned account.", valueName: "name")
    )
    var username: String = "vivadmin"

    @Option(
        name: .customLong("full-name"),
        help: ArgumentHelp("Full name of the provisioned account.", valueName: "name")
    )
    var fullName: String = "Vivarium Administrator"

    @Flag(
        inversion: .prefixedNo,
        help: ArgumentHelp(
            "Log the guest in automatically at startup.",
            discussion: """
                On by default. macOS automounts volumes through a console user \
                session, so with nobody logged in the artifact volume may never \
                appear in the guest. The guest script mounts it by name as a \
                fallback, so --no-auto-login is expected to work; it is a \
                weaker path, not a broken one.
                """
        )
    )
    var autoLogin: Bool = GuestProvisioner.defaultLogsInAutomatically
}

// MARK: - preflight

struct PreflightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preflight",
        abstract: "Check the host, the entitlement, free space, and a restore image.",
        discussion: """
            Creates nothing and starts no virtual machine. Its whole value is \
            turning a ninety-minute failure into a two-second one, so it is \
            cheap enough to run before anything else.

            Without --ipsw it checks only what does not depend on an image: \
            architecture, host version, the virtualization entitlement on this \
            binary, and free space in the Vivarium home.
            """
    )

    @Option(
        name: .customLong("ipsw"),
        help: ArgumentHelp(
            "Local macOS 27 restore image to inspect.",
            valueName: "path"
        )
    )
    var ipsw: PathArgument?

    @Flag(
        name: .customLong("query-latest"),
        help: """
            Also report what VZMacOSRestoreImage.latestSupported currently \
            offers. Informational: the downloadable image is not usable here.
            """
    )
    var queryLatest: Bool = false

    func run() async throws {
        var options = OrchestratorOptions()
        options.ipsw = ipsw?.url
        options.queryLatestSupported = queryLatest

        let report = await Orchestrator.preflight(options: options)
        print(report.text)
        guard report.passed else { throw ExitCode(ExitStatus.infrastructure) }
    }
}

// MARK: - template

struct TemplateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "template",
        abstract: "Create and inspect the guest templates runs are cloned from.",
        discussion: """
            macOS evaluates first-boot provisioning options exactly once, on the \
            first boot after a restore, so every guest must come from a freshly \
            restored disk. A template is that restored disk, snapshotted before \
            it is ever booted; runs clone it with APFS clonefile in a fraction \
            of a second instead of spending ninety minutes on another restore.
            """,
        subcommands: [TemplateCreateCommand.self, TemplateListCommand.self],
        defaultSubcommand: TemplateListCommand.self
    )
}

struct TemplateCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Restore macOS into a bundle and snapshot it as a template.",
        discussion: """
            Expect this to take around ninety minutes and to need roughly 80 GiB \
            of free space. The template is snapshotted before the guest's first \
            boot, because booting it would consume the one provisionable boot \
            the template exists to preserve.

            A local restore image is mandatory and there is no download \
            fallback: on this host VZMacOSRestoreImage.latestSupported resolves \
            to macOS 26.6.1, which silently ignores guest provisioning options \
            and would produce a template that can never be provisioned.
            """
    )

    @Option(
        name: .customLong("ipsw"),
        help: ArgumentHelp("Local macOS 27 restore image to restore from.", valueName: "path")
    )
    var ipsw: PathArgument

    @Option(
        name: .customLong("template"),
        help: ArgumentHelp(
            "Where to write the template. Defaults to <home>/templates/<build>.bundle.",
            valueName: "path"
        )
    )
    var template: PathArgument?

    @Flag(
        name: .customLong("skip-ipsw-digest"),
        help: """
            Skip hashing the restore image. Hashing 22 GB is noise against a \
            ninety-minute restore, so it is on by default; skip it when \
            iterating.
            """
    )
    var skipIPSWDigest: Bool = false

    @Flag(
        name: .customLong("reuse"),
        help: "Allow the working bundle directory to already exist and be non-empty."
    )
    var reuse: Bool = false

    func run() async throws {
        var options = OrchestratorOptions()
        options.ipsw = ipsw.url
        options.template = template?.url
        options.skipIPSWDigest = skipIPSWDigest
        options.reuse = reuse

        try await withOrchestrator(options) { orchestrator in
            try await orchestrator.runInstall()
            print("Template created.")
        }
    }
}

struct TemplateListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the templates in the Vivarium home."
    )

    func run() async throws {
        let directory = VivariumHome.templates
        let summaries = await TemplateInventory.summaries(in: directory)

        guard !summaries.isEmpty else {
            print("""
                No templates in \(directory.path).

                Create one from a local macOS 27 restore image:
                  viv template create --ipsw ~/Downloads/UniversalMac_27.0_<build>_Restore.ipsw
                """)
            return
        }

        let rows: [[String]] = summaries.map { summary in
            let version: String
            if let manifest = summary.manifest {
                version = "macOS " + manifest.ipswVersion
            } else {
                version = "unreadable template.json"
            }
            let size: String = summary.onDiskByteCount?.formattedByteCount ?? "unknown"
            let created: String = summary.createdAt.map { Self.dateStyle.format($0) } ?? "unknown"
            return [summary.name, version, size, created, summary.paths.root.path]
        }
        let headers = ["BUILD", "VERSION", "ON DISK", "CREATED", "PATH"]
        print(renderTable(headers: headers, rows: rows))
    }

    /// Local time without seconds: a template's age matters to the day, and a
    /// full ISO timestamp would push the path off the terminal.
    private static let dateStyle = Date.FormatStyle(date: .numeric, time: .shortened)
}

/// A simple, left-aligned, two-space-gutter table, shared by every command
/// that lists something rather than acting on one thing.
private func renderTable(headers: [String], rows: [[String]]) -> String {
    let widths = headers.indices.map { column in
        ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
    }
    func render(_ fields: [String]) -> String {
        fields.indices
            .map { $0 == fields.count - 1
                ? fields[$0]
                : fields[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
            .joined(separator: "  ")
    }
    return ([render(headers)] + rows.map(render)).joined(separator: "\n")
}

// MARK: - run

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a test command inside a fresh guest.",
        discussion: """
            The core pipeline: clone a template, provision and boot a guest, \
            stage a copy of the code directory into it, run the test command \
            with its output streamed here as it arrives, harvest artifacts, \
            write a report, and delete the expensive bundle if the test passed.

            The code directory is copied, not mounted: nothing the guest does \
            can reach the original. The copy is an APFS clone where the volume \
            allows one, so staging a large repository costs very little.

            The command comes from the manifest's "test" field, or after a \
            bare -- on the command line, which wins:

              viv run
              viv run --code ~/src/thing -- swift test --parallel

            Exits 0 when the test command exits 0, 1 when it does not or when \
            it exceeded --timeout, and 70 when Vivarium could not get far \
            enough to ask.
            """
    )

    @OptionGroup var guest: GuestOptions

    @Option(
        name: .customLong("code"),
        help: ArgumentHelp(
            "The directory to copy into the guest. Defaults to the working directory.",
            valueName: "path"
        )
    )
    var code: PathArgument?

    @Option(
        name: .customLong("manifest"),
        help: ArgumentHelp(
            "The project manifest. Defaults to <code>/viv.json when it exists.",
            valueName: "path"
        )
    )
    var manifest: PathArgument?

    @Option(
        name: .customLong("template"),
        help: ArgumentHelp(
            "Clone this template. Defaults to the newest in the Vivarium home.",
            valueName: "path"
        )
    )
    var template: PathArgument?

    @Option(
        name: .customLong("timeout"),
        help: ArgumentHelp(
            """
            Seconds the test command may take before it is abandoned. Bounds \
            the command alone, not the boot, the staging, or the harvest.
            """,
            valueName: "seconds"
        )
    )
    var timeout: Int?

    @Flag(
        name: .customLong("keep-vm"),
        help: """
            Keep VM.bundle even when the test passes. A failed run always keeps \
            everything.
            """
    )
    var keepVM: Bool = false

    @Flag(
        name: .customLong("keep-going"),
        help: ArgumentHelp(
            "On a run that did not pass, hold the guest for inspection.",
            discussion: """
                The guest lives inside this process, so holding it means this \
                command does not return: it waits, guest still executing, until \
                Ctrl-C. That force-stops the guest and exits with the status the \
                run had already earned. A passing run is never held.
                """
        )
    )
    var keepGoing: Bool = false

    /// The test command, after a bare `--`.
    ///
    /// `.postTerminator` so that the guest's command keeps its own flags: `viv
    /// run -- swift test --parallel` must not have `--parallel` read as
    /// Vivarium's.
    @Argument(
        parsing: .postTerminator,
        help: ArgumentHelp(
            "The command to run in the guest, after --. Overrides the manifest.",
            valueName: "command"
        )
    )
    var testCommand: [String] = []

    /// Vivarium's default budget for a test command.
    static let defaultTimeoutSeconds = 600

    func run() async throws {
        let plan = try await makePlan()

        var options = OrchestratorOptions()
        options.fromTemplate = plan.templateRoot
        options.guestAddress = guest.guestAddress
        options.username = guest.username
        options.fullName = guest.fullName
        options.logsInAutomatically = guest.autoLogin
        options.keepGoing = keepGoing
        // The share carries the artifacts, so a run needs no artifact disk and
        // none of the guest-side partitioning that goes with one. Selftest,
        // which exists to prove the disk path works, still asks for it.
        options.includesArtifactDisk = false

        let report: TestRunReport
        do {
            report = try await withOrchestrator(options) { orchestrator in
                try await orchestrator.runTest(plan: plan)
            }
        } catch {
            // Exit 1 belongs to the test command alone, and the test command's
            // verdict is in the report below. Anything thrown out of the
            // pipeline — including a guest that misbehaved — means Vivarium
            // never got to ask, which CI must not read as "your tests failed".
            throw InfrastructureFailure(error)
        }

        print("")
        print(report.summaryText)

        // A test that failed is not a Vivarium failure, so it leaves through
        // ExitCode rather than an error: no failure report, no "error:" prefix,
        // just the status the caller asked about.
        guard report.passed else { throw ExitCode(ExitStatus.testFailure) }
    }

    /// Reconciles the command line and the manifest before anything is created.
    ///
    /// Everything that can be wrong with the request — no command, no template,
    /// a missing code directory, a manifest with a typo in it — is found here,
    /// where the cost of being told is a message rather than a two-minute boot.
    private func makePlan() async throws -> TestPlan {
        // Resolved, not merely standardized: `cp -R` copies a symlinked
        // directory as the link, so staging `--code ~/work` where that is a
        // link would put a dangling link in the share and the guest would fail
        // several minutes later complaining that its staged code is missing.
        // The manifest is looked for at the resolved path too, so both halves
        // of the run agree on which directory the project is.
        let codeDirectory = (code?.url ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codeDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ValidationError("\(codeDirectory.path) is not a directory.")
        }

        // An explicitly named manifest that is not there is a mistake worth
        // reporting; a missing default one just means the project has no
        // manifest.
        let manifestURL: URL?
        if let manifest {
            guard FileManager.default.fileExists(atPath: manifest.path) else {
                throw ValidationError("No manifest at \(manifest.path).")
            }
            manifestURL = manifest.url
        } else {
            let candidate = codeDirectory.appendingPathComponent(VivManifest.filename)
            manifestURL = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        let project = try manifestURL.map { try VivManifest.read(from: $0) }

        let command: String
        let commandSource: String
        if !testCommand.isEmpty {
            command = Self.joined(testCommand)
            commandSource = "command line"
        } else if let test = project?.test, !test.trimmingCharacters(in: .whitespaces).isEmpty {
            command = test
            commandSource = VivManifest.filename
        } else {
            throw ValidationError("""
                No test command. Give one either way:

                  viv run -- swift test

                or in \(codeDirectory.appendingPathComponent(VivManifest.filename).path):

                  { "test": "swift test" }
                """)
        }

        if let timeout, timeout <= 0 {
            throw ValidationError("--timeout must be a positive number of seconds.")
        }
        let seconds = timeout ?? project?.timeout ?? Self.defaultTimeoutSeconds

        let templateRoot: URL
        if let template {
            templateRoot = template.url
        } else if let newest = await TemplateInventory.newest() {
            log.info("Using the newest template: \(newest.paths.root.path).")
            templateRoot = newest.paths.root
        } else {
            throw VivError(
                .bundlePreparation,
                """
                No template in \(VivariumHome.templates.path), and --template was not given.

                Create one:
                  viv template create --ipsw <path to a macOS 27 restore image>
                """
            )
        }

        return TestPlan(
            codeDirectory: codeDirectory,
            command: command,
            commandSource: commandSource,
            manifestPath: manifestURL,
            projectName: project?.name,
            artifactPatterns: project?.artifacts ?? [],
            environment: project?.environment ?? [:],
            timeout: .seconds(seconds),
            templateRoot: templateRoot,
            keepVM: keepVM
        )
    }

    /// Rebuilds a shell command line from the words after `--`.
    ///
    /// The shell has already removed one layer of quoting, so a word containing
    /// anything the guest's shell would act on gets that layer put back. Words
    /// that need nothing are left alone, so the command in the report reads the
    /// way it was typed.
    private static func joined(_ words: [String]) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./=:@+,")
        return words.map { word in
            word.isEmpty || word.unicodeScalars.contains(where: { !safe.contains($0) })
                ? ShellEscaping.singleQuoted(word)
                : word
        }.joined(separator: " ")
    }
}

// MARK: - selftest

struct SelftestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selftest",
        abstract: "Prove, end to end, that a guest can be provisioned and observed.",
        discussion: """
            Boots a guest with first-boot provisioning, authenticates over SSH \
            as the provisioned account, runs a scripted command, and checks \
            thirteen criteria covering stdout, stderr, the remote exit code, the \
            VirtioFS share, a graceful shutdown, and an artifact disk read back \
            on the host after the machine is released. This is Vivarium's own \
            integration test, inherited from the proof of concept.

            With no path options it clones the newest template in the Vivarium \
            home. With --from-template it clones the one named. With --ipsw and \
            no template it takes the cold path: restore, snapshot a template, \
            then run the proof, which takes around ninety minutes.

            The guest password is generated per run, kept in memory, and never \
            written to run.json, logged, or placed on a command line. That is \
            why a bundle from an earlier invocation cannot be provisioned by a \
            later one.

            Exits 1 when the guest failed to behave as asserted, and 70 when \
            Vivarium could not get far enough to ask.
            """
    )

    @OptionGroup var guest: GuestOptions

    @Option(
        name: .customLong("from-template"),
        help: ArgumentHelp("Clone this template instead of restoring.", valueName: "path")
    )
    var fromTemplate: PathArgument?

    @Option(
        name: .customLong("ipsw"),
        help: ArgumentHelp(
            """
            Local macOS 27 restore image. Given alone it selects the cold path: \
            restore, snapshot, then prove. Given with a template it only \
            asserts that the template was built from this image.
            """,
            valueName: "path"
        )
    )
    var ipsw: PathArgument?

    @Option(
        name: .customLong("artifact-volume-name"),
        help: ArgumentHelp("Volume name for the artifact disk.", valueName: "name")
    )
    var artifactVolumeName: String?

    @Flag(
        name: .customLong("validate-system-disk"),
        help: """
            Also attach the guest's system disk read-only afterwards and look \
            for the marker in the account's home directory. Reported, never \
            fatal: this path is more fragile than the artifact disk.
            """
    )
    var validateSystemDisk: Bool = false

    @Flag(
        name: .customLong("keep-going"),
        help: ArgumentHelp(
            "On failure, hold the guest for inspection instead of stopping it.",
            discussion: """
                The guest lives inside this process, so holding it means this \
                command does not return: it waits, guest still executing, until \
                Ctrl-C. That force-stops the guest and exits with the status the \
                failure had already earned.
                """
        )
    )
    var keepGoing: Bool = false

    @Flag(
        name: .customLong("reuse"),
        help: "Allow the working bundle directory to already exist and be non-empty."
    )
    var reuse: Bool = false

    @Flag(
        name: .customLong("skip-ipsw-digest"),
        help: "Skip hashing the restore image on the cold path."
    )
    var skipIPSWDigest: Bool = false

    @Flag(
        name: .customLong("share-read-only"),
        help: """
            Negative test: attach the VirtioFS share read-only, so the guest's \
            write to it must fail.
            """
    )
    var shareReadOnly: Bool = false

    @Flag(
        name: .customLong("artifact-read-only"),
        help: "Negative test: attach the artifact disk read-only."
    )
    var artifactReadOnly: Bool = false

    @Flag(
        name: .customLong("disable-remote-login"),
        help: """
            Negative test: provision without Remote Login, so the run must fail \
            at the SSH readiness gate rather than at boot.
            """
    )
    var disableRemoteLogin: Bool = false

    func run() async throws {
        var options = OrchestratorOptions()
        options.ipsw = ipsw?.url
        options.fromTemplate = fromTemplate?.url
        options.guestAddress = guest.guestAddress
        options.username = guest.username
        options.fullName = guest.fullName
        options.logsInAutomatically = guest.autoLogin
        options.artifactVolumeName = artifactVolumeName
        options.validateSystemDisk = validateSystemDisk
        options.keepGoing = keepGoing
        options.reuse = reuse
        options.skipIPSWDigest = skipIPSWDigest
        options.shareReadOnly = shareReadOnly
        options.artifactReadOnly = artifactReadOnly
        options.disableRemoteLogin = disableRemoteLogin

        // A named template wins over --ipsw, which then only pins the build the
        // template must have been made from. Restoring is the expensive path
        // and is never chosen on the operator's behalf.
        let warmPath: Bool
        if options.fromTemplate != nil {
            warmPath = true
        } else if options.ipsw != nil {
            warmPath = false
        } else {
            guard let newest = await TemplateInventory.newest() else {
                throw VivError(
                    .bundlePreparation,
                    """
                    No template in \(VivariumHome.templates.path), and neither \
                    --from-template nor --ipsw was given.

                    Create one:
                      viv template create --ipsw <path to a macOS 27 restore image>
                    """
                )
            }
            log.info("Using the newest template: \(newest.paths.root.path).")
            options.fromTemplate = newest.paths.root
            warmPath = true
        }

        try await withOrchestrator(options) { orchestrator in
            let report = warmPath
                ? try await orchestrator.runProvision()
                : try await orchestrator.runAll()
            print(report.summaryText)
            guard report.allAcceptanceCriteriaPassed else {
                throw VivError(.acceptance, "One or more acceptance criteria failed.")
            }
        }
    }
}

// MARK: - validate

struct ValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Re-check an existing bundle's artifact disk on the host.",
        discussion: """
            Attaches the bundle's artifact image read-only and compares its \
            marker against the expectations recorded in the bundle's run.json. \
            Starts no virtual machine, so it is safe to run against a bundle \
            kept from a failed run.
            """
    )

    @Option(
        name: .customLong("bundle"),
        help: ArgumentHelp("The VM bundle directory to validate.", valueName: "path")
    )
    var bundle: PathArgument

    func run() async throws {
        var options = OrchestratorOptions()
        options.bundle = bundle.url

        try await withOrchestrator(options) { orchestrator in
            let result = try await orchestrator.runValidate()
            print(result.markerMatched
                ? "pass  artifact-disk marker matched (\(result.markerByteCount) bytes)"
                : "FAIL  artifact-disk marker did not match")
            guard result.markerMatched else {
                throw VivError(.artifactValidation, "The artifact marker did not match.")
            }
        }
    }
}

// MARK: - gc

struct GCCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Delete run directories from the Vivarium home.",
        discussion: """
            Deletes only under <home>/runs — never templates, and never \
            anything the proof of concept left in ~/VRE-POC.

            With neither --all nor --older-than, a run counts as finished once \
            it has a results/report.json or a results/failure.json, and only \
            its heavy remains — VM.bundle and Shared/ — are deleted; results/ \
            is always kept. A run directory with a VM.bundle and no report at \
            all might still be running, so it is left alone with a note.

            --older-than widens that to delete whole run directories, results \
            included, once they are old enough by the report's finishedAt (or \
            the directory's own modification date, when there is no report). \
            --all deletes every run directory outright, kept-for-inspection \
            and reportless ones included.
            """
    )

    @Flag(name: .customLong("dry-run"), help: "List what would be deleted and delete nothing.")
    var dryRun: Bool = false

    @Flag(name: .customLong("all"), help: "Delete every run directory.")
    var all: Bool = false

    @Option(
        name: .customLong("older-than"),
        help: ArgumentHelp("Delete run directories older than this many days.", valueName: "days")
    )
    var olderThan: Int?

    func run() async throws {
        if all, olderThan != nil {
            throw ValidationError("--all and --older-than are mutually exclusive.")
        }
        if let olderThan, olderThan <= 0 {
            throw ValidationError("--older-than must be a positive number of days.")
        }

        let selection: RunGC.Selection = all
            ? .all
            : olderThan.map { .olderThan(days: $0) } ?? .heavyRemainsOfFinishedRuns

        let plan = try await RunGC.plan(selection: selection)
        guard !plan.actions.isEmpty else {
            print("Nothing to clean: no run directories in \(VivariumHome.runs.path).")
            return
        }

        let headers = ["RUN", "AGE", "ACTION", "SIZE", "STATUS"]
        let rows: [[String]] = plan.actions.map { action in
            let actionWord = action.isSkip ? "skip" : (dryRun ? "would delete" : "delete")
            let size = action.byteCount > 0 ? action.byteCount.formattedByteCount : "-"
            return [action.runID, action.ageDescription, actionWord, size, action.label]
        }
        print(renderTable(headers: headers, rows: rows))
        print("")

        guard !dryRun else {
            print("Would reclaim \(plan.reclaimableBytes.formattedByteCount).")
            return
        }

        try RunGC.execute(plan)
        print("Reclaimed \(plan.reclaimableBytes.formattedByteCount).")
    }
}

// MARK: - Orchestrator plumbing

/// Runs `body` against a fresh orchestrator, recording a failure report before
/// the error escapes.
///
/// The report has to be written from here rather than from the throwing code,
/// because only the orchestrator knows the state it reached and only the caller
/// knows the run is over.
@discardableResult
private func withOrchestrator<T: Sendable>(
    _ options: OrchestratorOptions,
    _ body: @escaping @Sendable (Orchestrator) async throws -> T
) async throws -> T {
    let orchestrator = await Orchestrator(options: options)
    do {
        return try await body(orchestrator)
    } catch {
        log.error(VivError.describe(error))
        await orchestrator.recordFailure(error)
        throw error
    }
}
