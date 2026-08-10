import Foundation

/// Every path inside one run's VM bundle.
///
/// This replaces the Apple sample's file-scope globals (`vmBundlePath`,
/// `diskImageURL`, and friends), which hardcode `~/VM.bundle` and therefore
/// make two concurrent runs, or a failed run kept for inspection, impossible.
struct VMBundlePaths: Sendable {
    let root: URL

    var auxiliaryStorage: URL { root.appendingPathComponent("AuxiliaryStorage") }
    var systemDisk: URL { root.appendingPathComponent("Disk.img") }
    var hardwareModel: URL { root.appendingPathComponent("HardwareModel") }
    var machineIdentifier: URL { root.appendingPathComponent("MachineIdentifier") }
    var macAddress: URL { root.appendingPathComponent("MACAddress") }
    var artifactDisk: URL { root.appendingPathComponent("Artifact.raw") }
    var sharedDirectory: URL { root.appendingPathComponent("Shared") }
    var sharedInput: URL { sharedDirectory.appendingPathComponent("input") }
    var sharedOutput: URL { sharedDirectory.appendingPathComponent("output") }
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
    var sharedMarker: URL { sharedDirectory.appendingPathComponent("vre-result.txt") }

    init(root: URL) {
        self.root = root.standardizedFileURL
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

enum DefaultLocations {
    static var poc: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("VRE-POC")
    }

    static var templates: URL {
        poc.appendingPathComponent("templates")
    }

    static func runBundle(runID: String) -> URL {
        poc.appendingPathComponent(runID).appendingPathComponent("VM.bundle")
    }

    static func template(ipswBuild: String) -> URL {
        templates.appendingPathComponent("\(ipswBuild).bundle")
    }
}
