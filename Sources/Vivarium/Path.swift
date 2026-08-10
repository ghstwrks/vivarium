import Foundation

/// Every path inside one run's VM bundle.
///
/// This replaces the Apple sample's file-scope globals (`vmBundlePath`,
/// `diskImageURL`, and friends), which hardcode `~/VM.bundle` and therefore
/// make two concurrent runs, or a failed run kept for inspection, impossible.
struct VMBundlePaths: Sendable {
    let root: URL

    /// The host directory exported to the guest over VirtioFS.
    ///
    /// It lives outside the bundle whenever a `RunLayout` supplies it, because
    /// the bundle is the expensive thing a successful run deletes and the share
    /// carries the harvest back. Keeping the two separate means cleanup is a
    /// directory removal rather than a selective one. A bundle named directly
    /// with `--bundle` has no run directory around it, so it keeps its share
    /// inside itself and stays self-contained.
    let sharedDirectory: URL

    var auxiliaryStorage: URL { root.appendingPathComponent("AuxiliaryStorage") }
    var systemDisk: URL { root.appendingPathComponent("Disk.img") }
    var hardwareModel: URL { root.appendingPathComponent("HardwareModel") }
    var machineIdentifier: URL { root.appendingPathComponent("MachineIdentifier") }
    var macAddress: URL { root.appendingPathComponent("MACAddress") }
    var artifactDisk: URL { root.appendingPathComponent("Artifact.raw") }
    var knownHosts: URL { root.appendingPathComponent("ssh_known_hosts") }
    var runManifest: URL { root.appendingPathComponent("run.json") }
    var sshResult: URL { root.appendingPathComponent("ssh-result.json") }
    var validationResult: URL { root.appendingPathComponent("validation.json") }
    var failureReport: URL { root.appendingPathComponent("failure.json") }
    var logsDirectory: URL { root.appendingPathComponent("logs") }
    var runLog: URL { logsDirectory.appendingPathComponent("run.log") }
    var installLog: URL { logsDirectory.appendingPathComponent("install.log") }
    var stateLog: URL { logsDirectory.appendingPathComponent("state.jsonl") }
    var diagnosticsDirectory: URL { logsDirectory.appendingPathComponent("diagnostics") }

    /// The marker the guest writes into the VirtioFS share. Written by the
    /// guest, read by the host: this is the whole point of the share.
    var sharedMarker: URL { sharedDirectory.appendingPathComponent("viv-result.txt") }

    init(root: URL, sharedDirectory: URL? = nil) {
        let root = root.standardizedFileURL
        self.root = root
        self.sharedDirectory = (sharedDirectory ?? root.appendingPathComponent("Shared"))
            .standardizedFileURL
    }

    /// The files that together constitute the VM's platform identity. They are
    /// cloned as a set, because a hardware model paired with someone else's
    /// auxiliary storage does not boot.
    static let platformIdentityFilenames = [
        "AuxiliaryStorage", "Disk.img", "HardwareModel", "MachineIdentifier", "MACAddress"
    ]
}

/// Paths inside a pristine post-restore template bundle.
struct TemplatePaths: Sendable {
    let root: URL

    var manifest: URL { root.appendingPathComponent("template.json") }

    init(root: URL) {
        self.root = root.standardizedFileURL
    }
}

/// Where Vivarium keeps everything it owns.
///
/// `~/.vivarium` follows the `~/.tart` precedent: a dot directory the user is
/// unlikely to browse, holding artefacts that are large, machine-generated, and
/// safe to delete. `VIVARIUM_HOME` exists so a run can be pointed at an
/// external volume — a single template plus one run is comfortably over 100 GB
/// of sparse image — without every command needing a path flag.
///
/// The POC's `~/VRE-POC` is deliberately *not* consulted or migrated. Nothing
/// in Vivarium reads or deletes it, so a POC bundle kept for reference stays
/// exactly where it was left.
enum VivariumHome {
    static let environmentVariable = "VIVARIUM_HOME"

