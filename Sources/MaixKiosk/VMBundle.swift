import Foundation

struct VMBundle {
    let root: URL
    let diskImage: URL
    let installerISO: URL
    let efiVars: URL
    let spiceSocket: URL
    let serialLog: URL

    init() {
        self.root = URL(fileURLWithPath: Config.vmBundlePath, isDirectory: true)
        self.diskImage = root.appendingPathComponent(Config.diskImageName)
        self.installerISO = root.appendingPathComponent(Config.installerISOName)
        self.efiVars = root.appendingPathComponent(Config.efiVarsName)
        self.spiceSocket = root.appendingPathComponent("spice.sock")
        self.serialLog = root.appendingPathComponent("serial.log")
        self.usbConfig = root.appendingPathComponent(Config.usbConfigName)
    }

    let usbConfig: URL
    var cameraSocket: URL { root.appendingPathComponent("camera.sock") }
    var cameraControlSocket: URL { root.appendingPathComponent("camera-control.sock") }

    func ensureUSBConfigExists() {
        guard !FileManager.default.fileExists(atPath: usbConfig.path) else { return }
        let template = """
        # Maix USB pass-through config.
        # One device per line. Format: VENDOR:PRODUCT     # optional label
        # Hex IDs. Find IDs with ./list-usb-mbn.sh on the build host.
        # Changes take effect on next Maix launch. Device must be plugged in
        # when the VM boots.
        #
        # Example (Logitech HD Webcam C270):
        # 046d:0825   Logitech C270
        """
        FileManager.default.createFile(atPath: usbConfig.path,
                                       contents: template.data(using: .utf8))
    }

    var isFirstRun: Bool { !FileManager.default.fileExists(atPath: efiVars.path) }

    func ensureExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    func ensureBlankDiskImage(bytes: UInt64 = 64 * 1024 * 1024 * 1024) throws {
        if FileManager.default.fileExists(atPath: diskImage.path) { return }
        FileManager.default.createFile(atPath: diskImage.path, contents: nil)
        let fh = try FileHandle(forWritingTo: diskImage)
        try fh.truncate(atOffset: bytes)
        try fh.close()
    }

    func importInstallerISO(from source: URL) throws {
        try? FileManager.default.removeItem(at: installerISO)
        try FileManager.default.copyItem(at: source, to: installerISO)
    }

    /// Seed efi_vars.fd from the bundle's edk2-arm-vars.fd template if missing.
    /// aarch64 pflash expects a 64 MiB region, so we pad the template with zeros.
    func ensureEFIVars(from template: URL) throws {
        guard !FileManager.default.fileExists(atPath: efiVars.path) else { return }
        try FileManager.default.copyItem(at: template, to: efiVars)
        let fh = try FileHandle(forWritingTo: efiVars)
        try fh.truncate(atOffset: 64 * 1024 * 1024)
        try fh.close()
    }
}
