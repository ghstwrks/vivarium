import Foundation

/// The shell a guest's scripts are written in.
///
/// Only two things about a shell reach these scripts: how globbing is turned
/// on, and how a variable holding a pattern is expanded as one. Everything else
/// they use is POSIX, so a third dialect would be a third case here rather than
/// a third copy of the scripts.
enum ShellDialect: String, Sendable {
    case zsh
    case bash
}

/// Every command Vivarium asks a guest to run, in that guest's own shell.
///
/// One value per guest operating system, supplied by its `GuestPlatform`. The
/// scripts themselves are written once: the guests differ in where the share is
/// mounted, which shell interprets the script, how that shell is asked to glob,
/// and how the machine is asked to shut itself down — and in nothing else, which
/// is why they are parameters rather than separate scripts. Every absolute path
/// below (`/bin/cp`, `/usr/bin/id`, `/bin/mkdir`) exists at that path on both a
/// macOS guest and a usr-merged Linux one.
struct GuestScripts: Sendable {
    let dialect: ShellDialect
    /// The shell every remote script is piped into.
    let shellExecutable: String
    /// Where the VirtioFS share appears in the guest.
    ///
    /// On macOS this is where the automount tag puts it; on Linux it is where
    /// the guest was told to mount it during provisioning. Either way the
    /// scripts assert it is really there rather than assuming it.
    let sharePath: String
    /// A command that must exit zero and print the account's short name and
    /// nothing else.
    ///
    /// Run before anything is asserted, so that "the guest is not ready yet"
    /// stays distinguishable from a deliberate non-zero exit later.
    let readinessCommand: String
    /// A graceful shutdown requested from inside the guest.
    let shutdownCommand: String
    /// Whether `shutdownCommand` expects the account password on stdin, as
    /// `sudo -S` does. False for a guest whose account escalates without one.
    let shutdownWantsPasswordOnStdin: Bool
    /// What to collect from a guest whose run has gone wrong.
    let diagnosticsScript: String

    // MARK: - Fixed vocabulary

    /// Where the code is copied to before the test runs.
    ///
    /// Guest-local rather than the share itself: builds and test runners
    /// hardlink, mmap, chmod, and create sockets, and doing that on a VirtioFS
    /// mount is a well-known source of failures that have nothing to do with
    /// the code under test.
    static let workdirShellExpression = "$HOME/vivwork"

    /// The workdir as it reads in a report, where `$HOME` means nothing.
    static let workdirDisplayPath = "~/vivwork"

    /// The file the guest writes its marker into, on every surface the run
    /// checks.
    static let markerFilename = "viv-result.txt"

    /// Variables Vivarium sets for the test command, and which a manifest's
    /// `env` therefore may not set.
    static let reservedEnvironmentNames: Set<String> = ["VIV_RUN_ID", "VIV_ARTIFACTS"]

    /// The here-document delimiter the artifact patterns are passed under.
    ///
    /// Quoted at the point of use, so the patterns undergo no expansion on
    /// their way into the guest; a pattern equal to this word is rejected when
    /// the manifest is read.
    static let artifactPatternDelimiter = "VIV_ARTIFACT_PATTERNS"

    /// The share subdirectory the staged code arrives in.
    var codeGuestPath: String { sharePath + "/code" }

    /// The share subdirectory the guest writes artifacts into.
    var artifactsGuestPath: String { sharePath + "/artifacts" }

    /// Wraps a script for delivery over SSH, in this guest's shell.
    func remoteCommand(_ script: String) -> String {
        ShellEscaping.base64RemoteCommand(script: script, shell: shellExecutable)
    }

    // MARK: - Globbing

    /// Turns on the globbing behaviour the harvest depends on.
    ///
    /// `**` is deliberately left meaning `*` in both dialects. zsh only treats
    /// `**` as recursive when it is followed by a slash, so `logs/**` has
    /// always matched one level on a macOS guest; enabling bash's `globstar`
    /// would make the same manifest harvest a different set of files depending
    /// on which guest ran it, which is worse than a pattern that is merely less
    /// powerful than it looks.
    private var globPreamble: String {
        switch dialect {
        case .zsh:
            return """
            setopt NULL_GLOB
            # zsh's bare glob qualifiers make `*(e:'command':)` a pattern that runs
            # a command while matching. The manifest validator presents `artifacts`
            # as a list of inert path patterns, so they are matched as inert path
            # patterns; the parenthesis is a literal here, as it is everywhere else.
            setopt NO_BARE_GLOB_QUAL
            """
        case .bash:
            return """
            shopt -s nullglob
            # An empty IFS is what keeps a pattern containing a space from being
            # split into two patterns. Pathname expansion happens after word
            # splitting and is unaffected, so the matches still arrive as
            # separate words.
            IFS=
            """
        }
    }

