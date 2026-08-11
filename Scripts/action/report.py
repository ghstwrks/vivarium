#!/usr/bin/env python3
"""Turns a run's results into step outputs and a job summary.

Written in Python rather than in shell because the source is JSON, and the one
thing shell cannot do without a dependency is read JSON. Python 3 ships with
macOS; jq does not.

Nothing here is allowed to fail the job. A run that produced a verdict has
already produced it, and a summary that could not be written is not a reason to
throw that verdict away — the verdict step downstream reads viv's exit code, not
this. Anything unexpected becomes a warning annotation and empty outputs.
"""

import json
import os
import sys

# GitHub truncates a step summary over 1 MiB and says so as a job-level error.
# The margin is for the sections appended after the report itself.
SUMMARY_LIMIT = 900_000
# Enough of a stream to recognise the failure, not enough to bury the report
# under a test suite's entire output. The uploaded artifact has all of it.
TAIL_BYTES = 12_000


def warn(message):
    print("::warning title=Vivarium::%s" % message)


def set_output(name, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        # The heredoc form, because report-json is a path but status came from
        # a file this script did not write, and a value with a newline in it
        # would otherwise be able to forge an output of its own.
        marker = "ghadelim_%s" % name
        handle.write("%s<<%s\n%s\n%s\n" % (name, marker, value, marker))


def read_text(path, limit=None):
    try:
        with open(path, "rb") as handle:
            if limit is not None:
                handle.seek(0, os.SEEK_END)
                size = handle.tell()
                handle.seek(max(0, size - limit))
                data = handle.read()
                if size > limit:
                    data = b"[... earlier output omitted; the uploaded artifact has all of it ...]\n" + data
            else:
                data = handle.read()
    except OSError:
        return None
    return data.decode("utf-8", "replace")


def append_summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text)
            if not text.endswith("\n"):
                handle.write("\n")
    except OSError as error:
        warn("Could not write the job summary: %s" % error)


def details(title, body, language=""):
    """A collapsed block, so a passing job's summary stays one screen long."""
    return "\n<details><summary>%s</summary>\n\n```%s\n%s\n```\n\n</details>\n" % (
        title,
        language,
        body.rstrip("\n"),
    )


def main():
    results = os.environ.get("RESULTS_PATH", "")
    exit_code = os.environ.get("EXIT_CODE", "")
    write_summary = os.environ.get("WRITE_SUMMARY", "true") == "true"

    report_path = os.path.join(results, "report.json") if results else ""
    failure_path = os.path.join(results, "failure.json") if results else ""

    report = None
    if report_path and os.path.isfile(report_path):
        try:
            with open(report_path, encoding="utf-8") as handle:
                report = json.load(handle)
        except (OSError, ValueError) as error:
            warn("Could not read %s: %s" % (report_path, error))

    if report is not None:
        status = report.get("status", "")
        set_output("status", status)
        set_output("passed", "true" if status == "passed" else "false")
        # Absent, not zero, when the command never exited: a timeout and an
        # exit 0 are not the same fact, and an output of "0" for both would
        # make them one.
        test_exit = report.get("testExitCode")
        set_output("test-exit-code", "" if test_exit is None else str(test_exit))
        set_output("report-json", report_path)
        total = report.get("totalSeconds")
        set_output("total-seconds", "" if total is None else ("%.1f" % total))
        set_output("artifact-count", str(len(report.get("artifacts") or [])))
    else:
        # No report means the run never reached a verdict — Vivarium failed, or
        # it failed before it had a directory to fail in. "error" is a status
        # the report itself can never carry, which is what makes it useful
        # here: a workflow branching on `status` can tell the two apart.
        set_output("status", "error")
        set_output("passed", "false")
        set_output("test-exit-code", "")
        set_output("report-json", "")
        set_output("total-seconds", "")
        set_output("artifact-count", "0")
        status = "error"

    if not write_summary:
        return

    parts = []
    markdown = read_text(os.path.join(results, "report.md")) if results else None
    if markdown:
        if len(markdown) > SUMMARY_LIMIT:
            markdown = markdown[:SUMMARY_LIMIT] + "\n\n[... report truncated for the job summary ...]\n"
        parts.append(markdown)
    else:
        parts.append("# Vivarium\n\nThe run produced no report. `viv` exited %s.\n" % (exit_code or "?"))

    failure = None
    if failure_path and os.path.isfile(failure_path):
        try:
            with open(failure_path, encoding="utf-8") as handle:
                failure = json.load(handle)
        except (OSError, ValueError) as error:
            warn("Could not read %s: %s" % (failure_path, error))

    if failure is not None:
        lines = [
            "\n## Vivarium failed\n",
            "The tests did not run. This is a fault in the host, the template, or the guest,",
            "not a verdict on the project.\n",
            "| | |", "|---|---|",
            "| stage | %s |" % failure.get("stage", ""),
            "| message | %s |" % str(failure.get("message", "")).replace("|", "\\|").replace("\n", " "),
        ]
        for label, key in (("underlying", "underlyingDescription"),
                           ("VM state", "vmState"),
                           ("last gate", "lastReadinessGate")):
            value = failure.get(key)
            if value:
                lines.append("| %s | %s |" % (label, str(value).replace("|", "\\|").replace("\n", " ")))
        hints = failure.get("inspectionHints") or []
        if hints:
            lines.append("")
            lines.append("Worth inspecting:")
            lines.append("")
            for hint in hints:
                lines.append("- `%s`" % hint)
        parts.append("\n".join(lines) + "\n")

    # The streams only when something went wrong: on a pass they are noise, and
    # the artifact has them either way.
    if status != "passed" and results:
        for name, title in (("test-stderr.txt", "test-stderr.txt (tail)"),
                            ("test-stdout.txt", "test-stdout.txt (tail)")):
            text = read_text(os.path.join(results, name), TAIL_BYTES)
            if text and text.strip():
                parts.append(details(title, text))

    append_summary("".join(parts))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 - see the module docstring
        warn("The report step did not finish: %r" % (error,))
        sys.exit(0)
