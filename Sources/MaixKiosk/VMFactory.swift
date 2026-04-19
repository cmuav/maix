import Foundation
import Virtualization

enum VMFactory {
    static func makeConfiguration(bundle: VMBundle,
                                  guestAgent: GuestAgentBridge? = nil) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        config.cpuCount = Config.cpuCount
        config.memorySize = Config.memorySize

        let bootloader = VZEFIBootLoader()
        bootloader.variableStore = try bundle.loadOrCreateEFIVariableStore()
        config.bootLoader = bootloader

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try bundle.loadOrCreateMachineIdentifier()
        config.platform = platform

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: bundle.diskImage,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        for name in ["installer.iso", "seed.iso"] {
            let url = bundle.root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let att = try VZDiskImageStorageDeviceAttachment(
                url: url, readOnly: true,
                cachingMode: .automatic, synchronizationMode: .full)
            let dev = VZUSBMassStorageDeviceConfiguration(attachment: att)
            config.storageDevices.append(dev)
        }

        let nat = VZNATNetworkDeviceAttachment()
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = nat
        config.networkDevices = [net]

        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [bestScanout()]
        config.graphicsDevices = [gpu]

        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        let serialLog = bundle.root.appendingPathComponent("serial.log")
        if !FileManager.default.fileExists(atPath: serialLog.path) {
            FileManager.default.createFile(atPath: serialLog.path, contents: nil)
        }
        if let writer = try? FileHandle(forWritingTo: serialLog),
           let reader = FileHandle(forReadingAtPath: "/dev/null") {
            writer.seekToEndOfFile()
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: reader,
                fileHandleForWriting: writer
            )
            config.serialPorts = [serial]
        }

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if let bridge = guestAgent {
            let port = try bridge.makePortConfiguration()
            let console = VZVirtioConsoleDeviceConfiguration()
            console.ports[0] = port
            config.consoleDevices.append(console)
        }

        if Config.enableRosetta {
            try addRosettaIfAvailable(to: config)
        }

        if Config.enableSharedHostFolder, let path = Config.sharedHostFolderPath {
            addHostShare(to: config, hostPath: path, tag: "hostshare")
        }

        try config.validate()
        return config
    }

    private static func bestScanout() -> VZVirtioGraphicsScanoutConfiguration {
        guard let screen = NSScreen.main else {
            return VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1080)
        }
        let scale = screen.backingScaleFactor
        let w = Int(screen.frame.width * scale)
        let h = Int(screen.frame.height * scale)
        return VZVirtioGraphicsScanoutConfiguration(widthInPixels: w, heightInPixels: h)
    }

    private static func addRosettaIfAvailable(to config: VZVirtualMachineConfiguration) throws {
        let availability = VZLinuxRosettaDirectoryShare.availability
        guard availability == .installed else {
            NSLog("Rosetta unavailable: \(availability.rawValue)")
            return
        }
        let rosetta = try VZLinuxRosettaDirectoryShare()
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
        fs.share = rosetta
        config.directorySharingDevices.append(fs)
    }

    private static func addHostShare(to config: VZVirtualMachineConfiguration,
                                     hostPath: String, tag: String) {
        let url = URL(fileURLWithPath: hostPath, isDirectory: true)
        let single = VZSharedDirectory(url: url, readOnly: false)
        let share = VZSingleDirectoryShare(directory: single)
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        fs.share = share
        config.directorySharingDevices.append(fs)
    }
}
