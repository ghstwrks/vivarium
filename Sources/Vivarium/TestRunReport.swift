import Foundation

/// Everything `viv run` needs, after the command line and the manifest have
/// been reconciled.
///
/// Resolved before anything is created so that a mistake — no command, no
/// template, an unreadable manifest — costs nothing but a message.
struct TestPlan: Sendable {
    /// The identifier the caller pinned with `--run-id`, or `nil` to generate
    /// one. Pinning it is what lets a caller know where the results will be
    /// before the run that writes them has started.
    let runID: String?
    let codeDirectory: URL
    let command: String
    /// Which of the two overriding sources the command came from, for the
    /// report.
    let commandSource: String
    let manifestPath: URL?
    let projectName: String?
    let artifactPatterns: [String]
    let environment: [String: String]
    /// The test command's budget. Bounds the command itself, not the boot, the
    /// staging, or the harvest.
    let timeout: Duration
    let templateRoot: URL
    /// Keep `VM.bundle` even when the run succeeds.
    let keepVM: Bool
}

/// How a run ended, from the operator's point of view.
enum TestRunStatus: String, Codable, Sendable {
    /// Everything worked and the test command exited zero.
    case passed
    /// Everything worked and the test command did not exit zero.
    case failed
    /// The test command was still running when its budget ran out.
    case timedOut
}

/// One phase's wall-clock cost.
///
/// Recorded as a list rather than a dictionary because the order is the
/// pipeline's order, and a report that shuffles its phases is harder to read
/// than one that does not.
struct PhaseTiming: Codable, Sendable {
    let name: String
    let seconds: Double
}

/// One state's wall-clock cost, in the order the run entered its states.
///
/// The state machine is finer-grained than `PhaseTiming`: a phase says "boot to
/// ssh took 17 seconds", a state says how much of that was spent waiting for an
/// address and how much waiting for sshd. Recorded so that a regression can be
/// located in an archived report rather than only noticed in one — which needs
/// the timings to survive the bundle, and `logs/state.jsonl` does not: it is
/// deleted with the bundle every time a run passes.
struct StateTiming: Codable, Sendable {
    /// A `VivState` raw value, kept as a string so that a report written by a
    /// different version of Vivarium — with a state this one does not know —
    /// still decodes.
    let state: String
    /// When the run entered this state, as an offset from the start of the run.
    let enteredAtSeconds: Double
    /// Wall-clock time in this state. The last state is closed at the moment
    /// the report is written, so it covers everything after the final
    /// transition.
    let seconds: Double
    let enteredAt: Date
}

/// A harvested file, as the host found it.
struct ArtifactEntry: Codable, Sendable {
    /// Relative to `results/artifacts/`, which mirrors the guest's workdir.
    let path: String
    let byteCount: Int64
}

/// `results/report.json`.
///
/// The schema is deliberately flat and self-describing: it exists to be read
/// by a person the day after, and by whatever CI step comes next, without
/// either needing Vivarium to interpret it.
struct TestRunReport: Codable, Sendable {
    let runID: String
    let vivariumVersion: String
    let status: TestRunStatus

    let startedAt: Date
    let finishedAt: Date

    let codeDirectory: String
    let manifestPath: String?
    let projectName: String?
    let command: String
    /// `"command line"` or `"viv.json"`: which of the two overriding sources
    /// the command came from.
    let commandSource: String

    let templatePath: String
    let templateBuild: String?
    let guestOS: GuestOS?
    let guestOSVersion: String?
    let guestUsername: String
    let guestAddress: String?
    let guestWorkdir: String

    let timeoutSeconds: Double
    let timedOut: Bool
    /// `nil` when the command never reached an exit — a timeout, or a
    /// connection that failed underneath it.
    let testExitCode: Int32?

    let phases: [PhaseTiming]
    /// Every state the run passed through, with the time it spent in each.
    ///
    /// Optional only for reports written before this field existed: `viv gc`
    /// decodes reports of any age, and a run archived by 0.1.0 must not stop
    /// decoding because a later version records more. Every report Vivarium
    /// writes now carries it.
    let states: [StateTiming]?
    let totalSeconds: Double

    let artifacts: [ArtifactEntry]
    let artifactByteCount: Int64
    /// Anything that went wrong while harvesting. Non-fatal by design: a
    /// pattern that matched nothing must not destroy a run's result.
    let harvestWarnings: [String]

    let resultsPath: String
    /// Paths deleted after a successful run.
    let deletedPaths: [String]
    /// Whether the whole run directory was kept for inspection.
    let keptForInspection: Bool

    var passed: Bool { status == .passed }

    // MARK: - Renderings

