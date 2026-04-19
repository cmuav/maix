import Foundation
import Virtualization

enum Config {
    static let vmBundlePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("MaixVM").path
    }()

    static let diskImageName = "disk.img"
    static let efiVariableStoreName = "nvram"
    static let machineIdentifierName = "machineIdentifier"

    static let cpuCount: Int = {
        let host = ProcessInfo.processInfo.processorCount
        // Half the host cores, capped at 6. Fedora aarch64 kernel has panicked
        // on higher vCPU counts under VZ; 6 is the empirical safe ceiling.
        let preferred = max(2, host / 2)
        let capped = min(preferred, 6)
        let clamped = min(
            max(capped, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount
        )
        return clamped
    }()

    /// Ceiling handed to VZ at boot. The balloon controller reclaims from here
    /// under memory pressure, so we can be generous. Reserves 2 GiB for macOS,
    /// caps at 24 GiB, floors at 2 GiB.
    static let memorySize: UInt64 = {
        let gib: UInt64 = 1024 * 1024 * 1024
        let mib: UInt64 = 1024 * 1024
        let host = ProcessInfo.processInfo.physicalMemory
        let reserved: UInt64 = 2 * gib
        let preferred = host > reserved ? host - reserved : host / 2
        let capped = min(preferred, 24 * gib)
        let floor = max(2 * gib, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        let ceiling = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        let aligned = (max(capped, floor) / mib) * mib
        return min(max(aligned, floor), ceiling)
    }()

    static var kioskMode: Bool = false
    static var trialMode: Bool = false
    static let trialDurationSeconds: TimeInterval = 90

    static let enableRosetta = true
    static let enableSharedHostFolder = false
    static let sharedHostFolderPath: String? = nil

    static let escapeModifiers: UInt = 0x100000 | 0x80000 | 0x20000
    static let escapeKeyCode: UInt16 = 53
}
