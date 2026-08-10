import Foundation
import Virtualization

/// Builds the two distinct VM configurations Vivarium needs.
///
/// Apple's sample builds exactly one configuration and reuses it. This splits
/// it in two, because the install VM must expose only the system disk — the
/// installer's behaviour when several writable block devices are present is
/// not documented, and guessing wrong costs a ninety-minute restore — while the
/// run VM needs the artifact disk and the VirtioFS share the proof depends on.
enum VMConfigurationFactory {
    static let artifactBlockDeviceIdentifier = "viv-artifacts"

    // MARK: - Sizing

    static func computeCPUCount() -> Int {
        let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
        var count = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
        count = max(count, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        count = min(count, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        return count
    }

    static func computeMemorySize() -> UInt64 {
        var memorySize: UInt64 = 8 * 1024 * 1024 * 1024
        memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        return memorySize
    }

    // MARK: - Platform

    /// Creates a fresh platform identity and writes every part of it to the
    /// bundle, so the run VM can be reconstructed byte-identically later.
    static func makePlatformForInstall(
        requirements: VZMacOSConfigurationRequirements,
        paths: VMBundlePaths
    ) throws -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()

        do {
            platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: paths.auxiliaryStorage,
                hardwareModel: requirements.hardwareModel,
                options: []
            )
        } catch {
            throw VivError(
                .installation,
                "Failed to create auxiliary storage at \(paths.auxiliaryStorage.path).",
                underlying: error
            )
        }

        platform.hardwareModel = requirements.hardwareModel
        platform.machineIdentifier = VZMacMachineIdentifier()

        do {
            try platform.hardwareModel.dataRepresentation.write(to: paths.hardwareModel)
            try platform.machineIdentifier.dataRepresentation.write(to: paths.machineIdentifier)
        } catch {
            throw VivError(
                .installation,
                "Failed to persist the platform identity into the bundle.",
                underlying: error
            )
        }

        return platform
    }

    /// Reloads the identity written during installation.
    ///
    /// All three parts must come from the same bundle. A hardware model paired
    /// with a different machine identifier or foreign auxiliary storage
    /// produces a VM that either refuses to start or boots as a different Mac.
    static func loadInstalledPlatform(paths: VMBundlePaths) throws -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()

