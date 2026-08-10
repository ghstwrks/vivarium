import Foundation

/// The command-line entry point.
///
/// Argument parsing is hand-rolled rather than pulled from swift-argument-parser
/// so the package has no external dependencies: the point of this POC is to
/// establish what Virtualization.framework does, and a resolved dependency graph
/// is one more thing that could explain an unexpected result.
@main
struct CLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        guard let subcommand = arguments.first, !subcommand.hasPrefix("-") else {
            print(usage)
            exit(arguments.isEmpty ? 2 : 2)
        }

        if subcommand == "help" || subcommand == "--help" || subcommand == "-h" {
            print(usage)
            exit(0)
        }

        let options: OrchestratorOptions
        do {
            options = try parseOptions(Array(arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data(("error: \(POCError.describe(error))\n\n").utf8))
            print(usage)
            exit(2)
        }

        let exitCode = await dispatch(subcommand: subcommand, options: options)
        // Flush the log file before the process ends; a run whose failure report
        // is truncated is much harder to diagnose than one that took an extra
        // millisecond to exit.
        log.detachFile()
        exit(exitCode)
    }

    private static func dispatch(subcommand: String, options: OrchestratorOptions) async -> Int32 {
        switch subcommand {
        case "preflight":
            let report = await POCOrchestrator.preflight(options: options)
            print(report.text)
            return report.passed ? 0 : 1

        case "install":
            return await run(options: options) { orchestrator in
                try await orchestrator.runInstall()
                print("Installation complete.")
            }

        case "provision":
            return await run(options: options) { orchestrator in
                let report = try await orchestrator.runProvision()
                print(report.summaryText)
                guard report.allAcceptanceCriteriaPassed else {
                    throw POCError(.cleanup, "One or more acceptance criteria failed.")
                }
            }

        case "run", "all":
            return await run(options: options) { orchestrator in
                let report = try await orchestrator.runAll()
                print(report.summaryText)
                guard report.allAcceptanceCriteriaPassed else {
                    throw POCError(.cleanup, "One or more acceptance criteria failed.")
                }
            }

        case "validate":
            return await run(options: options) { orchestrator in
                let result = try await orchestrator.runValidate()
                print(result.markerMatched
                    ? "pass  artifact-disk marker matched (\(result.markerByteCount) bytes)"
                    : "FAIL  artifact-disk marker did not match")
                guard result.markerMatched else {
                    throw POCError(.artifactValidation, "The artifact marker did not match.")
                }
            }

        default:
            FileHandle.standardError.write(Data("error: unknown subcommand \(subcommand)\n\n".utf8))
            print(usage)
            return 2
        }
    }

    /// Runs a body against a fresh orchestrator, converting a throw into a
    /// non-zero status and a written failure report.
    private static func run(
        options: OrchestratorOptions,
        body: @escaping @Sendable (POCOrchestrator) async throws -> Void
    ) async -> Int32 {
        let orchestrator = await POCOrchestrator(options: options)
        do {
            try await body(orchestrator)
            return 0
        } catch {
            log.error(POCError.describe(error))
            await orchestrator.recordFailure(error)
            return 1
        }
    }

    // MARK: - Options

    private static func parseOptions(_ arguments: [String]) throws -> OrchestratorOptions {
        var options = OrchestratorOptions()
        var index = 0

        func nextValue(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw POCError(.preflight, "\(flag) requires a value.")
            }
            return arguments[index]
        }

        func url(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--ipsw":
                options.ipsw = url(try nextValue(for: argument))
            case "--bundle":
                options.bundle = url(try nextValue(for: argument))
            case "--template":
                options.template = url(try nextValue(for: argument))
            case "--from-template":
                options.fromTemplate = url(try nextValue(for: argument))
            case "--guest-address":
                options.guestAddress = try nextValue(for: argument)
            case "--username":
                options.username = try nextValue(for: argument)
            case "--full-name":
                options.fullName = try nextValue(for: argument)
            case "--artifact-volume-name":
                options.artifactVolumeName = try nextValue(for: argument)
            case "--keep-going":
                options.keepGoing = true
            case "--reuse":
                options.reuse = true
            case "--skip-ipsw-digest":
                options.skipIPSWDigest = true
            case "--validate-system-disk":
                options.validateSystemDisk = true
            case "--query-latest":
                options.queryLatestSupported = true
            case "--no-auto-login":
                options.logsInAutomatically = false
            case "--auto-login":
                options.logsInAutomatically = true
            case "--share-read-only":
                options.shareReadOnly = true
            case "--artifact-read-only":
                options.artifactReadOnly = true
            case "--disable-remote-login":
                options.disableRemoteLogin = true
            default:
                throw POCError(.preflight, "unknown option \(argument)")
            }
            index += 1
        }

        return options
    }

    private static let usage = """
    vre-poc — a proof of concept for macOS 27 guest provisioning under
    Virtualization.framework.

    USAGE
      vre-poc <subcommand> [options]

    SUBCOMMANDS
      preflight   Check the host, the entitlement, free space, and (with --ipsw)
                  the restore image. Creates nothing.
      install     Restore macOS into a new bundle and snapshot a template.
      provision   Boot an installed bundle with provisioning options and run the
                  acceptance proof. Requires --from-template, because a guest
                  password is generated per run and never persisted.
      all         install followed by provision, in one process.
      validate    Attach an existing bundle's artifact disk read-only and check
                  its marker. Does not start a virtual machine.

    OPTIONS
      --ipsw <path>            Local macOS 27 restore image. Required for
                               install and all: there is no download fallback,
                               because the latest downloadable image on this
                               host is macOS 26.6.1, which ignores provisioning
                               options entirely.
      --bundle <path>          Bundle directory. Defaults to
                               ~/VRE-POC/<run-id>/VM.bundle.
      --template <path>        Where to write the post-restore template.
                               Defaults to ~/VRE-POC/templates/<build>.bundle.
      --from-template <path>   Clone this template instead of restoring.
      --guest-address <ip>     Skip address discovery and use this address.
      --username <name>        Provisioned account short name (default vreadmin).
      --full-name <name>       Provisioned account full name.
      --artifact-volume-name   Volume name for the artifact disk (default
                               VREArtifacts).
      --reuse                  Allow a non-empty existing bundle directory.
      --keep-going             On failure, leave the guest running for manual
                               inspection instead of stopping it.
      --skip-ipsw-digest       Skip hashing the restore image.
      --validate-system-disk   Also attach the system disk read-only and look
                               for the marker in the guest's home directory.
                               Optional: this path is more fragile than the
                               artifact disk and a failure is reported, not
                               fatal.
      --query-latest           Report what latestSupported currently offers.
      --no-auto-login          Provision without automatic login. The artifact
                               volume may then not automount; the acceptance
                               script mounts it by name as a fallback.
      --share-read-only        Negative test: attach the VirtioFS share
                               read-only, so the guest's write must fail.
      --artifact-read-only     Negative test: attach the artifact disk
                               read-only.
      --disable-remote-login   Negative test: provision without Remote Login,
                               so the run must fail at the SSH readiness gate.

    ENVIRONMENT
      VRE_DEBUG=1              Emit debug-level logging.

    NOTES
      The generated guest password is held in memory only. It is never written
      to run.json, never logged, and never placed on a command line.
    """
}
