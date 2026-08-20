import Foundation

enum ShellDialect: String, Sendable {
    case zsh
    case bash
}

struct GuestScripts: Sendable {
    let dialect: ShellDialect
    let shellExecutable: String
    let sharePath: String
    let readinessCommand: String
    let shutdownCommand: String
    let shutdownWantsPasswordOnStdin: Bool
    let diagnosticsScript: String

    static let workdirShellExpression = "$HOME/vivwork"

    static let workdirDisplayPath = "~/vivwork"

    static let markerFilename = "viv-result.txt"

    static let reservedEnvironmentNames: Set<String> = ["VIV_RUN_ID", "VIV_ARTIFACTS"]

    static let artifactPatternDelimiter = "VIV_ARTIFACT_PATTERNS"

    var codeGuestPath: String { sharePath + "/code" }

    var artifactsGuestPath: String { sharePath + "/artifacts" }

    func remoteCommand(_ script: String) -> String {
        ShellEscaping.base64RemoteCommand(script: script, shell: shellExecutable)
    }

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

    private func globExpansion(of variable: String) -> String {
        switch dialect {
        case .zsh: return "${~\(variable)}"
        case .bash: return "$\(variable)"
        }
    }

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