    /// Expands a variable holding a glob pattern as a glob.
    private func globExpansion(of variable: String) -> String {
        switch dialect {
        // Without the tilde, zsh treats the variable's contents as a literal
        // filename rather than a pattern.
        case .zsh: return "${~\(variable)}"
        case .bash: return "$\(variable)"
        }
    }

    // MARK: - `viv run`

    /// Copies the staged code out of the share into the guest-local workdir.
    ///
    /// A pre-existing workdir is removed rather than merged: a guest is fresh
    /// every run today, and if that ever stops being true, a test that passes
    /// because of a file left by a previous run is the worst kind of failure.
    var prepareScript: String {
        let share = ShellEscaping.singleQuoted(sharePath)
        let code = ShellEscaping.singleQuoted(codeGuestPath)
        let artifacts = ShellEscaping.singleQuoted(artifactsGuestPath)

        return """
        set -eu

        share=\(share)
        code=\(code)
        artifacts=\(artifacts)
        workdir="\(Self.workdirShellExpression)"

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
    ///
    /// It is then turned off again for the command itself, because the command
    /// is the user's shell script and not Vivarium's. Under `-e` a multi-line
    /// `test:` stops at its first non-zero line — including the ones that are
    /// meant to fail, like a grep that finds nothing — and under `-u` a
    /// reference to an unset variable kills the run outright. Neither is what
    /// the same lines would do in the shell the user tried them in, and a test
    /// harness that quietly changes the semantics of what it runs is worse than
    /// one that runs it plainly.
    ///
    /// Vivarium's own variables are exported last so that they hold whatever
    /// the caller passed: the manifest parser rejects an `env` that names one
    /// of them, but this script is the only place that can guarantee it, and
    /// `$VIV_ARTIFACTS` pointing somewhere other than the share would silently
    /// harvest nothing.
    func testScript(
        command: String,
        environment: [String: String],
        runID: String
    ) -> String {
        var exports: [String] = []
        for name in environment.keys.sorted() where !Self.reservedEnvironmentNames.contains(name) {
            exports.append("export \(name)=\(ShellEscaping.singleQuoted(environment[name]!))")
        }
        exports.append("export VIV_RUN_ID=\(ShellEscaping.singleQuoted(runID))")
        exports.append("export VIV_ARTIFACTS=\(ShellEscaping.singleQuoted(artifactsGuestPath))")

        return """
        set -eu

        cd "\(Self.workdirShellExpression)"
        \(exports.joined(separator: "\n"))

        # From here on the script is the user's, and behaves as it would in
        # their own shell.
        set +eu

        \(command)
        """
    }

    /// Resolves the manifest's globs in the guest and copies what they matched
    /// into `$VIV_ARTIFACTS`, from where the host lifts them off the share.
    ///
    /// Resolved in the guest because that is where the files are: a build that
    /// produced `logs/build.log` produced it in the workdir, which the host
    /// cannot see. The patterns travel in a quoted here-document, so nothing in
    /// them is expanded on the way, and each is then expanded as a pattern by
    /// the one mechanism this shell has for it.
    ///
    /// Only regular files are copied, each under its own relative path. That
    /// keeps a pattern that matches directories as well as files from copying a
    /// directory into itself, at the price of not harvesting empty directories.
    ///
    /// The failure counter is called `failures` and not the obvious `status`,
    /// because zsh makes `status` a read-only synonym for `$?` and treats the
    /// assignment as fatal — which silently turned this whole script into a
    /// no-op that reported exit 1.
    func harvestScript(patterns: [String]) -> String {
        let artifacts = ShellEscaping.singleQuoted(artifactsGuestPath)

        return """
        set -u
        \(globPreamble)

        artifacts=\(artifacts)
        failures=0

        cd "\(Self.workdirShellExpression)" || {
            printf 'viv: the workdir is gone; nothing to harvest\\n' >&2
            exit 20
        }

        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            matched=0
            for match in \(globExpansion(of: "pattern")); do
                [ -f "$match" ] || continue
                matched=1
                destination="$artifacts/$match"
                # `--` throughout: a matched file named `-n` is a filename, not
                # an option, and without it the harvest of an otherwise fine run
                # fails on someone's test fixture.
                if ! /bin/mkdir -p "$(/usr/bin/dirname -- "$destination")"; then
                    printf 'viv: could not make a place for %s on the share\\n' "$match" >&2
                    failures=1
                    continue
                fi
                if ! /bin/cp -- "$match" "$destination"; then
                    printf 'viv: could not copy %s onto the share\\n' "$match" >&2
                    failures=1
                fi
            done
            if [ "$matched" -eq 0 ]; then
                printf 'viv: no files matched the artifact pattern %s\\n' "$pattern" >&2
            fi
        done <<'\(Self.artifactPatternDelimiter)'
        \(patterns.joined(separator: "\n"))
        \(Self.artifactPatternDelimiter)

        # The host reads these bytes off the share as soon as this returns.
        /bin/sync
        exit $failures
        """
    }

    // MARK: - `viv selftest`

    /// The acceptance command.
    ///
    /// Every value interpolated here is generated by this tool — a UUID, a hex
    /// nonce, a volume name it chose — so none of it is attacker-influenced.
    /// It is still single-quoted, and the whole script is delivered base64-
    /// encoded, so that a marker containing an unexpected character could never
    /// change the script's meaning.
    ///
    /// - Parameter withArtifactVolume: whether this guest's acceptance run
    ///   asserts on the separate artifact disk. A guest whose platform does not
    ///   claim that proof is not asked to write to a volume that was never
    ///   attached; `RunReport` says so rather than passing the criterion by
    ///   default.
    func acceptanceScript(
        expectations: RunExpectations,
        withArtifactVolume: Bool
    ) -> String {
        let share = ShellEscaping.singleQuoted(sharePath)
        let marker = ShellEscaping.singleQuoted(expectations.marker)
        let stdoutToken = ShellEscaping.singleQuoted(expectations.stdoutToken)
        let stderrToken = ShellEscaping.singleQuoted(expectations.stderrToken)
        let markerFile = ShellEscaping.singleQuoted(Self.markerFilename)

        var artifactPreamble = ""
        var artifactAssertion = ""
        var artifactWrite = ""
        if withArtifactVolume {
            let artifactVolume = ShellEscaping.singleQuoted(expectations.artifactVolumeName)
            let artifactPath = ShellEscaping.singleQuoted(
                "/Volumes/\(expectations.artifactVolumeName)"
            )
            artifactPreamble = """

                artifact=\(artifactPath)
                artifact_volume=\(artifactVolume)

                # The artifact volume is preformatted APFS on a Virtio block device.
                # macOS automounts external volumes via diskarbitrationd in a console
                # user session, so with nobody logged in it may never appear. Mounting
                # by volume name makes the run independent of that behaviour.
                if [ ! -d "$artifact" ]; then
                    /usr/sbin/diskutil mount "$artifact_volume" >&2
                fi
                """
            artifactAssertion = "\nrequire_writable_directory artifact \"$artifact\""
            // `\\n` is one backslash and an `n` once Swift is done with it, which
            // is the `\n` printf needs. Two would make printf emit a literal
            // backslash and an `n` instead of a newline — a marker one byte
            // longer than the host expects, and a validation that fails for a
            // reason nothing about it suggests.
            artifactWrite = "\nprintf '%s\\n' \"$marker\" > \"$artifact/$marker_file\""
        }

        return """
        set -eu

        share=\(share)
        marker=\(marker)
        marker_file=\(markerFile)
        \(artifactPreamble)

        # Assert on the real mounts rather than trusting that they appeared.
        #
        # Each check reports which one failed and exits a distinct status. A
        # bare `test` under `set -e` exits 1 with nothing on either stream,
        # which is indistinguishable from the script never running at all — the
        # exact ambiguity that made an unwritable artifact volume look like a
        # broken harness.
        require_writable_directory() {
            label=$1
            path=$2
            if [ ! -d "$path" ]; then
                printf 'acceptance: the %s directory is missing: %s\\n' "$label" "$path" >&2
                exit 10
            fi
            if [ ! -w "$path" ]; then
                printf 'acceptance: the %s directory is not writable by %s: %s\\n' \\
                    "$label" "$(/usr/bin/id -un)" "$path" >&2
                /bin/ls -ld "$path" >&2 || true
                exit 11
            fi
        }

        require_writable_directory share "$share"\(artifactAssertion)

        printf '%s\\n' "$marker" > "$share/$marker_file"\(artifactWrite)
        printf '%s\\n' "$marker" > "$HOME/$marker_file"

        # Flush before the host is told the write happened. Combined with the
        # artifact disk's full synchronisation mode, this removes the ambiguity
        # between "the guest never wrote it" and "the host never flushed it".
        /bin/sync

        printf '%s\\n' \(stdoutToken)
        printf '%s\\n' \(stderrToken) >&2

        # A deliberately non-zero status. Exit 23 proves the harness reports the
        # remote command's own status instead of collapsing anything non-zero
        # into a generic failure. 255 is avoided: OpenSSH reserves it for its
        # own errors, which would make the assertion meaningless.
        exit 23
        """
    }
}
