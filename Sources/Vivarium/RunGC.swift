import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `viv gc`: deletes run directories, and only run directories, under
/// `<home>/runs`.
///
/// This command is different from every other one in Vivarium: its entire
/// job is destructive, so a classification mistake here loses data instead
/// of merely failing a run. Every rule follows from that:
///
/// - Default mode never deletes a `results/` directory. It only reclaims the
///   heavy remains — `VM.bundle` and `Shared/` — of runs that are *finished*
///   (have a `results/report.json` or a `results/failure.json`). A run
///   directory with a `VM.bundle` and neither file is possibly still live —
///   default mode leaves it alone.
/// - `--older-than <days>` widens default mode to also remove whole run
///   directories, `results/` included, once they are old enough by
///   `finishedAt` (or the directory's own modification date, when there is
///   no report to read).
/// - `--all` deletes every run directory outright: kept-for-inspection,
///   reportless, all of it.
/// - A symlinked entry under `runs/` is always deleted as the link it is,
///   never followed into whatever it points at — default mode does not even
///   inspect it, because inspecting a real run directory's contents means
///   composing paths that walk straight through a symlinked one.
enum RunGC {
    /// What `viv gc`'s flags select.
    enum Selection: Sendable {
        case heavyRemainsOfFinishedRuns
        case olderThan(days: Int)
        case all
    }

    /// One decision made about one entry directly under `runs/`.
    struct Action: Sendable {
        let runID: String
        let root: URL
        /// What would be (or was) deleted for this entry. Empty when skipped.
        let targets: [URL]
        let label: String
        let ageDescription: String
        /// On-disk bytes occupied by `targets`, measured before deletion.
        let byteCount: Int64
        let isSkip: Bool
    }

    struct Plan: Sendable {
        let actions: [Action]
        var reclaimableBytes: Int64 { actions.filter { !$0.isSkip }.reduce(0) { $0 + $1.byteCount } }
    }