    /// The terminal summary.
    ///
    /// Two minutes of waiting earns a paragraph that answers, in order: did it
    /// pass, what ran, where did the time go, and where are the results.
    var summaryText: String {
        var lines: [String] = []
        lines.append("Vivarium run \(runID) — \(statusPhrase)")
        lines.append("")
        lines.append(contentsOf: Self.aligned([
            ("command", command),
            ("code", codeDirectory),
            ("template", templatePath),
            ("guest", guestDescription
                + (guestAddress.map { ", \(guestUsername)@\($0)" } ?? ", \(guestUsername)"))
        ]))
        lines.append("")
        lines.append(contentsOf: Self.alignedTimings(phases, total: totalSeconds))
        lines.append("")
        lines.append(contentsOf: Self.aligned([
            ("exit code", testExitCode.map(String.init) ?? "none — the command did not finish"),
            ("artifacts", artifactSummary),
            ("results", resultsPath)
        ]))
        if !harvestWarnings.isEmpty {
            lines.append("")
            for warning in harvestWarnings {
                lines.append("  harvest: \(warning)")
            }
        }
        lines.append("")
        lines.append("  " + dispositionSentence)
        return lines.joined(separator: "\n")
    }

    /// `results/report.md`, mirroring the terminal summary.
    var markdownText: String {
        var lines: [String] = []
        lines.append("# Vivarium run \(runID)")
        lines.append("")
        lines.append("**\(statusPhrase)** — \(finishedAt.formatted(.iso8601))")
        lines.append("")
        lines.append("| | |")
        lines.append("|---|---|")
        var rows: [(String, String)] = [
            ("command", "`\(command)`"),
            ("command from", commandSource),
            ("code", "`\(codeDirectory)`"),
            ("template", "`\(templatePath)`")
        ]
        rows.append(("guest os", guestDescription))
        if let templateBuild { rows.append(("guest build", templateBuild)) }
        if let projectName { rows.append(("project", projectName)) }
        if let manifestPath { rows.append(("manifest", "`\(manifestPath)`")) }
        rows.append(("guest", guestAddress.map { "`\(guestUsername)@\($0)`" } ?? guestUsername))
        rows.append(("workdir", "`\(guestWorkdir)`"))
        rows.append(("exit code", testExitCode.map(String.init) ?? "none — the command did not finish"))
        rows.append(("timeout", String(format: "%.0f s%@", timeoutSeconds, timedOut ? " (exceeded)" : "")))
        rows.append(("results", "`\(resultsPath)`"))
        for (name, value) in rows {
            lines.append("| \(name) | \(value) |")
        }

        lines.append("")
        lines.append("## Phases")
        lines.append("")
        lines.append("| phase | seconds |")
        lines.append("|---|--:|")
        for phase in phases {
            lines.append("| \(phase.name) | \(String(format: "%.1f", phase.seconds)) |")
        }
        lines.append("| **total** | **\(String(format: "%.1f", totalSeconds))** |")

        lines.append("")
        lines.append("## Artifacts")
        lines.append("")
        if artifacts.isEmpty {
            lines.append("None.")
        } else {
            lines.append("\(artifactSummary), under `\(resultsPath)/artifacts`.")
            lines.append("")
            lines.append("| file | bytes |")
            lines.append("|---|--:|")
            for artifact in artifacts {
                lines.append("| `\(artifact.path)` | \(artifact.byteCount) |")
            }
        }

        if !harvestWarnings.isEmpty {
            lines.append("")
            lines.append("## Harvest warnings")
            lines.append("")
            for warning in harvestWarnings {
                lines.append("- \(warning)")
            }
        }

        lines.append("")
        lines.append(dispositionSentence)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private var guestDescription: String {
        let name = (guestOS ?? .assumedForUnlabelledTemplates).displayName
        return guestOSVersion.map { "\(name) \($0)" } ?? name
    }

    private var statusPhrase: String {
        switch status {
        case .passed: return "passed"
        case .failed: return "failed (the test command exited \(testExitCode.map(String.init) ?? "abnormally"))"
        case .timedOut: return "timed out after \(String(format: "%.0f", timeoutSeconds)) s"
        }
    }

    private var artifactSummary: String {
        artifacts.isEmpty
            ? "none"
            : "\(artifacts.count) file\(artifacts.count == 1 ? "" : "s"), "
                + artifactByteCount.formattedByteCount
    }

    private var dispositionSentence: String {
        if !deletedPaths.isEmpty {
            return "Deleted \(deletedPaths.joined(separator: " and ")); results kept at \(resultsPath)."
        }
        if keptForInspection {
            return "Run kept for inspection at \(runDirectory); viv gc cleans it up later."
        }
        return "Results kept at \(resultsPath)."
    }

    private var runDirectory: String {
        URL(fileURLWithPath: resultsPath).deletingLastPathComponent().path
    }

    private static func aligned(_ rows: [(String, String)]) -> [String] {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { "  " + $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
    }

    /// Timings right-aligned on the decimal point, so the expensive phase is
    /// found by looking down the column rather than by reading every line.
    private static func alignedTimings(_ phases: [PhaseTiming], total: Double) -> [String] {
        let rows = phases.map { ($0.name, String(format: "%.1fs", $0.seconds)) }
            + [("total", String(format: "%.1fs", total))]
        let nameWidth = rows.map(\.0.count).max() ?? 0
        let valueWidth = rows.map(\.1.count).max() ?? 0
        return rows.map { name, value in
            "  " + name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                + "  " + String(repeating: " ", count: valueWidth - value.count) + value
        }
    }
}
