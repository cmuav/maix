import Cocoa
import Darwin

/// A scrolling monospace text view that tails a file and appends new bytes as
/// they arrive, parsing ANSI SGR color codes. Used as a pre-SPICE boot console.
final class SerialConsoleView: NSView {
    private let scroll: NSScrollView
    private let textView: NSTextView
    private var fd: Int32 = -1
    private var offset: off_t = 0
    private var timer: DispatchSourceTimer?
    private let parser = AnsiParser()

    override init(frame: NSRect) {
        scroll = NSScrollView(frame: frame)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        textView = NSTextView(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.userFixedPitchFont(ofSize: 11)
        textView.textColor = parser.defaultForeground
        textView.backgroundColor = .black
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]

        scroll.documentView = textView
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.width, .height]
        addSubview(scroll)

        appendPlain("Waiting for guest framebuffer...\n\n")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Begin tailing `url`. Polls the file every 100 ms for new bytes (the only
    /// reliable way on regular files — kqueue VNODE events aren't emitted for
    /// ordinary buffered writes by qemu's `-serial file:`).
    func startTailing(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            NSLog("SerialConsoleView: open failed \(url.path) errno=\(errno)")
            return
        }
        offset = 0

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.05, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func drain() {
        guard fd >= 0 else { return }
        // Check for new bytes by comparing file size to our cursor.
        var st = stat()
        guard fstat(fd, &st) == 0 else { return }
        if st.st_size <= offset { return }

        let remaining = Int(st.st_size - offset)
        let chunk = min(remaining, 64 * 1024)
        var buf = [UInt8](repeating: 0, count: chunk)
        lseek(fd, offset, SEEK_SET)
        let n = read(fd, &buf, chunk)
        guard n > 0 else { return }
        offset += off_t(n)

        let attr = parser.parse(buf.prefix(n))
        textView.textStorage?.append(attr)
        textView.scrollRangeToVisible(NSRange(location: textView.string.count, length: 0))
    }

    private func appendPlain(_ s: String) {
        let attr = NSAttributedString(string: s, attributes: [
            .font: textView.font ?? NSFont.userFixedPitchFont(ofSize: 11)!,
            .foregroundColor: parser.defaultForeground,
        ])
        textView.textStorage?.append(attr)
    }
}

// MARK: - ANSI SGR parser (minimal)

/// Parses the subset of ANSI escape codes the kernel + systemd emit:
/// CSI [...]m for colors/attrs. Ignores cursor-movement codes by stripping
/// them silently. Doesn't attempt full terminal emulation.
private final class AnsiParser {
    let defaultForeground: NSColor
    let defaultBackground: NSColor = .black
    private var fg: NSColor
    private var bg: NSColor
    private var bold = false
    private let font: NSFont

    init() {
        defaultForeground = NSColor(white: 0.9, alpha: 1)
        fg = defaultForeground
        bg = defaultBackground
        font = NSFont.userFixedPitchFont(ofSize: 11)!
    }

    func parse<S: Sequence>(_ bytes: S) -> NSAttributedString where S.Element == UInt8 {
        let out = NSMutableAttributedString()
        var i = 0
        let arr = Array(bytes)
        while i < arr.count {
            let b = arr[i]
            if b == 0x1B && i + 1 < arr.count && arr[i+1] == UInt8(ascii: "[") {
                // CSI sequence: ESC [ params letter
                var j = i + 2
                while j < arr.count {
                    let c = arr[j]
                    if c >= 0x40 && c <= 0x7E { break }
                    j += 1
                }
                if j < arr.count {
                    let letter = arr[j]
                    let paramsBytes = Array(arr[(i+2)..<j])
                    let params = String(bytes: paramsBytes, encoding: .ascii) ?? ""
                    if letter == UInt8(ascii: "m") {
                        applySGR(params)
                    }
                    // All other CSI (cursor movement, erase, etc.) silently ignored.
                    i = j + 1
                    continue
                }
            } else if b == 0x07 || b == 0x08 || b == 0x0D {
                // bell, backspace, CR — ignore CR since it's noisy in logs.
                i += 1
                continue
            }
            // Plain byte: append to output with current attrs.
            if let s = String(bytes: [b], encoding: .utf8) {
                out.append(NSAttributedString(string: s, attributes: attrs()))
            }
            i += 1
        }
        return out
    }

