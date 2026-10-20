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

    /// How long `appLaunchScript` waits for the app's port by default.
    static let defaultAppPortTimeoutSeconds = 120

    /// The file in `$VIV_ARTIFACTS` that a launched app's output goes to.
    static let appLogFilename = "app.log"

    /// The line prefix `browserSetupScript` reports the guest's default
    /// gateway under, on stdout.
    static let gatewayLinePrefix = "gateway "

    /// Starts the app under test in the workdir, detached, and waits for its
    /// port when one is given.
    ///
    /// The app outlives the ssh session that starts it and ends with the
    /// guest. Its stdin is `/dev/null`: this script itself arrives on the
    /// shell's stdin, and a child left reading it would swallow the rest of
    /// the script. The port counts as open once either loopback address
    /// accepts a connection, because a dev server bound to `localhost` may
    /// listen on `::1` alone.
    func appLaunchScript(
        command: String,
        port: Int?,
        portTimeoutSeconds: Int = GuestScripts.defaultAppPortTimeoutSeconds
    ) -> String {
        var script = """
        set -eu

        cd "\(Self.workdirShellExpression)"
        export VIV_ARTIFACTS=\(ShellEscaping.singleQuoted(artifactsGuestPath))
        log="$VIV_ARTIFACTS/\(Self.appLogFilename)"

        /usr/bin/nohup \(shellExecutable) -c \(ShellEscaping.singleQuoted(command)) \\
            </dev/null >>"$log" 2>&1 &
        app=$!
        printf 'viv: the app is running as pid %s\\n' "$app"
        """

        guard let port else { return script }
        script += """


        port=\(port)
        limit=\(portTimeoutSeconds)
        waited=0
        until /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1 \\
            || /usr/bin/nc -z ::1 "$port" >/dev/null 2>&1; do
            if ! kill -0 "$app" 2>/dev/null; then
                printf 'viv: the app exited before anything listened on port %s\\n' "$port" >&2
                /usr/bin/tail -n 40 "$log" >&2 || true
                exit 31
            fi
            if [ "$waited" -ge "$limit" ]; then
                printf 'viv: nothing listened on port %s within %s seconds\\n' "$port" "$limit" >&2
                /usr/bin/tail -n 40 "$log" >&2 || true
                exit 32
            fi
            /bin/sleep 1
            waited=$((waited + 1))
        done
        printf 'viv: port %s accepted a connection after %s seconds\\n' "$port" "$waited"
        """
        return script
    }

    /// Prepares Safari for remote automation, keeps the display awake, and
    /// reports the guest's default gateway. macOS guests only.
    ///
    /// Needs no root: the per-user `AllowRemoteAutomation` preference is all
    /// `safaridriver --mcp` requires. Raising the ten-minute display sleep
    /// with `pmset` would need root, so a detached `caffeinate` holds the
    /// display awake instead, until the guest shuts down. The gateway is the
    /// host as the guest sees it, printed on stdout after
    /// `gatewayLinePrefix`, and empty when the guest has no default route.
    var browserSetupScript: String {
        """
        set -eu

        if [ ! -x /usr/bin/safaridriver ]; then
            printf 'viv: /usr/bin/safaridriver is missing, so this guest has no Safari MCP server\\n' >&2
            exit 40
        fi

        webdriver="$HOME/Library/WebDriver"
        plist="$webdriver/com.apple.Safari.plist"
        /bin/mkdir -p "$webdriver"
        # `add` refuses a key that is already there, as it is in a template
        # that was prepared by hand.
        if ! /usr/libexec/PlistBuddy -c 'add AllowRemoteAutomation bool true' "$plist" >/dev/null 2>&1; then
            /usr/libexec/PlistBuddy -c 'set AllowRemoteAutomation true' "$plist"
        fi

        /usr/bin/nohup /usr/bin/caffeinate -dims </dev/null >/dev/null 2>&1 &
        /usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int 0 || true

        gateway=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/ { print $2; exit }')
        printf '\(Self.gatewayLinePrefix)%s\\n' "$gateway"
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
