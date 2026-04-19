import Cocoa
import CocoaSpiceNoUsb

/// Routes input events from VMMetalView to CSInput. Minimal port of UTM's
/// display controller input path.
final class SpiceInputRouter: VMMetalViewInputDelegate {
    weak var metalView: VMMetalView?
    var input: CSInput?
    var display: CSDisplay?

    let shouldUseCmdOptForCapture: Bool = true

    func mouseMove(absolutePoint: CGPoint, buttonMask: CSInputButton) {
        // VMMetalView reports view-space points, origin bottom-left.
        // SPICE wants guest-framebuffer pixels, origin top-left.
        guard let mv = metalView else { return }
        let viewSize = mv.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let dSize: CGSize
        if let d = display, d.displaySize.width > 0, d.displaySize.height > 0 {
            dSize = d.displaySize
        } else {
            dSize = viewSize   // fallback before display info arrives
        }

        let sx = absolutePoint.x / viewSize.width * dSize.width
        let sy = (viewSize.height - absolutePoint.y) / viewSize.height * dSize.height
        let scaled = CGPoint(x: max(0, min(dSize.width,  sx)),
                             y: max(0, min(dSize.height, sy)))

        input?.sendMousePosition(buttonMask, absolutePoint: scaled,
                                 forMonitorID: display?.monitorID ?? 0)
        // SPICE's cursor channel in client mouse mode does not push moves —
        // we must set the client-side cursor position explicitly.
        display?.cursor?.move(to: scaled)
    }

    func mouseMove(relativePoint: CGPoint, buttonMask: CSInputButton) {
        input?.sendMouseMotion(buttonMask, relativePoint: relativePoint,
                               forMonitorID: display?.monitorID ?? 0)
    }

    func mouseDown(button: CSInputButton, mask: CSInputButton) {
        input?.sendMouseButton(button, mask: mask, pressed: true)
    }

    func mouseUp(button: CSInputButton, mask: CSInputButton) {
        input?.sendMouseButton(button, mask: mask, pressed: false)
    }

    func mouseScroll(dy: CGFloat, buttonMask: CSInputButton) {
        input?.sendMouseScroll(.smooth, buttonMask: buttonMask, dy: dy)
    }

    func keyDown(scanCode: Int) {
        sendKey(.press, scanCode: scanCode)
    }

    func keyUp(scanCode: Int) {
        sendKey(.release, scanCode: scanCode)
    }

    /// Translate PS/2 extended scan codes (0xE0XX) into the 0x1XX form that
    /// SPICE's 512-slot key-state table actually accepts. Non-extended codes
    /// >= 0x100 are dropped. Same trick UTM uses.
    private func sendKey(_ type: CSInputKey, scanCode: Int) {
        if (scanCode & 0xFF00) == 0xE000 {
            input?.send(type, code: Int32(0x100 | (scanCode & 0xFF)))
        } else if scanCode >= 0x100 {
            NSLog("ignored invalid scancode \(scanCode)")
        } else {
            input?.send(type, code: Int32(scanCode))
        }
    }

    func syncCapsLock(with modifier: NSEvent.ModifierFlags?) {
        guard let modifier = modifier, let input = input else { return }
        input.keyLock = modifier.contains(.capsLock) ? .caps : []
    }

    func captureMouse()  { metalView?.captureMouse() }
    func releaseMouse()  { metalView?.releaseMouse() }
    func didUseNumericPad() {}
}
