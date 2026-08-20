import Foundation
import Testing

@testable import Vivarium

@Suite("Guest scripts")
struct GuestScriptsTests {
    let mac = MacOSPlatform().scripts
    let linux = LinuxPlatform(os: .fedora).scripts

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

    @Test("a guest without an artifact disk is not asked about one")
    func acceptanceWithoutArtifactVolume() {
        let expectations = RunExpectations.generate(runID: "test-run")
        let script = linux.acceptanceScript(expectations: expectations, withArtifactVolume: false)
        #expect(!script.contains("diskutil"))
        #expect(!script.contains("artifact_volume"))
        #expect(script.contains("require_writable_directory share"))
        #expect(!script.contains("require_writable_directory artifact"))
    }

    @Test("every script uses its own guest's share path")
    func sharePaths() {
        #expect(mac.sharePath == "/Volumes/My Shared Files")
        #expect(linux.sharePath == "/mnt/viv")
        #expect(mac.prepareScript.contains("/Volumes/My Shared Files/code"))
        #expect(linux.prepareScript.contains("/mnt/viv/code"))
        #expect(linux.artifactsGuestPath == "/mnt/viv/artifacts")
    }

    @Test("each dialect expands a pattern variable its own way")
    func globExpansion() {
        let patterns = ["logs/*.log"]
        #expect(mac.harvestScript(patterns: patterns).contains("for match in ${~pattern}"))
        #expect(mac.harvestScript(patterns: patterns).contains("setopt NULL_GLOB"))
        #expect(linux.harvestScript(patterns: patterns).contains("for match in $pattern"))
        #expect(linux.harvestScript(patterns: patterns).contains("shopt -s nullglob"))
    }

    @Test("globstar is not enabled for bash")
    func noGlobstar() {
        #expect(!linux.harvestScript(patterns: ["logs/**"]).contains("globstar"))
    }

    @Test("artifact patterns travel verbatim in a quoted here-document")
    func harvestHeredoc() {
        let script = linux.harvestScript(patterns: ["a b/*.txt", "$(danger)"])
        #expect(script.contains("<<'\(GuestScripts.artifactPatternDelimiter)'"))
        #expect(script.contains("a b/*.txt\n$(danger)"))
    }

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
        #expect(script.contains("set -eu"))
        #expect(script.contains("set +eu"))
    }

    @Test("environment values are single-quoted")
    func testScriptQuoting() {
        let script = linux.testScript(
            command: "true",
            environment: ["TOKEN": "it's $HOME `whoami`"],
            runID: "r1"
        )
        #expect(script.contains(#"export TOKEN='it'\''s $HOME `whoami`'"#))
    }

    @Test("remote commands are base64, piped into the guest's own shell")
    func remoteCommandShape() {
        #expect(mac.remoteCommand("echo hi").hasSuffix("| /bin/zsh -s"))
        #expect(linux.remoteCommand("echo hi").hasSuffix("| /bin/bash -s"))
        let encoded = Data("echo hi".utf8).base64EncodedString()
        #expect(linux.remoteCommand("echo hi").contains(encoded))
    }
}