    /// Builds the plan without deleting anything, so `--dry-run` and the real
    /// run share one code path and can never disagree about what qualifies.
    static func plan(selection: Selection, in runsRoot: URL = VivariumHome.runs, now: Date = Date()) async throws -> Plan {
        try requireContained(runsRoot)
        guard FileManager.default.fileExists(atPath: runsRoot.path) else {
            return Plan(actions: [])
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runsRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw VivError(
                .cleanup,
                "Cannot list \(runsRoot.path).",
                inspectionHints: ["ls -la \(runsRoot.path)"]
            )
        }

        var actions: [Action] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            actions.append(await classify(entry: entry, selection: selection, now: now))
        }
        return Plan(actions: actions)
    }

    /// Deletes what `plan` decided to delete.
    static func execute(_ plan: Plan) throws {
        for action in plan.actions where !action.isSkip {
            for target in action.targets {
                try RunStorage.remove(target)
            }
        }
    }

    // MARK: - Classification

    private static func classify(entry: URL, selection: Selection, now: Date) async -> Action {
        let runID = entry.lastPathComponent
        let isSymlink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false

        if isSymlink {
            return await classifySymlink(entry: entry, runID: runID, selection: selection, now: now)
        }

        let layout = RunLayout(runID: runID, root: entry)
        let hasBundle = FileManager.default.fileExists(atPath: layout.bundleRoot.path)
        let report = try? JSONCoding.read(TestRunReport.self, from: layout.reportJSON, stage: .cleanup)
        let hasFailureReport = FileManager.default.fileExists(atPath: layout.failureReport.path)
        let referenceDate = report?.finishedAt ?? modificationDate(of: entry) ?? now
        let ageDescription = age(from: referenceDate, to: now)
        let label = label(report: report, hasFailureReport: hasFailureReport, hasBundle: hasBundle)

        switch selection {
        case .all:
            let bytes = await RunStorage.onDiskByteCount(of: entry) ?? 0
            return Action(
                runID: runID, root: entry, targets: [entry], label: label,
                ageDescription: ageDescription, byteCount: bytes, isSkip: false
            )

        case .olderThan(let days):
            guard isOlder(than: days, referenceDate: referenceDate, now: now) else {
                return await defaultAction(
                    runID: runID, entry: entry, layout: layout, label: label,
                    hasFailureReport: hasFailureReport, hasBundle: hasBundle,
                    finished: report != nil || hasFailureReport, ageDescription: ageDescription
                )
            }
            let bytes = await RunStorage.onDiskByteCount(of: entry) ?? 0
            return Action(
                runID: runID, root: entry, targets: [entry], label: "\(label), whole directory (older than \(days)d)",
                ageDescription: ageDescription, byteCount: bytes, isSkip: false
            )

        case .heavyRemainsOfFinishedRuns:
            return await defaultAction(
                runID: runID, entry: entry, layout: layout, label: label,
                hasFailureReport: hasFailureReport, hasBundle: hasBundle,
                finished: report != nil || hasFailureReport, ageDescription: ageDescription
            )
        }
    }

    /// Default-mode selection: heavy remains of a finished run only.
    private static func defaultAction(
        runID: String, entry: URL, layout: RunLayout, label: String,
        hasFailureReport: Bool, hasBundle: Bool, finished: Bool, ageDescription: String
    ) async -> Action {
        guard finished else {
            return Action(
                runID: runID, root: entry, targets: [],
                label: hasBundle ? "no report — possibly still running, skipped" : "empty, skipped",
                ageDescription: ageDescription, byteCount: 0, isSkip: true
            )
        }
        guard hasBundle else {
            return Action(
                runID: runID, root: entry, targets: [],
                label: "\(label), results only — nothing to reclaim",
                ageDescription: ageDescription, byteCount: 0, isSkip: true
            )
        }

        var targets = [layout.bundleRoot]
        if FileManager.default.fileExists(atPath: layout.shared.path) {
            targets.append(layout.shared)
        }
        var bytes: Int64 = 0
        for target in targets {
            bytes += await RunStorage.onDiskByteCount(of: target) ?? 0
        }
        return Action(
            runID: runID, root: entry, targets: targets, label: label,
            ageDescription: ageDescription, byteCount: bytes, isSkip: false
        )
    }

    /// A symlinked entry directly under `runs/` is never inspected or
    /// descended into — only ever deleted, as the link, or left alone.
    private static func classifySymlink(
        entry: URL, runID: String, selection: Selection, now: Date
    ) async -> Action {
        let referenceDate = linkModificationDate(of: entry) ?? now
        let ageDescription = age(from: referenceDate, to: now)
        let bytes = await RunStorage.onDiskByteCount(of: entry) ?? 0

        switch selection {
        case .all:
            return Action(
                runID: runID, root: entry, targets: [entry], label: "symlink",
                ageDescription: ageDescription, byteCount: bytes, isSkip: false
            )
        case .olderThan(let days):
            guard isOlder(than: days, referenceDate: referenceDate, now: now) else {
                return Action(
                    runID: runID, root: entry, targets: [],
                    label: "symlink, not followed — skipped", ageDescription: ageDescription,
                    byteCount: 0, isSkip: true
                )
            }
            return Action(
                runID: runID, root: entry, targets: [entry],
                label: "symlink, older than \(days)d", ageDescription: ageDescription,
                byteCount: bytes, isSkip: false
            )
        case .heavyRemainsOfFinishedRuns:
            return Action(
                runID: runID, root: entry, targets: [],
                label: "symlink, not followed — skipped", ageDescription: ageDescription,
                byteCount: 0, isSkip: true
            )
        }
    }

    private static func label(report: TestRunReport?, hasFailureReport: Bool, hasBundle: Bool) -> String {
        if let report {
            switch report.status {
            case .passed: return report.keptForInspection ? "passed, kept (--keep-vm)" : "passed"
            case .failed: return "failed"
            case .timedOut: return "timed out"
            }
        }
        if hasFailureReport { return "infrastructure failure" }
        return hasBundle ? "no report" : "empty"
    }

    // MARK: - Safety

    /// Refuses to proceed if `runsRoot` resolves outside the Vivarium home —
    /// paranoia against a hostile or mistaken `VIVARIUM_HOME` pointing `runs/`
    /// (via a symlink somewhere in the chain) at something Vivarium does not
    /// own, such as `~/VRE-POC` or the filesystem root.
    private static func requireContained(_ runsRoot: URL) throws {
        guard FileManager.default.fileExists(atPath: runsRoot.path) else { return }

        let resolvedRoot = VivariumHome.root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRuns = runsRoot.resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolvedRuns.path.hasPrefix(prefix) else {
            throw VivError(
                .cleanup,
                "\(runsRoot.path) resolves to \(resolvedRuns.path), which is outside the Vivarium "
                    + "home at \(resolvedRoot.path). Refusing to run viv gc against it.",
                inspectionHints: ["echo $VIVARIUM_HOME", "ls -la \(runsRoot.path)"]
            )
        }
    }

    // MARK: - Dates and formatting

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The link's own modification time, via `lstat`, so a symlink is dated
    /// by itself rather than by whatever it points at.
    private static func linkModificationDate(of url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isOlder(than days: Int, referenceDate: Date, now: Date) -> Bool {
        referenceDate.distance(to: now) >= Double(days) * 86400
    }

    /// A coarse age for the per-run line: seconds, minutes, hours, or days —
    /// whichever reads best at that magnitude.
    private static func age(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}