    private func attrs() -> [NSAttributedString.Key: Any] {
        var f = font
        if bold, let fm = NSFontManager.shared.font(withFamily: font.familyName ?? "Menlo",
                                                    traits: [.boldFontMask],
                                                    weight: 5,
                                                    size: font.pointSize) {
            f = fm
        }
        return [
            .font: f,
            .foregroundColor: fg,
            .backgroundColor: bg,
        ]
    }

    private func applySGR(_ paramString: String) {
        let params = paramString.isEmpty ? ["0"] : paramString.split(separator: ";").map(String.init)
        var idx = 0
        while idx < params.count {
            let p = Int(params[idx]) ?? 0
            switch p {
            case 0:
                fg = defaultForeground; bg = defaultBackground; bold = false
            case 1:
                bold = true
            case 22:
                bold = false
            case 30...37:
                fg = ansiColor(p - 30, bright: false)
            case 38:
                // 38;5;n  or 38;2;r;g;b
                if idx + 2 < params.count, params[idx+1] == "5", let n = Int(params[idx+2]) {
                    fg = palette256(n); idx += 2
                } else if idx + 4 < params.count, params[idx+1] == "2",
                          let r = Int(params[idx+2]), let g = Int(params[idx+3]), let bl = Int(params[idx+4]) {
                    fg = NSColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(bl)/255, alpha: 1)
                    idx += 4
                }
            case 39:
                fg = defaultForeground
            case 40...47:
                bg = ansiColor(p - 40, bright: false)
            case 49:
                bg = defaultBackground
            case 90...97:
                fg = ansiColor(p - 90, bright: true)
            case 100...107:
                bg = ansiColor(p - 100, bright: true)
            default:
                break
            }
            idx += 1
        }
    }

    private func ansiColor(_ n: Int, bright: Bool) -> NSColor {
        // Solarized-ish dark palette for readability on black.
        let normal: [NSColor] = [
            .init(white: 0.2, alpha: 1),                         // black
            .init(red: 0.86, green: 0.20, blue: 0.18, alpha: 1), // red
            .init(red: 0.52, green: 0.60, blue: 0.00, alpha: 1), // green
            .init(red: 0.71, green: 0.54, blue: 0.00, alpha: 1), // yellow
            .init(red: 0.15, green: 0.55, blue: 0.82, alpha: 1), // blue
            .init(red: 0.83, green: 0.21, blue: 0.51, alpha: 1), // magenta
            .init(red: 0.16, green: 0.63, blue: 0.60, alpha: 1), // cyan
            .init(white: 0.93, alpha: 1),                        // white
        ]
        let brighter: [NSColor] = [
            .init(white: 0.45, alpha: 1),
            .init(red: 1.00, green: 0.40, blue: 0.35, alpha: 1),
            .init(red: 0.72, green: 0.82, blue: 0.15, alpha: 1),
            .init(red: 0.95, green: 0.75, blue: 0.15, alpha: 1),
            .init(red: 0.40, green: 0.72, blue: 0.95, alpha: 1),
            .init(red: 0.95, green: 0.40, blue: 0.72, alpha: 1),
            .init(red: 0.35, green: 0.85, blue: 0.80, alpha: 1),
            .init(white: 1.00, alpha: 1),
        ]
        let arr = bright ? brighter : normal
        return arr[max(0, min(7, n))]
    }

    private func palette256(_ n: Int) -> NSColor {
        if n < 16 { return ansiColor(n & 7, bright: n >= 8) }
        if n >= 232 {
            let g = CGFloat(n - 232) / 23.0
            return NSColor(white: g, alpha: 1)
        }
        let c = n - 16
        let r = CGFloat((c / 36) * 51) / 255
        let g = CGFloat(((c / 6) % 6) * 51) / 255
        let b = CGFloat((c % 6) * 51) / 255
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }
}
