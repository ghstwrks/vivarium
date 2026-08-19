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
    static let releaseVersion = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "viv",
        abstract: "Run tests autonomously inside a fresh virtual machine.",
        discussion: """
            Vivarium prepares a guest, runs a command in it, harvests what the \
            command produced, and shuts the guest down. No human touches the \
            guest at any point.

            Two guests today: macOS 27, restored from a local IPSW, and Fedora, \
            imported from the disk image Fedora publishes. Which one a run uses \
            comes from its template, so only `viv template create` needs to be \
            told.

            The usual sequence is to build a template once, then run against \
            clones of it:

              viv template create --os fedora
              cd ~/my-project && viv run -- ./run-tests.sh

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

/// `--os` takes the operating system's own lowercase name.
///
/// The conformance is here rather than on the type, so that `GuestOS` — which
/// is written into every template and every report — does not depend on the
/// argument parser.
extension GuestOS: ExpressibleByArgument {}

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
            "Log the guest in automatically at startup. macOS guests only.",
            discussion: """
                On by default, and meaningless to a guest that is not macOS. \
                macOS automounts volumes through a console user session, so \
                with nobody logged in the artifact volume may never appear in \
                the guest. The guest script mounts it by name as a fallback, so \
                --no-auto-login is expected to work; it is a weaker path, not a \
                broken one.
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
        name: .customLong("os"),
        help: ArgumentHelp(
            "Which guest to check for: \(GuestOS.allNames).",
            discussion: """
                The checks differ by guest. A macOS guest needs a macOS 27 host \
                and around 80 GiB free; a Fedora guest needs neither, and \
                checking it against the stricter numbers would refuse a host \
                that is perfectly capable of running it.
                """,
            valueName: "name"
        )
    )
    var os: GuestOS = .macOS

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
        if ipsw != nil, os != .macOS {
            throw ValidationError("--ipsw is a macOS restore image; --os \(os.rawValue) has none.")
        }
        var options = OrchestratorOptions()
        options.guestOS = os
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
            A template is a guest that exists but has never been started. Runs \
            clone it — with APFS clonefile where the filesystem has one, and a \
            byte copy where it does not — and boot the clone, so no run ever \
            writes to the template and no run inherits what the last one left.

            Why that matters differs by guest, and the answer is the same either \
            way. macOS evaluates first-boot provisioning options exactly once, \
            on the first boot after a restore, so a template that had been \
            booted could never be provisioned again and every attempt would cost \
            another ninety-minute restore. A Fedora image imported from the \
            distribution costs minutes rather than an afternoon, but booting the \
            imported image in place would leave every run's host keys, logs, and \
            package cache in the image the next run started from.
            """,
        subcommands: [TemplateCreateCommand.self, TemplateListCommand.self],
        defaultSubcommand: TemplateListCommand.self
    )
}

struct TemplateCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Build a template from a restore image or a published disk image.",
        discussion: """
            What this costs depends entirely on the guest, because the two are \
            not the same operation wearing different flags.

            A macOS template is restored: --ipsw is mandatory, it takes around \
            ninety minutes, and it needs roughly 80 GiB free. There is no \
            download fallback, because on this host \
            VZMacOSRestoreImage.latestSupported resolves to macOS 26.6.1, which \
            silently ignores guest provisioning options and would produce a \
            template that can never be provisioned. The template is snapshotted \
            before the guest's first boot, because booting it would consume the \
            one provisionable boot the template exists to preserve.

            A Linux template is imported: the distribution already did the \
            installing, so this downloads a published disk image, checks it \
            against a digest pinned in Vivarium's own source, decompresses it, \
            and grows it to something a build can work in. Expect a few \
            minutes. Pass --image to import a file you already have, or \
            --image-url with --image-sha256 to name a different one.

              viv template create --ipsw ~/Downloads/UniversalMac_27.0_…_Restore.ipsw
              viv template create --os fedora

            Either way, the result is the same kind of thing: an immutable, \
            never-booted guest that runs clone in a fraction of a second.
            """
    )

    @Option(
        name: .customLong("os"),
        help: ArgumentHelp(
            "Which operating system the template holds: \(GuestOS.allNames).",
            valueName: "name"
        )
    )
    var os: GuestOS = .macOS

    @Option(
        name: .customLong("ipsw"),
        help: ArgumentHelp("Local macOS 27 restore image to restore from.", valueName: "path")
    )
    var ipsw: PathArgument?

    @Option(
        name: .customLong("image"),
        help: ArgumentHelp(
            "Import this disk image instead of downloading one.",
            discussion: """
                A raw disk image, or one compressed with xz — the form \
                distributions publish. Use it to import an image you already \
                have, or one Vivarium does not know about: a Fedora Server \
                guest image converted from qcow2, for instance, which nothing \
                above this flag assumes anything about.
                """,
            valueName: "path"
        )
    )
    var image: PathArgument?

    @Option(
        name: .customLong("image-url"),
        help: ArgumentHelp(
            "Download this disk image instead of the pinned one.",
            discussion: """
                Requires --image-sha256. The pin in Vivarium's source goes \
                stale when a distribution respins a compose and the old URL \
                stops resolving; this is what gets anyone unblocked without \
                waiting for a release.
                """,
            valueName: "url"
        )
    )
    var imageURL: String?

    @Option(
        name: .customLong("image-sha256"),
        help: ArgumentHelp(
            "The digest the disk image must have.",
            valueName: "hex"
        )
    )
    var imageSHA256: String?

    @Option(
        name: .customLong("template"),
        help: ArgumentHelp(
            "Where to write the template. Defaults to <home>/templates/<os>-<build>.bundle.",
            valueName: "path"
        )
    )
    var template: PathArgument?

    @Option(
        name: .customLong("disk-size"),
        help: ArgumentHelp(
            "The guest's system disk size, in GiB.",
            discussion: """
                Sparse: the space is not allocated until the guest writes to \
                it. Defaults to 128 for macOS, which is what a restore expects, \
                and \(LinuxTemplateBuilder.defaultDiskSizeGiB) for Linux, which \
                is a published cloud image grown to something a build can work \
                in.
                """,
            valueName: "gib"
        )
    )
    var diskSize: Int?

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
        if let diskSize, diskSize <= 0 {
            throw ValidationError("--disk-size must be a positive number of GiB.")
        }
        switch os {
        case .macOS: try await createMacOSTemplate()
        case .fedora: try await createLinuxTemplate()
        }
    }

    /// Restore a macOS guest and snapshot it.
    private func createMacOSTemplate() async throws {
        guard image == nil, imageURL == nil, imageSHA256 == nil else {
            throw ValidationError(
                "--image, --image-url, and --image-sha256 are for a guest that is imported from a "
                    + "published disk image. A macOS template is restored from an IPSW."
            )
        }
        guard let ipsw else {
            throw ValidationError(
                "--ipsw is required for a macOS template, and there is no download fallback: on "
                    + "this host VZMacOSRestoreImage.latestSupported resolves to macOS 26.6.1, "
                    + "which would produce a guest that silently ignores provisioning options."
            )
        }

        var options = OrchestratorOptions()
        options.guestOS = .macOS
        options.ipsw = ipsw.url
        options.template = template?.url
        options.skipIPSWDigest = skipIPSWDigest
        options.reuse = reuse
        options.diskSizeGiB = diskSize

        try await withOrchestrator(options) { orchestrator in
            try await orchestrator.runInstall()
            print("Template created.")
        }
    }

    /// Import a published Linux disk image as a template.
    ///
    /// No orchestrator and no virtual machine: nothing here boots anything, so
    /// there is no run to record a failure against and no guest to stop. What
    /// it produces is the same template every other command consumes.
    private func createLinuxTemplate() async throws {
        guard ipsw == nil else {
            throw ValidationError("--ipsw is a macOS restore image; --os \(os.rawValue) has none.")
        }
        guard image == nil || imageURL == nil else {
            throw ValidationError("Give either --image or --image-url, not both.")
        }
        if skipIPSWDigest {
            throw ValidationError(
                "--skip-ipsw-digest applies to a macOS restore. An imported image is always "
                    + "hashed: it is the only thing standing between a mirror and this guest."
            )
        }

        let source: LinuxImageSource
        if let image {
            source = .local(url: image.url, sha256: imageSHA256)
        } else if let imageURL {
            guard let url = URL(string: imageURL), url.scheme == "https" else {
                throw ValidationError("--image-url must be an https URL.")
            }
            guard let sha256 = imageSHA256 else {
                throw ValidationError(
                    "--image-url needs --image-sha256. An image fetched over the network and "
                        + "unpacked unchecked is whatever the network felt like sending."
                )
            }
            source = .remote(url: url, sha256: sha256)
        } else {
            guard let release = LinuxImageCatalogue.release(for: os) else {
                throw ValidationError(
                    "Vivarium has no pinned image for \(os.rawValue). Pass --image, or "
                        + "--image-url with --image-sha256."
                )
            }
            log.info("Using the pinned image: \(release.summary).")
            source = .catalogue(release)
            if let imageSHA256, imageSHA256 != release.sha256 {
                throw ValidationError(
                    "--image-sha256 was given without an image to apply it to, and it does not "
                        + "match the pinned one. Pass --image-url as well if a different image "
                        + "was meant."
                )
            }
        }

        try VivariumHome.requireUsable(stage: .templateSnapshot)
        let templateRoot = template?.url
            ?? DefaultLocations.template(os: os, build: source.build)

        try await LinuxTemplateBuilder.create(
            LinuxTemplateBuilder.Request(
                os: os,
                source: source,
                template: TemplatePaths(root: templateRoot),
                diskSizeGiB: diskSize ?? LinuxTemplateBuilder.defaultDiskSizeGiB,
                // The template's own parent, so a download lands on the volume
                // the template will live on rather than crossing one on the way.
                workingDirectory: templateRoot.deletingLastPathComponent()
            )
        )
        print("Template created at \(templateRoot.path).")
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

                Create one:
                  viv template create --ipsw ~/Downloads/UniversalMac_27.0_<build>_Restore.ipsw
                  viv template create --os fedora
                """)
            return
        }

        let rows: [[String]] = summaries.map { summary in
            let os: String
            let version: String
            if let manifest = summary.manifest {
                os = manifest.os.displayName
                version = manifest.osVersion + " (" + manifest.osBuild + ")"
            } else {
                os = "?"
                version = "unreadable template.json"
            }
            let size: String = summary.onDiskByteCount?.formattedByteCount ?? "unknown"
            let created: String = summary.createdAt.map { Self.dateStyle.format($0) } ?? "unknown"
            return [summary.name, os, version, size, created, summary.paths.root.path]
        }
        let headers = ["TEMPLATE", "OS", "VERSION", "ON DISK", "CREATED", "PATH"]
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
        name: .customLong("os"),
        help: ArgumentHelp(
            "Pick the newest template of this guest: \(GuestOS.allNames).",
            discussion: """
                Only narrows which template is chosen when --template was not \
                given; a named template already says what it is. With neither, \
                the newest template of any guest is used and the run says which \
                one it picked.
                """,
            valueName: "name"
        )
    )
    var os: GuestOS?

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

    @Option(
        name: .customLong("env-file"),
        help: ArgumentHelp(
            "Read NAME=value lines into the test command's environment.",
            discussion: """
                For the values that cannot be committed to viv.json — a token, \
                a password, a branch name. Each line is NAME=value, with the \
                value taken literally to the end of the line: no quote \
                stripping, no escapes, no interpolation. A name given here \
                overrides the same name in the manifest.

                A file rather than a flag because a command line is readable by \
                every other process on the host, and these are the values that \
                must not be. Nothing read from it is written to report.json or \
                to the run log.
                """,
            valueName: "path"
        )
    )
    var envFile: PathArgument?

    @Option(
        name: .customLong("run-id"),
        help: ArgumentHelp(
            "Name this run instead of generating an identifier for it.",
            discussion: """
                The run's directory is <home>/runs/<run-id>, so naming the run \
                tells the caller where the results will be before the run \
                starts — which is what a CI job needs in order to collect them \
                afterwards. It is also the guest's $VIV_RUN_ID.

                May contain ASCII letters, digits, dots, dashes, and \
                underscores, and may not begin with a dot or a dash. An \
                identifier already in use is refused rather than written over.
                """,
            valueName: "id"
        )
    )
    var runID: String?

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

    @Option(
        name: .customLong("command"),
        help: ArgumentHelp(
            "The command to run in the guest, as one argument.",
            discussion: """
                The same thing as the words after --, for a caller that has the \
                command as a single string and would otherwise have to decide \
                where its quoting ends. A multi-line command has no \
                word-splitting reading at all, so this is the spelling a script \
                or a CI action wants; the two are mutually exclusive.
                """,
            valueName: "script"
        )
    )
    var commandOption: String?

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
        options.runID = plan.runID
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
        if !testCommand.isEmpty, commandOption != nil {
            throw ValidationError(
                "--command and a trailing -- are two spellings of the same thing. Give one."
            )
        }
        if !testCommand.isEmpty {
            command = Self.joined(testCommand)
            commandSource = "command line"
        } else if let given = commandOption,
                  !given.trimmingCharacters(in: .whitespaces).isEmpty {
            command = given
            commandSource = "--command"
        } else if let test = project?.test, !test.trimmingCharacters(in: .whitespaces).isEmpty {
            command = test
            commandSource = VivManifest.filename
        } else {
            throw ValidationError("""
                No test command. Give one any of these ways:

                  viv run -- swift test
                  viv run --command 'swift test'

                or in \(codeDirectory.appendingPathComponent(VivManifest.filename).path):

                  { "test": "swift test" }
                """)
        }

        if let timeout, timeout <= 0 {
            throw ValidationError("--timeout must be a positive number of seconds.")
        }
        let seconds = timeout ?? project?.timeout ?? Self.defaultTimeoutSeconds

        // The manifest is what the project always wants; the file is what this
        // invocation needs, so the file wins — the same way the trailing
        // command wins over the manifest's. Which names it displaced is worth
        // a line in the log, because a value silently replaced by a CI system
        // is a confusing thing to debug from the guest's side.
        var environment = project?.environment ?? [:]
        if let envFile {
            guard FileManager.default.fileExists(atPath: envFile.path) else {
                throw ValidationError("No environment file at \(envFile.path).")
            }
            let supplied = try GuestEnvironment.read(envFile: envFile.url)
            let overridden = supplied.keys.filter { environment[$0] != nil }.sorted()
            if !overridden.isEmpty {
                log.info(
                    "\(envFile.path) overrides \(overridden.joined(separator: ", ")) "
                        + "from the manifest."
                )
            }
            environment.merge(supplied) { _, fromFile in fromFile }
        }

        let identifier = try resolvedRunID()

        let templateRoot = try await Self.resolveTemplate(named: template?.url, os: os)

        return TestPlan(
            runID: identifier,
            codeDirectory: codeDirectory,
            command: command,
            commandSource: commandSource,
            manifestPath: manifestURL,
            projectName: project?.name,
            artifactPatterns: project?.artifacts ?? [],
            environment: environment,
            timeout: .seconds(seconds),
            templateRoot: templateRoot,
            keepVM: keepVM
        )
    }

    /// Checks `--run-id` before anything is created.
    ///
    /// The identifier is a directory name under `<home>/runs`, so it is held to
    /// what a directory name may be here rather than at the point where the
    /// directory is created and a confusing path has already been printed. A
    /// leading dot is refused because `viv gc --all` skips hidden entries, and
    /// a leading dash because the resulting path reads as a flag in every
    /// command anyone would then run against it.
    private func resolvedRunID() throws -> String? {
        guard let runID else { return nil }

        func refuse(_ reason: String) -> ValidationError {
            ValidationError(
                "--run-id \"\(runID)\" \(reason). An identifier may contain ASCII "
                    + "letters, digits, dots, dashes, and underscores, may not begin with a "
                    + "dot or a dash, and may be at most \(Self.runIDLimit) characters."
            )
        }
        guard !runID.isEmpty else { throw refuse("is empty") }
        guard runID.count <= Self.runIDLimit else { throw refuse("is too long") }
        guard !runID.hasPrefix("."), !runID.hasPrefix("-") else {
            throw refuse("begins with \(runID.hasPrefix(".") ? "a dot" : "a dash")")
        }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard runID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw refuse("contains a character that may not appear in one")
        }

        // A second run under a name already taken would write its results over
        // the first one's, which is the one outcome a caller that named the run
        // in order to find those results afterwards cannot recover from.
        let directory = VivariumHome.run(id: runID)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw VivError(
                .bundlePreparation,
                "\(directory.path) already exists, so --run-id \(runID) is already taken. "
                    + "Choose another identifier, or delete that run first.",
                inspectionHints: ["ls -la \(directory.path)"]
            )
        }
        return runID
    }

    /// Chooses which template to clone.
    ///
    /// A named one wins outright. Otherwise the newest is used, narrowed to one
    /// guest where `--os` said so — and the choice is logged either way,
    /// because "the newest template" stopped being an obvious answer the moment
    /// a home could hold two operating systems.
    static func resolveTemplate(named: URL?, os: GuestOS?) async throws -> URL {
        if let named { return named }
        if let newest = await TemplateInventory.newest(os: os) {
            log.info(
                "Using the newest \(newest.manifest?.os.displayName ?? "") template: "
                    + newest.paths.root.path
            )
            return newest.paths.root
        }
        throw VivError(
            .bundlePreparation,
            """
            No \(os.map { $0.displayName + " " } ?? "")template in \
            \(VivariumHome.templates.path), and --template was not given.

            Create one:
              viv template create --ipsw <path to a macOS 27 restore image>
              viv template create --os fedora
            """
        )
    }

    /// Long enough for a CI system to concatenate a workflow run, an attempt,
    /// and a job name; short enough to stay readable in a path.
    static let runIDLimit = 128

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
            as the provisioned account, runs a scripted command, and checks the \
            criteria its guest claims: stdout, stderr, the remote exit code, the \
            VirtioFS share, and a graceful shutdown for every guest, plus an \
            artifact disk read back on the host after the machine is released \
            for a macOS one. A guest whose platform does not claim a criterion \
            has it reported as not asserted, with the reason, rather than as \
            passed. This is Vivarium's own integration test, inherited from the \
            proof of concept.

            With no path options it clones the newest template in the Vivarium \
            home. With --from-template it clones the one named. With --ipsw and \
            no template it takes the cold path: restore, snapshot a template, \
            then run the proof, which takes around ninety minutes.

            The guest's credential is generated per run and belongs to it: a \
            macOS guest's password is kept in memory and never written to \
            run.json, logged, or placed on a command line, and a Linux guest's \
            key pair lives in the run's own bundle and goes when it does. Either \
            way, a bundle from an earlier invocation cannot be provisioned by a \
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
        name: .customLong("os"),
        help: ArgumentHelp(
            "Prove it against the newest template of this guest: \(GuestOS.allNames).",
            valueName: "name"
        )
    )
    var os: GuestOS?

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
        if options.fromTemplate == nil, options.ipsw != nil, os == nil || os == .macOS {
            warmPath = false
        } else {
            options.fromTemplate = try await RunCommand.resolveTemplate(
                named: options.fromTemplate, os: os
            )
            warmPath = true
        }

        // Which guest this is decides which of the flags below mean anything,
        // and only the template knows. A flag that would be silently ignored is
        // refused instead: a negative test that quietly stops being a negative
        // test is exactly the kind of green nobody should trust.
        let guestOS = warmPath
            ? try TemplateManager.readManifest(of: TemplatePaths(root: options.fromTemplate!)).os
            : GuestOS.macOS
        options.guestOS = guestOS
        try refuseFlagsThatDoNotApply(to: guestOS)

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

    /// Refuses the flags that only mean something to a macOS guest.
    private func refuseFlagsThatDoNotApply(to guestOS: GuestOS) throws {
        guard !guestOS.platform.assertsArtifactDisk else { return }

        var offending: [String] = []
        if artifactVolumeName != nil { offending.append("--artifact-volume-name") }
        if artifactReadOnly { offending.append("--artifact-read-only") }
        if disableRemoteLogin { offending.append("--disable-remote-login") }
        guard offending.isEmpty else {
            throw ValidationError(
                "\(offending.joined(separator: ", ")) "
                    + (offending.count == 1 ? "applies" : "apply")
                    + " to the artifact disk and the framework's own provisioning, neither of "
                    + "which a \(guestOS.displayName) guest has. Its selftest reports those "
                    + "criteria as not asserted."
            )
        }
        if validateSystemDisk, !guestOS.platform.supportsSystemDiskValidation {
            throw ValidationError(
                "--validate-system-disk reads the guest's system disk on the host, which cannot "
                    + "read a \(guestOS.displayName) guest's filesystem."
            )
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
