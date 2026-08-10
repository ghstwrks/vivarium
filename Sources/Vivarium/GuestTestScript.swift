import Foundation

/// The three scripts `viv run` asks the guest to execute.
///
/// They are three separate SSH sessions rather than one, because each has a
/// different budget and a different relationship to the user's output. Only
/// the middle one is the user's test: its stdout and stderr are the run's
/// stdout and stderr, its exit status is the run's verdict, and its `--timeout`
/// must not be spent copying a large repository or harvesting artifacts. The
/// workdir persists between sessions, so splitting them costs one SSH
/// handshake each and buys streams with nothing of Vivarium's mixed in.
enum GuestTestScript {
    /// Where the code is copied to before the test runs.
    ///
    /// Guest-local rather than the share itself: builds and test runners
    /// hardlink, mmap, chmod, and create sockets, and doing that on a VirtioFS
    /// mount is a well-known source of failures that have nothing to do with
    /// the code under test.
    static let workdirShellExpression = "$HOME/vivwork"

    /// The workdir as it reads in a report, where `$HOME` means nothing.
    static let workdirDisplayPath = "~/vivwork"

    /// The share subdirectory the guest writes artifacts into.
    static let artifactsGuestPath = AcceptanceScript.expectedSharePath + "/artifacts"

    /// The share subdirectory the staged code arrives in.
    static let codeGuestPath = AcceptanceScript.expectedSharePath + "/code"

    /// Variables Vivarium sets for the test command, and which a manifest's
    /// `env` therefore may not set.
    static let reservedEnvironmentNames: Set<String> = ["VIV_RUN_ID", "VIV_ARTIFACTS"]

    /// The here-document delimiter the artifact patterns are passed under.
    ///
    /// Quoted at the point of use, so the patterns undergo no expansion on
    /// their way into the guest; a pattern equal to this word is rejected when
    /// the manifest is read.
    static let artifactPatternDelimiter = "VIV_ARTIFACT_PATTERNS"

    /// Copies the staged code out of the share into the guest-local workdir.
    ///
    /// A pre-existing workdir is removed rather than merged: a guest is fresh
    /// every run today, and if that ever stops being true, a test that passes
    /// because of a file left by a previous run is the worst kind of failure.
    static var prepareScript: String {
        let share = ShellEscaping.singleQuoted(AcceptanceScript.expectedSharePath)
        let code = ShellEscaping.singleQuoted(codeGuestPath)
        let artifacts = ShellEscaping.singleQuoted(artifactsGuestPath)

        return """
        set -eu

        share=\(share)
        code=\(code)
        artifacts=\(artifacts)
        workdir="\(workdirShellExpression)"

        if [ ! -d "$share" ]; then
            printf 'viv: the VirtioFS share is not mounted at %s\\n' "$share" >&2
            exit 10
        fi
        if [ ! -d "$code" ]; then
            printf 'viv: the staged code is missing from the share: %s\\n' "$code" >&2
            exit 11
        fi
        if [ ! -d "$artifacts" ]; then
            printf 'viv: the artifact directory is missing from the share: %s\\n' "$artifacts" >&2
            exit 12
        fi
        if [ ! -w "$artifacts" ]; then
            printf 'viv: the artifact directory is not writable by %s: %s\\n' \\
                "$(/usr/bin/id -un)" "$artifacts" >&2
            exit 13
        fi

        /bin/rm -rf "$workdir"
        /bin/mkdir -p "$workdir"
        # `code/.` rather than `code` so the copy lands as the workdir's own
        # contents and includes dotfiles.
        /bin/cp -R "$code/." "$workdir/"
        """
    }

    /// The user's test command, and nothing else.
    ///
    /// The command is the script's last statement, so the shell exits with the
    /// command's own status and the run reports what the test decided. `set -e`
    /// covers the preamble: a failure to reach the workdir must not be reported
    /// as the test's result.
    static func testScript(
        command: String,
        environment: [String: String],
        runID: String
    ) -> String {
        var exports = [
            "export VIV_RUN_ID=\(ShellEscaping.singleQuoted(runID))",
            "export VIV_ARTIFACTS=\(ShellEscaping.singleQuoted(artifactsGuestPath))"
        ]
        for name in environment.keys.sorted() {
            exports.append("export \(name)=\(ShellEscaping.singleQuoted(environment[name]!))")
        }

        return """
        set -eu

        cd "\(workdirShellExpression)"
        \(exports.joined(separator: "\n"))

        \(command)
        """
    }

    /// Resolves the manifest's globs in the guest and copies what they matched
    /// into `$VIV_ARTIFACTS`, from where the host lifts them off the share.
    ///
    /// Resolved in the guest because that is where the files are: a build that
    /// produced `logs/build.log` produced it in the workdir, which the host
    /// cannot see. The patterns travel in a quoted here-document, so nothing in
    /// them is expanded on the way; `${~pattern}` then asks zsh to treat the
    /// variable's contents as a glob, and `NULL_GLOB` makes a pattern that
    /// matched nothing vanish instead of failing.
    ///
    /// Only regular files are copied, each under its own relative path. That
    /// keeps `logs/**` — which zsh expands to the directories as well as the
    /// files beneath them — from copying a directory into itself, at the price
    /// of not harvesting empty directories.
    ///
    /// The failure counter is called `failures` and not the obvious `status`,
    /// because zsh makes `status` a read-only synonym for `$?` and treats the
    /// assignment as fatal — which silently turned this whole script into a
    /// no-op that reported exit 1.
    static func harvestScript(patterns: [String]) -> String {
        let artifacts = ShellEscaping.singleQuoted(artifactsGuestPath)

        return """
        set -u
        setopt NULL_GLOB

        artifacts=\(artifacts)
        failures=0

        cd "\(workdirShellExpression)" || {
            printf 'viv: the workdir is gone; nothing to harvest\\n' >&2
            exit 20
        }

        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            matched=0
            for match in ${~pattern}; do
                [ -f "$match" ] || continue
                matched=1
                destination="$artifacts/$match"
                if ! /bin/mkdir -p "$(/usr/bin/dirname "$destination")"; then
                    printf 'viv: could not make a place for %s on the share\\n' "$match" >&2
                    failures=1
                    continue
                fi
                if ! /bin/cp "$match" "$destination"; then
                    printf 'viv: could not copy %s onto the share\\n' "$match" >&2
                    failures=1
                fi
            done
            if [ "$matched" -eq 0 ]; then
                printf 'viv: no files matched the artifact pattern %s\\n' "$pattern" >&2
            fi
        done <<'\(artifactPatternDelimiter)'
        \(patterns.joined(separator: "\n"))
        \(artifactPatternDelimiter)

        # The host reads these bytes off the share as soon as this returns.
        /bin/sync
        exit $failures
        """
    }
}
