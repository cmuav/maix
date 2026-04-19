import Cocoa
import UniformTypeIdentifiers
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: KioskWindowController?
    private var bundle: VMBundle?
    private var qemu: QEMUProcess?
    private var escapeMonitor: Any?
    private var spice: SpiceIO?
    private var inputRouter: SpiceInputRouter?
    private var socketWaiter: DispatchSourceTimer?
    private var usbAuto: SpiceUSBAutoConnect?
    private var camera: CameraBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Config.kioskMode {
            NSApp.presentationOptions = [
                .hideDock, .hideMenuBar,
                .disableProcessSwitching, .disableForceQuit,
                .disableSessionTermination, .disableAppleMenu,
                .disableHideApplication
            ]
        }

        installDefaultMenu()
        requestMediaPermissions()

        do {
            let bundle = VMBundle()
            try bundle.ensureExists()
            bundle.ensureUSBConfigExists()
            self.bundle = bundle

            guard let paths = QEMUArgs.resolvePaths() else {
                throw NSError(domain: "Maix", code: 10, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Maix.app is missing its qemu framework or resources. Rebuild with ./build.sh."
                ])
            }

            try runFirstBootSetupIfNeeded(bundle: bundle, paths: paths)

            let controller = KioskWindowController()
            self.controller = controller
            controller.show()

            let qemu = QEMUProcess()
            qemu.onExit = { [weak self] status in
                NSLog("QEMU exited with status \(status). Maix exiting.")
                self?.controller?.window.orderOut(nil)
                exit(status == 0 ? 0 : 1)
            }
            self.qemu = qemu

            let argv = QEMUArgs.build(bundle: bundle, paths: paths)
            let logURL = bundle.root.appendingPathComponent("qemu.log")
            try qemu.start(paths: paths, args: argv, logURL: logURL)

            let cam = CameraBridge(
                dataSocketPath: bundle.cameraSocket.path,
                controlSocketPath: bundle.cameraControlSocket.path
            )
            cam.start()
            self.camera = cam

            controller.showSerialConsole(tailing: bundle.serialLog)
            waitForSpiceSocket(bundle: bundle, controller: controller)

            installEscapeMonitor()
            NSApp.activate(ignoringOtherApps: true)

            if Config.trialMode {
                scheduleTrialShutdown()
            }
        } catch {
            NSLog("Fatal init error: \(error)")
            presentFatal(error)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        qemu?.terminate()
        return .terminateNow
    }

    // MARK: - First boot

    private func runFirstBootSetupIfNeeded(bundle: VMBundle, paths: QEMUArgs.Paths) throws {
        guard bundle.isFirstRun else { return }
        NSLog("First-run setup: efi_vars missing.")
        try bundle.ensureEFIVars(from: paths.edk2VarsTemplate)
        try bundle.ensureBlankDiskImage()

        if !FileManager.default.fileExists(atPath: bundle.installerISO.path) {
            guard let picked = promptForInstallerISO() else {
                throw NSError(domain: "Maix", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "First-run setup cancelled: no installer ISO selected."
                ])
            }
            NSLog("Copying installer ISO from \(picked.path)")
            try bundle.importInstallerISO(from: picked)
        }
    }

    private func promptForInstallerISO() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select installer ISO"
        panel.message = "First boot: pick the installer ISO. It will be copied into ~/MaixVM/."
        panel.allowedContentTypes = [UTType(filenameExtension: "iso"), UTType.diskImage].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Menu / escape

    private func requestMediaPermissions() {
        // Explicitly ask TCC for mic + camera. Without this the prompt never
        // surfaces when qemu's CoreAudio code opens the device lazily from a
        // subprocess, because TCC needs a request from the responsible bundle.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("Microphone access: \(granted ? "granted" : "denied")")
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            NSLog("Camera access: \(granted ? "granted" : "denied")")
        }
    }

    private func installDefaultMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Maix",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) && event.keyCode == Config.escapeKeyCode {
                DispatchQueue.main.async { self?.handleEscape() }
                return nil
            }
            return event
        }
    }

    private func handleEscape() {
        let alert = NSAlert()
        alert.messageText = "Maintenance"
        alert.informativeText = "Stop the VM and exit Maix?"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Exit")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        qemu?.terminate()
    }

    private func waitForSpiceSocket(bundle: VMBundle, controller: KioskWindowController) {
        let src = DispatchSource.makeTimerSource(queue: .main)
        src.schedule(deadline: .now() + 0.5, repeating: 0.5)
        var elapsed: Double = 0
        src.setEventHandler { [weak self] in
            elapsed += 0.5
            if FileManager.default.fileExists(atPath: bundle.spiceSocket.path) {
                src.cancel()
                self?.socketWaiter = nil
                self?.startSpice(bundle: bundle, controller: controller)
            } else if elapsed > 30 {
                src.cancel()
                self?.socketWaiter = nil
                NSLog("spice.sock never appeared after 30s.")
            }
        }
        src.resume()
        socketWaiter = src
    }

    private func startSpice(bundle: VMBundle, controller: KioskWindowController) {
        let spice = SpiceIO(socketURL: bundle.spiceSocket)
        let router = SpiceInputRouter()
        router.metalView = controller.metalView
        controller.metalView.inputDelegate = router
        self.inputRouter = router

        spice.onPrimaryDisplay = { [weak self] display in
            self?.inputRouter?.display = display
            self?.controller?.attach(display: display)
        }
        spice.onPrimaryInput = { [weak self] input in
            self?.inputRouter?.input = input
        }
        spice.onDisconnect = {
            NSLog("SPICE disconnected.")
        }
        spice.onError = { msg in
            NSLog("SPICE error: \(msg)")
        }
        spice.onAgentConnected = { [weak self] in
            // vdagent is up — userspace is ready. Hide the serial console,
            // reveal the live SPICE framebuffer, and nudge the guest to
            // match our window size.
            self?.controller?.handleAgentConnected()
        }
        spice.onConnected = { [weak self] conn in
            guard let self = self else { return }
            let wanted = QEMUArgs.parseUSBConfig(url: bundle.usbConfig)
                .map { ($0.0, $0.1) }
            self.usbAuto = SpiceUSBAutoConnect(manager: conn.usbManager, wanted: wanted)
            if wanted.isEmpty {
                NSLog("USB: no entries in \(bundle.usbConfig.path); passthrough disabled.")
            } else {
                NSLog("USB: watching \(wanted.count) VID:PID filter(s).")
            }
        }
        spice.onDisplayUpdated = { [weak self] _ in
            self?.controller?.handleDisplayUpdated()
        }

        do {
            try spice.start()
            guard spice.connect() else {
                NSLog("SpiceIO.connect() returned false")
                return
            }
            self.spice = spice
            NSLog("SpiceIO started. Awaiting primary display...")
        } catch {
            NSLog("SpiceIO start failed: \(error)")
        }
    }

    private func scheduleTrialShutdown() {
        let seconds = Config.trialDurationSeconds
        NSLog("Trial mode: will quit after \(Int(seconds))s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            NSLog("Trial mode: time up.")
            self?.qemu?.terminate()
        }
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Maix failed to start"
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }
}
