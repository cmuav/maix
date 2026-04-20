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
    static let usbConfigName = "usb.conf"

    /// Give the guest every host core minus one for macOS. On low-core
    /// Apple Silicon SoCs (e.g. A18 Pro with 2P+4E = 6 total), capping to
    /// P-cores only starves the guest and tanks JS / UI throughput; the
    /// E-cores on these SoCs are capable enough that letting the macOS
    /// scheduler place vCPUs across P+E beats sitting idle on 2 P-cores.
    /// On fatter Macs (M-series Pro/Max), host-1 still leaves plenty.
    static let cpuCount: Int = {
        let host = ProcessInfo.processInfo.processorCount
        return max(1, host)
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
