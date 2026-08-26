import Foundation
import Testing

@testable import Vivarium

/// A Vivarium home for the whole test process.
///
/// `VIVARIUM_HOME` is read from the environment on every call and the
/// environment is process-wide, so the suites that need a home share one
/// rather than each installing its own while the others are running.
let testVivariumHome: URL = {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("viv-home-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    setenv(VivariumHome.environmentVariable, url.path, 1)
    return url
}()

/// One test's own `runs/`, inside the shared home so `viv gc` will act on it.
private func makeRunsRoot() throws -> URL {
    let root = testVivariumHome
        .appendingPathComponent("case-\(UUID().uuidString)")
        .appendingPathComponent("runs")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A run directory, with whichever of its three parts the case needs.
@discardableResult
private func makeRun(
    _ runID: String,
    in runsRoot: URL,
    bundle: Bool = false,
    shared: Bool = false,
    report: TestRunFixture? = nil,
    failureReport: Bool = false
) throws -> URL {
    let manager = FileManager.default
    let layout = RunLayout(runID: runID, root: runsRoot.appendingPathComponent(runID))
    try manager.createDirectory(at: layout.root, withIntermediateDirectories: true)
    if bundle {
        try manager.createDirectory(at: layout.bundleRoot, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: layout.bundleRoot.appendingPathComponent("Disk.img"))
    }
    if shared {
        try manager.createDirectory(at: layout.sharedCode, withIntermediateDirectories: true)
        try Data("code".utf8).write(to: layout.sharedCode.appendingPathComponent("main.swift"))
    }
    if report != nil || failureReport {
        try manager.createDirectory(at: layout.results, withIntermediateDirectories: true)
    }
    if let report {
        try Data(report.json.utf8).write(to: layout.reportJSON)
    }
    if failureReport {
        try Data(#"{ "stage": "sshReadiness", "message": "no answer" }"#.utf8)
            .write(to: layout.failureReport)
    }
    return layout.root
}

/// A `results/report.json` in the shape `viv run` writes one.
///
/// Spelled as JSON rather than built from `TestRunReport` because that is what
/// `viv gc` actually meets on disk: reports written by older versions, which it
/// is required to keep decoding.
struct TestRunFixture {
    var status: String = "passed"
    var finishedAt: String = "2026-08-10T14:35:11Z"
    var keptForInspection: Bool = false

    var json: String {
        """
        {
          "runID": "fixture",
          "vivariumVersion": "0.1.0",
          "status": "\(status)",
          "startedAt": "2026-08-10T14:30:00Z",
          "finishedAt": "\(finishedAt)",
          "codeDirectory": "/tmp/project",
          "command": "swift test",
          "commandSource": "viv.json",
          "templatePath": "/tmp/templates/macos-26A5388g.bundle",
          "guestUsername": "viv",
          "guestWorkdir": "/Users/viv/work",
          "timeoutSeconds": 600,
          "timedOut": false,
          "phases": [],
          "totalSeconds": 120,
          "artifacts": [],
          "artifactByteCount": 0,
          "harvestWarnings": [],
          "resultsPath": "/tmp/results",
          "deletedPaths": [],
          "keptForInspection": \(keptForInspection)
        }
        """
    }
}

private func action(_ plan: RunGC.Plan, _ runID: String) throws -> RunGC.Action {
    try #require(plan.actions.first { $0.runID == runID })
}

/// Serialized because these tests and the ones below share `VIVARIUM_HOME`,
/// which is process-wide state.
@Suite("viv gc", .serialized)
struct RunGarbageCollectionTests {
    @Test("a finished run gives up its bundle and its share, and keeps its results")
    func reclaimsHeavyRemains() async throws {
        let runs = try makeRunsRoot()
        let root = try makeRun("done", in: runs, bundle: true, shared: true, report: TestRunFixture())

        let plan = try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs)
        let entry = try action(plan, "done")
        #expect(entry.isSkip == false)
        #expect(Set(entry.targets.map(\.lastPathComponent)) == ["VM.bundle", "Shared"])

        try RunGC.execute(plan)
        let layout = RunLayout(runID: "done", root: root)
        #expect(FileManager.default.fileExists(atPath: layout.bundleRoot.path) == false)
        #expect(FileManager.default.fileExists(atPath: layout.shared.path) == false)
        #expect(FileManager.default.fileExists(atPath: layout.reportJSON.path))
    }

    @Test("a run that left no report might still be running, and is left alone")
    func skipsReportlessRun() async throws {
        let runs = try makeRunsRoot()
        try makeRun("live", in: runs, bundle: true, shared: true)

        let plan = try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs)
        let entry = try action(plan, "live")
        #expect(entry.isSkip)
        #expect(entry.targets.isEmpty)
        #expect(entry.label.contains("possibly still running"))
    }

    @Test("a run that failed before it could report is finished, and is reclaimed")
    func reclaimsInfrastructureFailure() async throws {
        let runs = try makeRunsRoot()
        try makeRun("broken", in: runs, bundle: true, shared: true, failureReport: true)

        let plan = try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs)
        let entry = try action(plan, "broken")
        #expect(entry.isSkip == false)
        #expect(entry.label == "infrastructure failure")
    }

    @Test("a share left behind by a half-finished cleanup is still reclaimed")
    func reclaimsOrphanedShare() async throws {
        // Gating on the bundle would leave a Shared/ full of staged code
        // classified forever as "nothing to reclaim".
        let runs = try makeRunsRoot()
        try makeRun("half", in: runs, bundle: false, shared: true, report: TestRunFixture())

        let entry = try action(
            try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs), "half"
        )
        #expect(entry.isSkip == false)
        #expect(entry.targets.map(\.lastPathComponent) == ["Shared"])
    }

    @Test("a run already reduced to its results has nothing left to give")
    func skipsResultsOnlyRun() async throws {
        let runs = try makeRunsRoot()
        try makeRun("reclaimed", in: runs, report: TestRunFixture())

        let entry = try action(
            try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs), "reclaimed"
        )
        #expect(entry.isSkip)
        #expect(entry.label.contains("nothing to reclaim"))
    }

    @Test("default mode never targets a results directory")
    func neverTargetsResults() async throws {
        let runs = try makeRunsRoot()
        try makeRun("a", in: runs, bundle: true, shared: true, report: TestRunFixture())
        try makeRun("b", in: runs, bundle: true, report: TestRunFixture(status: "failed"))

        let plan = try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs)
        let targets = plan.actions.flatMap(\.targets).map(\.lastPathComponent)
        #expect(targets.allSatisfy { $0 == "VM.bundle" || $0 == "Shared" })
    }

    @Test("--all takes the whole run directory, results included")
    func allTakesEverything() async throws {
        let runs = try makeRunsRoot()
        let root = try makeRun("done", in: runs, bundle: true, shared: true, report: TestRunFixture())

        let plan = try await RunGC.plan(selection: .all, in: runs)
        let entry = try action(plan, "done")
        #expect(entry.isSkip == false)
        // The whole run directory, rather than the two heavy parts of it.
        #expect(entry.targets.count == 1)
        #expect(entry.targets.first?.lastPathComponent == "done")

        try RunGC.execute(plan)
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    @Test("--all takes a run that never reported, too")
    func allTakesReportlessRun() async throws {
        let runs = try makeRunsRoot()
        try makeRun("live", in: runs, bundle: true)
        let entry = try action(try await RunGC.plan(selection: .all, in: runs), "live")
        #expect(entry.isSkip == false)
    }

    @Test("a run is old enough by the date it finished, not the date it was made")
    func agesByFinishedAt() async throws {
        let runs = try makeRunsRoot()
        try makeRun(
            "ancient", in: runs, bundle: true,
            report: TestRunFixture(finishedAt: "2026-01-01T00:00:00Z")
        )
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-10T00:00:00Z"))

        let entry = try action(
            try await RunGC.plan(selection: .olderThan(days: 30), in: runs, now: now), "ancient"
        )
        #expect(entry.isSkip == false)
        #expect(entry.label.contains("whole directory"))
    }

    @Test("a run too young for --older-than falls back to reclaiming its remains")
    func youngRunKeepsItsResults() async throws {
        let runs = try makeRunsRoot()
        let root = try makeRun(
            "recent", in: runs, bundle: true, shared: true,
            report: TestRunFixture(finishedAt: "2026-08-09T00:00:00Z")
        )
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-10T00:00:00Z"))

        let entry = try action(
            try await RunGC.plan(selection: .olderThan(days: 30), in: runs, now: now), "recent"
        )
        #expect(entry.targets.contains(root) == false)
        #expect(Set(entry.targets.map(\.lastPathComponent)) == ["VM.bundle", "Shared"])
    }

    @Test("a passing run kept with --keep-vm still says so in the listing")
    func labelsKeptRun() async throws {
        let runs = try makeRunsRoot()
        try makeRun(
            "kept", in: runs, bundle: true,
            report: TestRunFixture(keptForInspection: true)
        )
        let entry = try action(
            try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs), "kept"
        )
        #expect(entry.label == "passed, kept (--keep-vm)")
    }

    @Test("a run's verdict names the line it is listed under", arguments: [
        ("passed", "passed"), ("failed", "failed"), ("timedOut", "timed out"),
    ])
    func labelsVerdict(_ verdict: (status: String, label: String)) async throws {
        let runs = try makeRunsRoot()
        try makeRun(
            "run", in: runs, bundle: true, report: TestRunFixture(status: verdict.status)
        )
        let entry = try action(
            try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs), "run"
        )
        #expect(entry.label == verdict.label)
    }

    @Test("a report gc cannot decode still counts as a finished run")
    func toleratesForeignReport() async throws {
        // `viv selftest` writes its own acceptance report to the same name.
        // Asking the decoder whether a run finished would leave every selftest
        // classified forever as possibly still running.
        let runs = try makeRunsRoot()
        let root = try makeRun("selftest", in: runs, bundle: true)
        let layout = RunLayout(runID: "selftest", root: root)
        try FileManager.default.createDirectory(at: layout.results, withIntermediateDirectories: true)
        try Data(#"{ "criteria": [], "passed": true }"#.utf8).write(to: layout.reportJSON)

        let entry = try action(
            try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs), "selftest"
        )
        #expect(entry.isSkip == false)
        #expect(entry.label == "finished")
    }

    @Test("an empty run directory is described as empty, not as still running")
    func labelsEmptyRun() async throws {
        let runs = try makeRunsRoot()
        try makeRun("empty", in: runs)
        let entry = try action(
            try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs), "empty"
        )
        #expect(entry.isSkip)
        #expect(entry.label == "empty, skipped")
    }

    @Test("a plan against a runs directory that is not there is empty, not an error")
    func toleratesMissingRunsDirectory() async throws {
        let runs = testVivariumHome
            .appendingPathComponent("case-\(UUID().uuidString)")
            .appendingPathComponent("runs")
        let plan = try await RunGC.plan(selection: .all, in: runs)
        #expect(plan.actions.isEmpty)
    }

    @Test("the reclaimable total counts only what would actually be deleted")
    func totalsOnlyRealTargets() async throws {
        let runs = try makeRunsRoot()
        try makeRun("done", in: runs, bundle: true, report: TestRunFixture())
        try makeRun("live", in: runs, bundle: true)

        let plan = try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs)
        let reclaimed = plan.actions.filter { !$0.isSkip }.reduce(Int64(0)) { $0 + $1.byteCount }
        #expect(plan.reclaimableBytes == reclaimed)
        #expect(plan.reclaimableBytes > 0)
    }

    @Test("a dry run leaves everything exactly where it was")
    func planDeletesNothing() async throws {
        let runs = try makeRunsRoot()
        let root = try makeRun("done", in: runs, bundle: true, shared: true, report: TestRunFixture())

        _ = try await RunGC.plan(selection: .all, in: runs)

        let layout = RunLayout(runID: "done", root: root)
        #expect(FileManager.default.fileExists(atPath: layout.bundleRoot.path))
        #expect(FileManager.default.fileExists(atPath: layout.shared.path))
    }

    // MARK: - Refusals

    @Test("a symlinked entry is never followed in default mode")
    func neverFollowsSymlinkByDefault() async throws {
        let runs = try makeRunsRoot()
        let (link, target) = try makeSymlinkedEntry(in: runs)

        let entry = try action(
            try await RunGC.plan(selection: .heavyRemainsOfFinishedRuns, in: runs), "linked"
        )
        #expect(entry.isSkip)
        #expect(entry.label.contains("not followed"))
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("--all deletes a symlinked entry as the link, leaving its target alone")
    func deletesSymlinkNotTarget() async throws {
        // This is the whole safety model: an entry under runs/ that points
        // somewhere else must cost the link, never the tree it names.
        let runs = try makeRunsRoot()
        let (link, target) = try makeSymlinkedEntry(in: runs)

        let plan = try await RunGC.plan(selection: .all, in: runs)
        let entry = try action(plan, "linked")
        #expect(entry.label == "symlink")
        try RunGC.execute(plan)

        var info = stat()
        #expect(lstat(link.path, &info) == -1)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
    }

    @Test("a runs directory resolving outside the home is refused")
    func refusesRunsRootOutsideHome() async throws {
        let outside = try temporaryDirectory("viv-not-the-home")
        defer { try? FileManager.default.removeItem(at: outside) }
        let runs = outside.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)

        let error = await #expect(throws: VivError.self) {
            try await RunGC.plan(selection: .all, in: runs)
        }
        #expect(try #require(error).message.contains("outside the Vivarium home"))
    }

    @Test("a runs directory symlinked out of the home is refused")
    func refusesSymlinkedRunsRoot() async throws {
        // The attack this defends against: runs/ replaced with a link to a
        // tree Vivarium does not own, so an ordinary gc deletes someone else's
        // files.
        let outside = try temporaryDirectory("viv-elsewhere")
        defer { try? FileManager.default.removeItem(at: outside) }

        let home = testVivariumHome.appendingPathComponent("case-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let runs = home.appendingPathComponent("runs")
        try FileManager.default.createSymbolicLink(atPath: runs.path, withDestinationPath: outside.path)

        await #expect(throws: VivError.self) {
            try await RunGC.plan(selection: .all, in: runs)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("a VIVARIUM_HOME Vivarium cannot own is refused", arguments: [
        ("relative/path", "relative path"),
        ("/", "filesystem root"),
    ])
    func refusesUnusableHome(_ override: (value: String, reason: String)) throws {
        try withVivariumHome(override.value) {
            let error = #expect(throws: VivError.self) {
                try VivariumHome.requireUsable(stage: .cleanup)
            }
            #expect(error?.message.contains(override.reason) == true)
        }
    }

    @Test("VIVARIUM_HOME set to the home directory itself is refused")
    func refusesHomeDirectoryItself() throws {
        // `runs/` under $HOME is plausible enough to already exist as
        // something else entirely.
        try withVivariumHome(NSHomeDirectory()) {
            let error = #expect(throws: VivError.self) {
                try VivariumHome.requireUsable(stage: .cleanup)
            }
            #expect(error?.message.contains("home directory itself") == true)
        }
    }

    @Test("the default home needs no override to be usable")
    func acceptsDefaultHome() throws {
        try withVivariumHome(nil) {
            #expect(throws: Never.self) { try VivariumHome.requireUsable(stage: .cleanup) }
            #expect(VivariumHome.root.lastPathComponent == ".vivarium")
        }
    }

    @Test("runs and templates are siblings, so gc can never reach a template")
    func runsAndTemplatesAreSiblings() {
        #expect(VivariumHome.runs.lastPathComponent == "runs")
        #expect(VivariumHome.templates.lastPathComponent == "templates")
        #expect(
            VivariumHome.runs.deletingLastPathComponent().path
                == VivariumHome.templates.deletingLastPathComponent().path
        )
    }

    /// A symlinked entry under `runs/`, plus the directory it points at.
    private func makeSymlinkedEntry(in runs: URL) throws -> (link: URL, target: URL) {
        let target = testVivariumHome.appendingPathComponent("target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))

        let link = runs.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        return (link, target)
    }

    /// Runs `body` with `VIVARIUM_HOME` set to `value`, then puts it back.
    ///
    /// The environment is process-wide, which is why both suites that touch it
    /// are serialized.
    private func withVivariumHome(_ value: String?, _ body: () throws -> Void) throws {
        let previous = ProcessInfo.processInfo.environment[VivariumHome.environmentVariable]
        defer {
            if let previous {
                setenv(VivariumHome.environmentVariable, previous, 1)
            } else {
                unsetenv(VivariumHome.environmentVariable)
            }
        }
        if let value {
            setenv(VivariumHome.environmentVariable, value, 1)
        } else {
            unsetenv(VivariumHome.environmentVariable)
        }
        try body()
    }
}
