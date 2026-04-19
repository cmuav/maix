import Foundation
import Darwin

/// Spawns maix-qemu-launcher as a subprocess. Launcher dlopens qemu and runs
/// its main loop.
final class QEMUProcess {
    private(set) var process: Process?
    var onExit: ((Int32) -> Void)?

    func start(paths: QEMUArgs.Paths, args: [String], logURL: URL) throws {
        let p = Process()
        p.executableURL = paths.launcher
        p.arguments = [paths.qemuDylib.path] + args

        let logFH: FileHandle
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logFH = try FileHandle(forWritingTo: logURL)
        logFH.seekToEndOfFile()
        p.standardOutput = logFH
        p.standardError = logFH

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.onExit?(proc.terminationStatus) }
        }

        NSLog("QEMU launcher: \(paths.launcher.path)")
        NSLog("QEMU argv: \(args.joined(separator: " "))")
        try p.run()
        process = p
    }

    func terminate() {
        process?.terminate()
    }

    func forceKill() {
        guard let p = process, p.isRunning else { return }
        Darwin.kill(p.processIdentifier, SIGKILL)
    }
}