        guard FileManager.default.fileExists(atPath: paths.auxiliaryStorage.path) else {
            throw VivError(.runConfiguration, "Missing \(paths.auxiliaryStorage.path).")
        }
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: paths.auxiliaryStorage)

        let hardwareModelData: Data
        let machineIdentifierData: Data
        do {
            hardwareModelData = try Data(contentsOf: paths.hardwareModel)
            machineIdentifierData = try Data(contentsOf: paths.machineIdentifier)
        } catch {
            throw VivError(
                .runConfiguration,
                "Failed to read the saved platform identity from \(paths.root.path).",
                underlying: error
            )
        }

        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            throw VivError(.runConfiguration, "\(paths.hardwareModel.path) is not a valid hardware model.")
        }
        guard hardwareModel.isSupported else {
            throw VivError(
                .runConfiguration,
                "The bundle's hardware model is not supported on this host."
            )
        }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            throw VivError(
                .runConfiguration,
                "\(paths.machineIdentifier.path) is not a valid machine identifier."
            )
        }

        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        return platform
    }

    // MARK: - Devices

    static func makeSystemDisk(paths: VMBundlePaths, stage: VivStage) throws -> VZVirtioBlockDeviceConfiguration {
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: paths.systemDisk,
                readOnly: false,
                cachingMode: .automatic,
                synchronizationMode: .fsync
            )
            return VZVirtioBlockDeviceConfiguration(attachment: attachment)
        } catch {
            throw VivError(
                stage,
                "Failed to attach the system disk at \(paths.systemDisk.path).",
                underlying: error
            )
        }
    }

    /// The artifact disk, attached with full synchronisation.
    ///
    /// Full synchronisation is chosen over the faster modes precisely because
    /// this disk exists to answer "did the guest's write survive detachment?".
    /// Any weaker mode leaves a failed validation ambiguous between "the guest
    /// never wrote it" and "the host never flushed it".
    static func makeArtifactDisk(
        paths: VMBundlePaths,
        readOnly: Bool = false
    ) throws -> VZVirtioBlockDeviceConfiguration {
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: paths.artifactDisk,
                readOnly: readOnly,
                cachingMode: .automatic,
                synchronizationMode: .full
            )
            let device = VZVirtioBlockDeviceConfiguration(attachment: attachment)
            device.blockDeviceIdentifier = artifactBlockDeviceIdentifier
            return device
        } catch {
            throw VivError(
                .runConfiguration,
                "Failed to attach the artifact disk at \(paths.artifactDisk.path).",
                underlying: error
            )
        }
    }

    static func makeVirtioFileSystemShare(
        paths: VMBundlePaths,
        readOnly: Bool = false
    ) -> VZVirtioFileSystemDeviceConfiguration {
        let directory = VZSharedDirectory(url: paths.sharedDirectory, readOnly: readOnly)
        let share = VZSingleDirectoryShare(directory: directory)
        // The automount tag is what makes the share appear under
        // /Volumes/My Shared Files without the guest running `mount`.
        let fileSystem = VZVirtioFileSystemDeviceConfiguration(
            tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
        )
        fileSystem.share = share
        return fileSystem
    }

    /// A network device with the run's persisted MAC address.
    ///
    /// The sample hardcodes one address, which makes ARP-based guest discovery
    /// ambiguous the moment two VMs exist. The address is generated per bundle
    /// and must stay identical between installation and first boot, because it
    /// is the only stable handle the host has on the guest's DHCP lease.
    static func makeNetworkDevice(macAddress: VZMACAddress) -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.macAddress = macAddress
        device.attachment = VZNATNetworkDeviceAttachment()
        return device
    }

    static func makeGraphicsDevice() -> VZMacGraphicsDeviceConfiguration {
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)
        ]
        return graphics
    }

    // MARK: - Configurations

    /// The install configuration: system disk only, no share, no artifact disk.
    static func makeInstallConfiguration(
        requirements: VZMacOSConfigurationRequirements,
        paths: VMBundlePaths,
        macAddress: VZMACAddress
    ) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = try makePlatformForInstall(requirements: requirements, paths: paths)

        let cpuCount = computeCPUCount()
        guard cpuCount >= requirements.minimumSupportedCPUCount else {
            throw VivError(
                .installation,
                "\(cpuCount) CPUs configured, but the restore image requires at least "
                    + "\(requirements.minimumSupportedCPUCount)."
            )
        }
        configuration.cpuCount = cpuCount

        let memorySize = computeMemorySize()
        guard memorySize >= requirements.minimumSupportedMemorySize else {
            throw VivError(
                .installation,
                "\(memorySize) bytes of memory configured, but the restore image requires at least "
                    + "\(requirements.minimumSupportedMemorySize)."
            )
        }
        configuration.memorySize = memorySize

        configuration.bootLoader = VZMacOSBootLoader()
        configuration.graphicsDevices = [makeGraphicsDevice()]
        configuration.networkDevices = [makeNetworkDevice(macAddress: macAddress)]
        configuration.storageDevices = [try makeSystemDisk(paths: paths, stage: .installation)]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        configuration.keyboards = [VZMacKeyboardConfiguration()]

        do {
            try configuration.validate()
            // Only asserted here. The run configuration deliberately violates
            // save/restore's device restrictions by adding a directory share
            // and a second block device, so asserting it there would fail for
            // reasons unrelated to this experiment.
            try configuration.validateSaveRestoreSupport()
        } catch {
            throw VivError(.installation, "The install VM configuration is invalid.", underlying: error)
        }

        return configuration
    }

    /// The run configuration: system disk, then artifact disk, then the share.
    static func makeRunConfiguration(
        paths: VMBundlePaths,
        macAddress: VZMACAddress,
        cpuCount: Int,
        memorySize: UInt64,
        shareReadOnly: Bool = false,
        artifactReadOnly: Bool = false
    ) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = try loadInstalledPlatform(paths: paths)
        configuration.cpuCount = cpuCount
        configuration.memorySize = memorySize
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.graphicsDevices = [makeGraphicsDevice()]
        configuration.networkDevices = [makeNetworkDevice(macAddress: macAddress)]

        // Order matters: the system disk must remain the first block device so
        // the boot loader finds the same device it installed onto.
        configuration.storageDevices = [
            try makeSystemDisk(paths: paths, stage: .runConfiguration),
            try makeArtifactDisk(paths: paths, readOnly: artifactReadOnly)
        ]

        configuration.directorySharingDevices = [
            makeVirtioFileSystemShare(paths: paths, readOnly: shareReadOnly)
        ]

        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        configuration.keyboards = [VZMacKeyboardConfiguration()]

        do {
            try configuration.validate()
        } catch {
            throw VivError(.runConfiguration, "The run VM configuration is invalid.", underlying: error)
        }

        return configuration
    }

    // MARK: - MAC address persistence

    /// Generates a locally administered unicast address and saves it.
    static func createAndPersistMACAddress(paths: VMBundlePaths) throws -> VZMACAddress {
        let address = VZMACAddress.randomLocallyAdministered()
        do {
            try Data(address.string.utf8).write(to: paths.macAddress, options: .atomic)
        } catch {
            throw VivError(
                .bundlePreparation,
                "Failed to persist the MAC address to \(paths.macAddress.path).",
                underlying: error
            )
        }
        return address
    }

    static func loadMACAddress(paths: VMBundlePaths, stage: VivStage) throws -> VZMACAddress {
        let text: String
        do {
            text = try String(contentsOf: paths.macAddress, encoding: .utf8)
        } catch {
            throw VivError(
                stage,
                "Failed to read the persisted MAC address from \(paths.macAddress.path).",
                underlying: error
            )
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = VZMACAddress(string: trimmed) else {
            throw VivError(stage, "\(trimmed) is not a valid MAC address.")
        }
        return address
    }
}
