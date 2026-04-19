import Cocoa
import MetalKit
import CocoaSpice
import CocoaSpiceRenderer

final class KioskNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class KioskWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let metalView: VMMetalView
    private(set) var renderer: CSMetalRenderer?
    private var currentDisplay: CSDisplay?
    private var serialConsole: SerialConsoleView?
    private var efiDisplaySize: CGSize?

    override init() {
        let screenFrame = NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let windowFrame: NSRect
        let styleMask: NSWindow.StyleMask

        if Config.kioskMode {
            windowFrame = screenFrame
            styleMask = [.borderless]
        } else {
            let w: CGFloat = min(1280, screenFrame.width * 0.75)
            let h: CGFloat = min(800, screenFrame.height * 0.75)
            windowFrame = NSRect(x: screenFrame.midX - w / 2,
                                 y: screenFrame.midY - h / 2,
                                 width: w, height: h)
            styleMask = [.titled, .closable, .miniaturizable, .resizable]
        }

        let win: NSWindow = Config.kioskMode
            ? KioskNSWindow(contentRect: windowFrame, styleMask: styleMask,
                            backing: .buffered, defer: false)
            : NSWindow(contentRect: windowFrame, styleMask: styleMask,
                       backing: .buffered, defer: false)
        win.title = "Maix"
        win.backgroundColor = .black
        win.isOpaque = true
        if Config.kioskMode {
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            win.isMovable = false
            win.hasShadow = false
        }

        let container = NSView(frame: windowFrame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizingMask = [.width, .height]
        win.contentView = container

        let mv = VMMetalView(frame: container.bounds)
        mv.autoresizingMask = [.width, .height]
        mv.device = MTLCreateSystemDefaultDevice()
        mv.preferredFramesPerSecond = 60
        mv.isHidden = true
        container.addSubview(mv)

        self.window = win
        self.metalView = mv
        super.init()
        win.delegate = self
    }

    func showSerialConsole(tailing url: URL) {
        guard let content = window.contentView else { return }
        let console = SerialConsoleView(frame: content.bounds)
        content.addSubview(console)
        console.startTailing(url)
        serialConsole = console
    }

    private func hideSerialConsole() {
        serialConsole?.stop()
        serialConsole?.removeFromSuperview()
        serialConsole = nil
        metalView.isHidden = false
    }

    func attach(display: CSDisplay) {
        if renderer == nil {
            let r = CSMetalRenderer(metalKitView: metalView)
            renderer = r
            metalView.delegate = r
        }
        if let old = currentDisplay, let r = renderer {
            old.removeRenderer(r)
        }
        if let r = renderer {
            display.addRenderer(r)
        }
        currentDisplay = display
        // Do NOT hide the console yet — EDK2 has drawn a "Display output is
        // not active" frame to the virtio-gpu framebuffer. Keep the boot log
        // visible until the guest changes resolution (Linux kernel / Plymouth
        // taking over from EFI). displayUpdated will trigger the hide.
        efiDisplaySize = display.displaySize
        rescaleToFit()
        NSLog("KioskWindow: attached to SPICE display (monitorID=\(display.monitorID) size=\(display.displaySize))")
    }

    /// Recompute viewportScale so the guest framebuffer fills the window.
    /// Also ask the SPICE agent to resize the guest (no-op if vdagent absent).
    func rescaleToFit() {
        guard let display = currentDisplay, let renderer = renderer else { return }
        let ds = display.displaySize
        guard ds.width > 0, ds.height > 0 else { return }
        let backing = window.screen?.backingScaleFactor ?? 1.0
        let content = window.contentView?.bounds.size ?? window.frame.size
        let sx = content.width  * backing / ds.width
        let sy = content.height * backing / ds.height
        renderer.viewportScale = min(sx, sy)

        // Nudge the guest to match the window. No-op pre-vdagent.
        let pixelW = content.width  * backing
        let pixelH = content.height * backing
        display.requestResolution(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
    }

    // MARK: - NSWindowDelegate

    /// Call on CSDisplay size updates. Hides the serial console once the
    /// guest OS has taken over from EFI (first resolution change post-attach).
    func handleDisplayUpdated() {
        guard let cur = currentDisplay else { return }
        if let efi = efiDisplaySize, cur.displaySize != efi {
            hideSerialConsole()
            efiDisplaySize = nil
        }
        rescaleToFit()
    }

    func windowDidResize(_ notification: Notification) {
        rescaleToFit()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        rescaleToFit()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(metalView)
    }
}