    static var root: URL {
        if let override = ProcessInfo.processInfo.environment[environmentVariable],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                .standardizedFileURL
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".vivarium")
            .standardizedFileURL
    }

    static var templates: URL {
        root.appendingPathComponent("templates")
    }

    /// Refuses a `VIVARIUM_HOME` that cannot be the root of a tree Vivarium
    /// creates, fills, and deletes from.
    ///
    /// Three values are refused outright, because each turns an ordinary
    /// `viv gc` into something else entirely: a relative path makes the home
    /// depend on the working directory, so the same command means a different
    /// tree from a different shell; `/` makes `runs/` a top-level directory and
    /// puts the whole filesystem one typo away; and `$HOME` itself makes the
    /// home the user's own, where `runs/` is plausible enough to already exist
    /// as something else. The default `~/.vivarium` is none of these, so this
    /// only ever fires for an override.
    static func requireUsable(stage: VivStage) throws {
        guard let override = ProcessInfo.processInfo.environment[environmentVariable],
              !override.isEmpty else { return }

        func refuse(_ reason: String) -> VivError {
            VivError(
                stage,
                "\(environmentVariable) is set to \"\(override)\", which \(reason). "
                    + "Point it at a directory Vivarium can own, or unset it to use "
                    + "~/.vivarium.",
                inspectionHints: ["echo $\(environmentVariable)"]
            )
        }

        let expanded = (override as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw refuse("is a relative path — the home would follow the working directory")
        }
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard path != "/" else { throw refuse("is the filesystem root") }
        guard path != URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path else {
            throw refuse("is your home directory itself")
        }
    }

    /// Runs live one level below `runs/` rather than directly under the home,
    /// so that `viv gc` has a single subtree it may delete from and can never
    /// reach `templates/`, which is expensive to rebuild.
    static var runs: URL {
        root.appendingPathComponent("runs")
    }

    static func run(id: String) -> URL {
        runs.appendingPathComponent(id)
    }
}

/// The directory tree one run owns: `<home>/runs/<run-id>/`.
///
/// Three siblings rather than one nest, because they have three different
/// lifetimes. `VM.bundle` is tens of gigabytes and is deleted the moment a run
/// succeeds; `Shared/` is the channel the guest reads code from and writes
/// artifacts to, and is deleted with it; `results/` is small, is the only thing
/// anyone reads afterwards, and is always kept.
struct RunLayout: Sendable {
    let runID: String
    let root: URL

    init(runID: String, root: URL? = nil) {
        self.runID = runID
        self.root = (root ?? VivariumHome.run(id: runID)).standardizedFileURL
    }

    var bundleRoot: URL { root.appendingPathComponent("VM.bundle") }

    /// The VirtioFS share, which the guest sees at
    /// `AcceptanceScript.expectedSharePath`.
    var shared: URL { root.appendingPathComponent("Shared") }
    /// The staged copy of the user's code. The original directory is never
    /// mounted into a guest and never written to.
    var sharedCode: URL { shared.appendingPathComponent("code") }
    /// The guest's `$VIV_ARTIFACTS`. Everything the guest leaves here, plus
    /// everything matched by the manifest's `artifacts` globs, is harvested.
    var sharedArtifacts: URL { shared.appendingPathComponent("artifacts") }

    var results: URL { root.appendingPathComponent("results") }
    var resultsArtifacts: URL { results.appendingPathComponent("artifacts") }
    var reportJSON: URL { results.appendingPathComponent("report.json") }
    var reportMarkdown: URL { results.appendingPathComponent("report.md") }
    var testStdout: URL { results.appendingPathComponent("test-stdout.txt") }
    var testStderr: URL { results.appendingPathComponent("test-stderr.txt") }
    var failureReport: URL { results.appendingPathComponent("failure.json") }

    var paths: VMBundlePaths {
        VMBundlePaths(root: bundleRoot, sharedDirectory: shared)
    }
}

enum DefaultLocations {
    static var templates: URL { VivariumHome.templates }

    static func template(ipswBuild: String) -> URL {
        templates.appendingPathComponent("\(ipswBuild).bundle")
    }
}
