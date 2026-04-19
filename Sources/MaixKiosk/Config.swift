import Foundation

enum Config {
    static var kioskMode: Bool = false
    static var trialMode: Bool = false
    static let trialDurationSeconds: TimeInterval = 90

    static let vmBundlePath: String = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MaixVM").path
    }()

    static let diskImageName = "disk.img"
    static let installerISOName = "installer.iso"
    static let efiVarsName = "efi_vars.fd"

    static let cpuCount: Int = {
        let host = ProcessInfo.processInfo.processorCount
        return min(6, max(2, host / 2))
    }()

    static let memorySizeMiB: UInt64 = {
        let gib: UInt64 = 1024
        let host = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let reserved: UInt64 = 2 * gib
        let preferred = host > reserved ? host - reserved : host / 2
        return max(2 * gib, min(preferred, 24 * gib))
    }()

    /// Cmd+Esc
    static let escapeModifiers: UInt = 0x100000
    static let escapeKeyCode: UInt16 = 53
}
