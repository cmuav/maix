import Cocoa
import Virtualization
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    private var vm: VZVirtualMachine?
    private var controller: KioskWindowController?
    private var bundle: VMBundle?
    private var escapeMonitor: Any?
    private var balloonController: BalloonController?
    private var guestAgent: GuestAgentBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Config.kioskMode {
            NSApp.presentationOptions = [
                .hideDock,
                .hideMenuBar,
                .disableProcessSwitching,
                .disableForceQuit,
                .disableSessionTermination,
                .disableMenuBarTransparency,
                .disableAppleMenu,
                .disableHideApplication
            ]
        }

        installDefaultMenu()

        do {
            let bundle = VMBundle()
            try bundle.ensureExists()
            self.bundle = bundle

            try runFirstBootSetupIfNeeded(bundle: bundle)

            let agent = GuestAgentBridge()
            self.guestAgent = agent
            let config = try VMFactory.makeConfiguration(bundle: bundle, guestAgent: agent)
            let machine = VZVirtualMachine(configuration: config)
            machine.delegate = self
            self.vm = machine

            let controller = KioskWindowController(vm: machine)
            self.controller = controller
            controller.show()

            installEscapeMonitor()

            NSApp.activate(ignoringOtherApps: true)

            machine.start { [weak self] result in
                if case .failure(let error) = result {
                    NSLog("VM start failed: \(error)")
                    return
                }
                DispatchQueue.main.async {
                    guard let self = self, let vm = self.vm else { return }
                    self.balloonController = BalloonController(vm: vm, ceiling: Config.memorySize)
                    self.balloonController?.start()
                    do { try self.guestAgent?.start() }
                    catch { NSLog("GuestAgentBridge start failed: \(error)") }
                }
            }
        } catch {
            NSLog("Fatal init error: \(error)")
            presentFatal(error)
        }

        if Config.kioskMode {
            installReactivationWatchdog()
        }

        if Config.trialMode {
            scheduleTrialShutdown()
        }
    }

    private func scheduleTrialShutdown() {
        let seconds = Config.trialDurationSeconds
        NSLog("Trial mode: will quit after \(Int(seconds))s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            NSLog("Trial mode: time up, stopping VM and quitting.")
            guard let vm = self?.vm else { NSApp.terminate(nil); return }
            vm.stop { _ in
                DispatchQueue.main.async { exit(0) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        }
    }

    private func installDefaultMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Maix",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let viewMenuItem = NSMenuItem()
        main.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let fs = NSMenuItem(
            title: "Toggle Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fs)
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Config.kioskMode
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = vm, vm.state == .running || vm.state == .paused else { return .terminateNow }
        vm.stop { _ in
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        NSLog("Guest stopped cleanly. Exiting kiosk.")
        balloonController?.stop()
        guestAgent?.stop()
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        NSLog("Guest stopped with error: \(error). Exiting with failure.")
        balloonController?.stop()
        guestAgent?.stop()
        exit(1)
    }

    private func restartVM() {
        guard let bundle = bundle else { return }
        balloonController?.stop(); balloonController = nil
        guestAgent?.stop()
        let agent = GuestAgentBridge()
        guestAgent = agent
        do {
            let config = try VMFactory.makeConfiguration(bundle: bundle, guestAgent: agent)
            let machine = VZVirtualMachine(configuration: config)
            machine.delegate = self
            self.vm = machine
            controller?.vmView.virtualMachine = machine
            machine.start { [weak self] result in
                if case .failure(let error) = result {
                    NSLog("VM restart failed: \(error)")
                    return
                }
                DispatchQueue.main.async {
                    guard let self = self, let vm = self.vm else { return }
                    self.balloonController = BalloonController(vm: vm, ceiling: Config.memorySize)
                    self.balloonController?.start()
                    do { try self.guestAgent?.start() }
                    catch { NSLog("GuestAgentBridge restart failed: \(error)") }
                }
            }
        } catch {
            NSLog("VM restart config error: \(error)")
        }
    }

    private func installReactivationWatchdog() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { _ in
            NSApp.activate(ignoringOtherApps: true)
        }
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            self.controller?.window.orderFrontRegardless()
        }
    }

    private func runFirstBootSetupIfNeeded(bundle: VMBundle) throws {
        guard bundle.isFirstRun else { return }
        NSLog("First-run setup: nvram missing.")

        try bundle.ensureBlankDiskImage()

        if !FileManager.default.fileExists(atPath: bundle.installerISO.path) {
            guard let picked = promptForInstallerISO() else {
                throw NSError(domain: "MaixKiosk", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "First-run setup cancelled: no installer ISO selected."
                ])
            }
            NSLog("Copying installer ISO from \(picked.path)")
            try bundle.importInstallerISO(from: picked)
        }
    }

    private func promptForInstallerISO() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Fedora installer ISO"
        panel.message = "First boot: pick the installer ISO. It will be copied into ~/MaixVM/ and used to install the guest OS."
        panel.allowedContentTypes = [UTType(filenameExtension: "iso"), UTType.diskImage].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func installEscapeMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) && event.keyCode == Config.escapeKeyCode {
                DispatchQueue.main.async { self?.handleEscape() }
            }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) && event.keyCode == Config.escapeKeyCode {
                handler(event)
                return nil
            }
            return event
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    private func handleEscape() {
        let alert = NSAlert()
        alert.messageText = "Maintenance"
        alert.informativeText = "Exit kiosk and stop the VM?"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Exit")
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return }
        vm?.stop { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Kiosk failed to start"
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
