import Foundation
import Virtualization

/// Restores macOS into a bundle's system disk.
///
/// Every VM object is created and touched on the main actor, which is where
/// Virtualization requires its objects to live. The type is deliberately
/// short-lived: `install` returns only once the installer, its progress
/// observation, and the install-time VM have all been released, because the
/// next phase reconstructs a *different* VM from the same disk image and must
/// not race a still-attached one.
@MainActor
final class MacOSInstaller {
    private var virtualMachine: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var progressObservation: NSKeyValueObservation?
    private var eventRelay: VMEventRelay?

    private let paths: VMBundlePaths

    init(paths: VMBundlePaths) {
        self.paths = paths
    }

    /// Creates the system disk image.
    ///
    /// On macOS 16 and later the framework supports ASIF, a sparse format whose
    /// sparsity travels with the file rather than depending on the host
    /// filesystem. Since this package targets macOS 27, the RAW branch present
    /// in Apple's sample is unreachable here and is not carried over.
    func createSystemDiskImage(sizeGiB: Int = 128) async throws {
        guard !FileManager.default.fileExists(atPath: paths.systemDisk.path) else {
            throw VivError(
                .installation,
                "\(paths.systemDisk.path) already exists; refusing to overwrite an existing system disk."
            )
        }

        log.info("Creating a \(sizeGiB) GiB ASIF system disk at \(paths.systemDisk.path).")
        try await ProcessRunner.runChecked(
            "/usr/sbin/diskutil",
            ["image", "create", "blank",
             "--fs", "none",
             "--format", "ASIF",
             "--size", "\(sizeGiB)GiB",
             paths.systemDisk.path],
            timeout: .seconds(300),
            stage: .installation
        )
    }

    /// Runs the restore and returns the CPU/memory the install VM used, so the
    /// run VM can be built with the same shape.
    func install(
        restoreImage: LoadedRestoreImage,
        macAddress: VZMACAddress
    ) async throws -> (cpuCount: Int, memorySize: UInt64) {
        let configuration = try VMConfigurationFactory.makeInstallConfiguration(
            requirements: restoreImage.requirements,
            paths: paths,
            macAddress: macAddress
        )

        let relay = VMEventRelay()
        eventRelay = relay

        let machine = VZVirtualMachine(configuration: configuration)
        machine.delegate = relay
        virtualMachine = machine

        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restoreImage.url)
        self.installer = installer

        let installLogWriter = ProgressLogWriter(url: paths.installLog)
        installLogWriter.write("Installation starting from \(restoreImage.url.path).")
        progressObservation = installer.progress.observe(
            \.fractionCompleted,
            options: [.initial, .new]
        ) { _, change in
            guard let fraction = change.newValue else { return }
            installLogWriter.writeProgress(fraction: fraction)
        }

        log.info("Starting macOS installation. This may take several minutes.")

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                installer.install { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            installLogWriter.write("Installation failed: \(VivError.describe(error))")
            releaseInstallationObjects()
            throw VivError(
                .installation,
                "VZMacOSInstaller failed.",
                underlying: error,
                inspectionHints: [
                    "cat \(paths.installLog.path)",
                    "log show --last 30m --predicate 'subsystem == \"com.apple.Virtualization\"'"
                ]
            )
        }

        installLogWriter.write("Installation succeeded.")
        log.info("Installation succeeded.")

        let cpuCount = configuration.cpuCount
        let memorySize = configuration.memorySize

        try await stopInstallVirtualMachine()
        releaseInstallationObjects()

        return (cpuCount, memorySize)
    }

    /// Stops the install-time VM if the installer left it running.
    ///
    /// `VZMacOSInstaller` reports success with the VM in an implementation-
    /// defined state. Anything other than `.stopped` is forced down here — a
    /// destructive stop is acceptable at this point because the guest has not
    /// yet booted and there is no guest state to lose.
    private func stopInstallVirtualMachine() async throws {
        guard let machine = virtualMachine else { return }
        guard machine.state != .stopped else { return }

        log.info("Install VM is in state \(describe(machine.state)); stopping it.")
        if machine.canStop {
            do {
                try await machine.stop()
            } catch {
                log.warn("Stopping the install VM failed: \(VivError.describe(error))")
            }
        }

        // Give the framework a moment to settle so the disk image is no longer
        // held open when the template clone starts.
        for _ in 0..<50 where machine.state != .stopped {
            try? await Task.sleep(for: .milliseconds(200))
        }

        if machine.state != .stopped {
            log.warn("Install VM did not reach .stopped; it is \(describe(machine.state)).")
        }
    }

    /// Drops every object that could still hold the system disk open.
    private func releaseInstallationObjects() {
        progressObservation?.invalidate()
        progressObservation = nil
        installer = nil
        virtualMachine?.delegate = nil
        virtualMachine = nil
        eventRelay?.finish()
        eventRelay = nil
    }

    func describe(_ state: VZVirtualMachine.State) -> String {
        VMStateDescription.describe(state)
    }
}

/// Appends install progress to a log file with monotonic timestamps.
///
/// Progress is logged at whole-percent granularity: the KVO callback fires far
/// more often than that, and a log of every fractional change buries the two
/// lines that matter (when it started, when it stalled).
private final class ProgressLogWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var lastLoggedPercent = -1

    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    func writeProgress(fraction: Double) {
        let percent = Int(fraction * 100)
        lock.lock()
        let shouldLog = percent > lastLoggedPercent
        if shouldLog { lastLoggedPercent = percent }
        lock.unlock()
        guard shouldLog else { return }
        write("progress \(percent)%")
        if percent % 10 == 0 {
            log.info("Installation progress: \(percent)%.")
        }
    }

    func write(_ message: String) {
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let line = String(format: "[+%9.3fs] %@\n", seconds, message)
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

enum VMStateDescription {
    static func describe(_ state: VZVirtualMachine.State) -> String {
        switch state {
        case .stopped: return "stopped"
        case .running: return "running"
        case .paused: return "paused"
        case .error: return "error"
        case .starting: return "starting"
        case .pausing: return "pausing"
        case .resuming: return "resuming"
        case .stopping: return "stopping"
        case .saving: return "saving"
        case .restoring: return "restoring"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}
