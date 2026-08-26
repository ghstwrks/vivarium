import Foundation
import Testing

@testable import Vivarium

@Suite("What a run owns")
struct RunLayoutTests {
    private let layout = RunLayout(runID: "run-1", root: URL(fileURLWithPath: "/tmp/runs/run-1"))

    @Test("the three parts of a run are siblings, because they have three lifetimes")
    func partsAreSiblings() {
        // VM.bundle goes the moment a run succeeds, Shared/ goes with it, and
        // results/ is the only part anyone reads afterwards.
        for part in [layout.bundleRoot, layout.shared, layout.results] {
            #expect(part.deletingLastPathComponent().path == layout.root.path)
        }
        #expect(layout.bundleRoot.lastPathComponent == "VM.bundle")
        #expect(layout.shared.lastPathComponent == "Shared")
        #expect(layout.results.lastPathComponent == "results")
    }

    @Test("the staged code and the artifacts live in the share, not the bundle")
    func shareHoldsCodeAndArtifacts() {
        #expect(layout.sharedCode.deletingLastPathComponent().path == layout.shared.path)
        #expect(layout.sharedArtifacts.deletingLastPathComponent().path == layout.shared.path)
    }

    @Test("everything anyone reads afterwards is under results")
    func resultsHoldTheReadableOutput() {
        for file in [
            layout.reportJSON, layout.reportMarkdown, layout.testStdout,
            layout.testStderr, layout.failureReport,
        ] {
            #expect(file.deletingLastPathComponent().path == layout.results.path)
        }
        #expect(layout.resultsArtifacts.deletingLastPathComponent().path == layout.results.path)
    }

    @Test("a run's bundle keeps its share outside itself, so cleanup is one removal")
    func bundleSharesTheRunsShare() {
        #expect(layout.paths.root.path == layout.bundleRoot.path)
        #expect(layout.paths.sharedDirectory.path == layout.shared.path)
    }

    @Test("a bundle named directly keeps its share inside itself")
    func standaloneBundleIsSelfContained() {
        // `--bundle` has no run directory around it, so the share has nowhere
        // else to go.
        let paths = VMBundlePaths(root: URL(fileURLWithPath: "/tmp/VM.bundle"))
        #expect(paths.sharedDirectory.path == "/tmp/VM.bundle/Shared")
    }

    @Test("the guest's marker is read back from the share")
    func markerIsInTheShare() {
        let paths = VMBundlePaths(root: URL(fileURLWithPath: "/tmp/VM.bundle"))
        #expect(paths.sharedMarker.deletingLastPathComponent().path == paths.sharedDirectory.path)
        #expect(paths.sharedMarker.lastPathComponent == GuestScripts.markerFilename)
    }

    @Test("every logged file is under the bundle's logs directory")
    func logsAreTogether() {
        let paths = layout.paths
        for file in [paths.runLog, paths.installLog, paths.consoleLog, paths.stateLog] {
            #expect(file.deletingLastPathComponent().path == paths.logsDirectory.path)
        }
        #expect(paths.diagnosticsDirectory.deletingLastPathComponent().path == paths.logsDirectory.path)
    }

    @Test("the guest's private key and its known-hosts file live in the bundle it belongs to")
    func credentialsAreInTheBundle() {
        // A Linux guest's key pair goes when the bundle does, which is only
        // true while it is inside it.
        let paths = layout.paths
        #expect(paths.sshPrivateKey.deletingLastPathComponent().path == paths.root.path)
        #expect(paths.knownHosts.deletingLastPathComponent().path == paths.root.path)
    }

    @Test("a path is standardized, so the same run never has two names")
    func standardizesPaths() {
        let awkward = RunLayout(runID: "run-1", root: URL(fileURLWithPath: "/tmp/runs/./x/../run-1"))
        #expect(awkward.root.path == "/tmp/runs/run-1")
    }

    @Test("a run directory sits one level below runs/, never directly in the home")
    func runsAreOneLevelDown() {
        // `viv gc` has exactly one subtree it may delete from, and it can
        // never reach templates/.
        let run = VivariumHome.run(id: "run-1")
        #expect(run.deletingLastPathComponent().lastPathComponent == "runs")
    }
}
