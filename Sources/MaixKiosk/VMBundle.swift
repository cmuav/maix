import Foundation
import Virtualization

struct VMBundle {
    let root: URL
    let diskImage: URL
    let efiVariableStore: URL
    let machineIdentifier: URL

    init() {
        self.root = URL(fileURLWithPath: Config.vmBundlePath, isDirectory: true)
        self.diskImage = root.appendingPathComponent(Config.diskImageName)
        self.efiVariableStore = root.appendingPathComponent(Config.efiVariableStoreName)
        self.machineIdentifier = root.appendingPathComponent(Config.machineIdentifierName)
    }

    var installerISO: URL { root.appendingPathComponent("installer.iso") }
    var isFirstRun: Bool { !FileManager.default.fileExists(atPath: efiVariableStore.path) }

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

    func loadOrCreateMachineIdentifier() throws -> VZGenericMachineIdentifier {
        if FileManager.default.fileExists(atPath: machineIdentifier.path) {
            let data = try Data(contentsOf: machineIdentifier)
            guard let id = VZGenericMachineIdentifier(dataRepresentation: data) else {
                throw NSError(domain: "MaixKiosk", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Corrupt machine identifier"])
            }
            return id
        }
        let id = VZGenericMachineIdentifier()
        try id.dataRepresentation.write(to: machineIdentifier)
        return id
    }

    func loadOrCreateEFIVariableStore() throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: efiVariableStore.path) {
            return VZEFIVariableStore(url: efiVariableStore)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: efiVariableStore)
    }
}
