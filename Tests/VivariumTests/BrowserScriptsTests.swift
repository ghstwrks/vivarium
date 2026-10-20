import Foundation
import Testing

@testable import Vivarium

/// Parses `script` with the shell's `-n`, which reads every command and runs
/// none, and returns what the shell complained about.
private func syntaxErrors(in script: String, shell: String = "/bin/zsh") throws -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-n"]
    let input = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
    try input.fileHandleForWriting.close()
    let complaint = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? nil : String(decoding: complaint, as: UTF8.self)
}

@Suite("Browser session scripts")
struct BrowserScriptsTests {
    let mac = MacOSPlatform().scripts

    @Test("browser setup enables remote automation for the user, without root")
    func setupNeedsNoRoot() {
        let script = mac.browserSetupScript
        #expect(script.contains("mkdir -p \"$webdriver\""))
        #expect(script.contains("webdriver=\"$HOME/Library/WebDriver\""))
        #expect(script.contains("PlistBuddy -c 'add AllowRemoteAutomation bool true' \"$plist\""))
        #expect(script.contains("PlistBuddy -c 'set AllowRemoteAutomation true' \"$plist\""))
        #expect(!script.contains("sudo"))
        #expect(!script.contains("safaridriver --enable"))
        #expect(!script.contains("pmset"))
    }

    @Test("caffeinate is detached from the setup session and from its stdin")
    func caffeinateDetached() {
        #expect(mac.browserSetupScript.contains(
            "/usr/bin/nohup /usr/bin/caffeinate -dims </dev/null >/dev/null 2>&1 &"
        ))
    }

    @Test("browser setup reports the gateway on its own line")
    func setupReportsGateway() {
        let script = mac.browserSetupScript
        #expect(script.contains("/sbin/route -n get default"))
        #expect(script.contains("printf '\(GuestScripts.gatewayLinePrefix)%s\\n' \"$gateway\""))
    }

    @Test("the app runs detached in the workdir, with its output on the share")
    func appLaunchDetached() {
        let script = mac.appLaunchScript(command: "npm run dev", port: nil)
        #expect(script.contains("cd \"$HOME/vivwork\""))
        #expect(script.contains("export VIV_ARTIFACTS='/Volumes/My Shared Files/artifacts'"))
        #expect(script.contains("log=\"$VIV_ARTIFACTS/app.log\""))
        #expect(script.contains("/usr/bin/nohup /bin/zsh -c 'npm run dev'"))
        #expect(script.contains("</dev/null >>\"$log\" 2>&1 &"))
        #expect(!script.contains("nc -z"))
    }

    @Test("the app's command reaches its shell as one quoted word")
    func appLaunchQuoting() {
        let script = mac.appLaunchScript(command: "echo 'hi' && PORT=$P npm start", port: nil)
        #expect(script.contains(#"-c 'echo '\''hi'\'' && PORT=$P npm start'"#))
    }

    @Test("with a port, the launch waits on both loopback addresses up to its limit")
    func appLaunchWaitsForPort() {
        let script = mac.appLaunchScript(command: "npm run dev", port: 5173, portTimeoutSeconds: 45)
        #expect(script.contains("port=5173"))
        #expect(script.contains("limit=45"))
        #expect(script.contains("/usr/bin/nc -z 127.0.0.1 \"$port\""))
        #expect(script.contains("/usr/bin/nc -z ::1 \"$port\""))
        #expect(script.contains("exit 31"))
        #expect(script.contains("exit 32"))
    }

    @Test("both scripts parse in the guest's shell", arguments: [nil, 8080] as [Int?])
    func scriptsParse(port: Int?) throws {
        #expect(try syntaxErrors(in: mac.browserSetupScript) == nil)
        #expect(try syntaxErrors(in: mac.appLaunchScript(command: "npm run dev", port: port)) == nil)
    }
}

/// Runs the app launch script on this host, with the guest's workdir and
/// share replaced by directories under `root`, and returns its exit status.
private func runAppLaunch(command: String, port: Int, timeout: Int, in root: URL) throws -> Int32 {
    let workdir = root.appendingPathComponent("vivwork")
    let artifacts = root.appendingPathComponent("artifacts")
    try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    let script = MacOSPlatform().scripts
        .appLaunchScript(command: command, port: port, portTimeoutSeconds: timeout)
        .replacingOccurrences(of: GuestScripts.workdirShellExpression, with: workdir.path)
        .replacingOccurrences(of: "/Volumes/My Shared Files/artifacts", with: artifacts.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", script]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Suite("Launching the app under test")
struct AppLaunchBehaviourTests {
    @Test("an app that exits before its port opens fails the launch, with its output logged")
    func appThatDies() throws {
        let root = try temporaryDirectory()
        let status = try runAppLaunch(command: "echo boom; exit 3", port: 1, timeout: 10, in: root)
        #expect(status == 31)
        let log = try String(contentsOf: root.appendingPathComponent("artifacts/app.log"), encoding: .utf8)
        #expect(log.contains("boom"))
    }

    @Test("an app whose port never opens fails the launch at the limit")
    func portNeverOpens() throws {
        let root = try temporaryDirectory()
        let status = try runAppLaunch(command: "sleep 5", port: 1, timeout: 1, in: root)
        #expect(status == 32)
    }

    @Test("the launch returns once the port accepts a connection")
    func portOpens() throws {
        let root = try temporaryDirectory()
        let port = 20_000 + Int.random(in: 0..<20_000)
        let status = try runAppLaunch(
            command: "exec /usr/bin/nc -l 127.0.0.1 \(port)", port: port, timeout: 10, in: root
        )
        #expect(status == 0)
    }
}
