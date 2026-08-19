import Foundation
import Testing

@testable import Vivarium

/// The guest scripts are text that a shell somewhere else executes, and nothing
/// in the type system checks them. They are also where a mistake is least
/// visible: an over-escaped `\n` in a `printf` format produced a marker one byte
/// longer than the host expected and a validation failure that said nothing
/// about the cause. These are the assertions that would have caught it, plus the
/// ones that keep the two dialects saying the same thing.
@Suite("Guest scripts")
struct GuestScriptsTests {
    let mac = MacOSPlatform().scripts
    let linux = LinuxPlatform(os: .fedora).scripts

    /// The exact bytes a marker write has to produce. `printf '%s\n'` writes the
    /// marker and one newline; `printf '%s\\n'` writes a backslash and an `n`,
    /// which is a marker the host will not recognise.
    @Test("marker writes use a real newline, not an escaped backslash")
    func markerNewline() throws {
        let expectations = RunExpectations.generate(runID: "test-run")
        for (scripts, withVolume) in [(mac, true), (mac, false), (linux, false)] {
            let script = scripts.acceptanceScript(
                expectations: expectations, withArtifactVolume: withVolume
            )
            #expect(!script.contains(#"printf '%s\\n'"#))
            #expect(script.contains(#"printf '%s\n' "$marker" > "$share/$marker_file""#))
            if withVolume {
                #expect(script.contains(#"printf '%s\n' "$marker" > "$artifact/$marker_file""#))
            }
        }
    }

    /// The artifact volume is a macOS-only proof. A guest that does not claim it
    /// must not be asked to mount a volume that was never attached.
    @Test("a guest without an artifact disk is not asked about one")
    func acceptanceWithoutArtifactVolume() {
        let expectations = RunExpectations.generate(runID: "test-run")
        let script = linux.acceptanceScript(expectations: expectations, withArtifactVolume: false)
        #expect(!script.contains("diskutil"))
        #expect(!script.contains("artifact_volume"))
        #expect(script.contains("require_writable_directory share"))
        #expect(!script.contains("require_writable_directory artifact"))
    }

    /// The share is the one path a guest cannot be assumed to agree with the
    /// host about, so every script that touches it has to name the guest's own.
    @Test("every script uses its own guest's share path")
    func sharePaths() {
        #expect(mac.sharePath == "/Volumes/My Shared Files")
        #expect(linux.sharePath == "/mnt/viv")
        #expect(mac.prepareScript.contains("/Volumes/My Shared Files/code"))
        #expect(linux.prepareScript.contains("/mnt/viv/code"))
        #expect(linux.artifactsGuestPath == "/mnt/viv/artifacts")
    }

    /// zsh needs a tilde to expand a variable as a pattern and bash does not;
    /// getting that wrong makes the harvest match one literal filename and
    /// report every glob as unmatched.
    @Test("each dialect expands a pattern variable its own way")
    func globExpansion() {
        let patterns = ["logs/*.log"]
        #expect(mac.harvestScript(patterns: patterns).contains("for match in ${~pattern}"))
        #expect(mac.harvestScript(patterns: patterns).contains("setopt NULL_GLOB"))
        #expect(linux.harvestScript(patterns: patterns).contains("for match in $pattern"))
        #expect(linux.harvestScript(patterns: patterns).contains("shopt -s nullglob"))
    }

    /// `**` means `*` on both guests, on purpose: bash's `globstar` would make
    /// one `viv.json` harvest a different set of files depending on which guest
    /// ran it.
    @Test("globstar is not enabled for bash")
    func noGlobstar() {
        #expect(!linux.harvestScript(patterns: ["logs/**"]).contains("globstar"))
    }

    /// The patterns travel in a quoted here-document so nothing in them is
    /// expanded on the way; a pattern equal to the delimiter is refused by the
    /// manifest reader, and this is the other half of that arrangement.
    @Test("artifact patterns travel verbatim in a quoted here-document")
    func harvestHeredoc() {
        let script = linux.harvestScript(patterns: ["a b/*.txt", "$(danger)"])
        #expect(script.contains("<<'\(GuestScripts.artifactPatternDelimiter)'"))
        #expect(script.contains("a b/*.txt\n$(danger)"))
    }

    /// Vivarium's own variables are exported last, so a manifest that somehow
    /// named one cannot leave `$VIV_ARTIFACTS` pointing away from the share.
    @Test("Vivarium's variables are exported after the caller's")
    func testScriptExportOrder() {
        let script = linux.testScript(
            command: "make test",
            environment: ["ZZZ": "last-alphabetically", "CI": "1"],
            runID: "r1"
        )
        let vivIndex = try? #require(script.range(of: "export VIV_ARTIFACTS="))
        let userIndex = try? #require(script.range(of: "export ZZZ="))
        #expect(userIndex!.lowerBound < vivIndex!.lowerBound)
        #expect(script.hasSuffix("make test"))
        // The preamble is Vivarium's and is strict; the command is the user's
        // and is not.
        #expect(script.contains("set -eu"))
        #expect(script.contains("set +eu"))
    }

    /// A value that reaches the guest has one layer of quoting put back on it,
    /// and single quotes are the only character that needs care.
    @Test("environment values are single-quoted")
    func testScriptQuoting() {
        let script = linux.testScript(
            command: "true",
            environment: ["TOKEN": "it's $HOME `whoami`"],
            runID: "r1"
        )
        #expect(script.contains(#"export TOKEN='it'\''s $HOME `whoami`'"#))
    }

    /// Both guests are piped a base64 blob, because a script quoted in place has
    /// to survive local quoting, ssh's concatenation, and the remote shell.
    @Test("remote commands are base64, piped into the guest's own shell")
    func remoteCommandShape() {
        #expect(mac.remoteCommand("echo hi").hasSuffix("| /bin/zsh -s"))
        #expect(linux.remoteCommand("echo hi").hasSuffix("| /bin/bash -s"))
        let encoded = Data("echo hi".utf8).base64EncodedString()
        #expect(linux.remoteCommand("echo hi").contains(encoded))
    }
}
