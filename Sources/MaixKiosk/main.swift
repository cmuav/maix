import Cocoa
import Virtualization

let args = CommandLine.arguments.dropFirst()
for arg in args {
    switch arg {
    case "--kiosk-mode":
        Config.kioskMode = true
    case "--trial-mode":
        Config.kioskMode = true
        Config.trialMode = true
    case "--help", "-h":
        print("""
        Maix [--kiosk-mode | --trial-mode]

          --kiosk-mode   Borderless fullscreen, disable process switching.
          --trial-mode   Kiosk mode, auto-quit after \(Int(Config.trialDurationSeconds))s.
          (default)      Windowed.
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("Unknown arg: \(arg)\n".utf8))
        exit(2)
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
