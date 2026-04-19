import Cocoa
import Virtualization

final class KioskContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

final class KioskNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class KioskWindowController {
    let window: NSWindow
    let contentView: KioskContentView
    let vmView: VZVirtualMachineView

    init(vm: VZVirtualMachine) {
        let screen = NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let windowFrame: NSRect
        let styleMask: NSWindow.StyleMask
        let level: NSWindow.Level

        if Config.kioskMode {
            windowFrame = screenFrame
            styleMask = [.borderless]
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        } else {
            let w: CGFloat = min(1600, screenFrame.width * 0.75)
            let h: CGFloat = min(1000, screenFrame.height * 0.75)
            windowFrame = NSRect(
                x: screenFrame.midX - w / 2,
                y: screenFrame.midY - h / 2,
                width: w, height: h
            )
            styleMask = [.titled, .closable, .miniaturizable, .resizable]
            level = .normal
        }

        let win: NSWindow = Config.kioskMode
            ? KioskNSWindow(contentRect: windowFrame, styleMask: styleMask, backing: .buffered, defer: false)
            : NSWindow(contentRect: windowFrame, styleMask: styleMask, backing: .buffered, defer: false)
        win.level = level
        win.title = "Maix"
        win.backgroundColor = .black
        win.isOpaque = true
        if Config.kioskMode {
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            win.isMovable = false
            win.hasShadow = false
        }

        let content = KioskContentView(frame: windowFrame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        win.contentView = content

        let vz = VZVirtualMachineView(frame: content.bounds)
        vz.autoresizingMask = [.width, .height]
        vz.virtualMachine = vm
        vz.capturesSystemKeys = Config.kioskMode
        if #available(macOS 14.0, *) {
            vz.automaticallyReconfiguresDisplay = true
        }
        content.addSubview(vz)

        self.window = win
        self.contentView = content
        self.vmView = vz
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(vmView)
    }
}
