import Foundation
import AppKit

/// Builds a qemu-system-aarch64 argv for a Linux guest on Apple Silicon,
/// using UTM's vendored qemu (GL via virglrenderer, display via SPICE).
///
/// Layout within Maix.app:
///   Contents/MacOS/maix-qemu-launcher
///   Contents/MacOS/MaixKiosk
///   Contents/Frameworks/qemu-aarch64-softmmu.framework/...
///   Contents/Frameworks/<supporting frameworks>
///   Contents/Resources/qemu/edk2-aarch64-code.fd
///   Contents/Resources/qemu/edk2-arm-vars.fd
///   Contents/Resources/qemu/efi-virtio.rom
///   Contents/Resources/qemu/keymaps/...
enum QEMUArgs {
    /// How many concurrent SPICE USB-redir channels to provision. Each slot
    /// can hold one attached host device.
    static let usbRedirSlotCount = 4

    struct Paths {
        let launcher: URL
        let qemuDylib: URL
        let biosDir: URL
        let edk2Code: URL
        let edk2VarsTemplate: URL
    }

    /// Parse `VENDOR:PRODUCT   optional label` lines. Skips blanks and #-comments.
    static func parseUSBConfig(url: URL) -> [(Int, Int, String)] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(Int, Int, String)] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hashIdx = line.firstIndex(of: "#") {
                line = String(line[..<hashIdx])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let idPart = parts.first else { continue }
            let ids = idPart.split(separator: ":").map(String.init)
            guard ids.count == 2,
                  let vid = Int(ids[0], radix: 16),
                  let pid = Int(ids[1], radix: 16) else {
                NSLog("usb.conf: skipping malformed line \(rawLine)")
                continue
            }
            let label = parts.dropFirst().joined(separator: " ")
            out.append((vid, pid, label))
        }
        return out
    }

    static func primaryScreenPixels() -> (Int, Int) {
        guard let s = NSScreen.main else { return (1920, 1200) }
        let scale = s.backingScaleFactor
        return (Int(s.frame.width * scale), Int(s.frame.height * scale))
    }

    static func resolvePaths() -> Paths? {
        let exec = Bundle.main.executableURL!.deletingLastPathComponent()   // Contents/MacOS
        let contents = exec.deletingLastPathComponent()                     // Contents
        let launcher = exec.appendingPathComponent("maix-qemu-launcher")
        let qemu = contents
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("qemu-aarch64-softmmu.framework")
            .appendingPathComponent("qemu-aarch64-softmmu")
        let biosDir = contents.appendingPathComponent("Resources/qemu")
        let code = biosDir.appendingPathComponent("edk2-aarch64-code.fd")
        let vars = biosDir.appendingPathComponent("edk2-arm-vars.fd")
        for url in [launcher, qemu, code, vars] {
            if !FileManager.default.fileExists(atPath: url.path) {
                NSLog("QEMU path missing: \(url.path)")
                return nil
            }
        }
        return Paths(launcher: launcher, qemuDylib: qemu, biosDir: biosDir,
                     edk2Code: code, edk2VarsTemplate: vars)
    }

    static func build(bundle: VMBundle, paths: Paths) -> [String] {
        var a: [String] = []

        a += ["-L", paths.biosDir.path]
        a += ["-name", "Maix"]
        a += ["-machine", "virt,highmem=on,gic-version=3"]
        a += ["-cpu", "host"]
        a += ["-accel", "hvf"]
        a += ["-smp", "cpus=\(Config.cpuCount)"]
        a += ["-m", "\(Config.memorySizeMiB)"]

        // EFI firmware (code) + persistent NVRAM (vars)
        a += ["-drive",
              "if=pflash,format=raw,unit=0,readonly=on,file=\(paths.edk2Code.path)"]
        a += ["-drive",
              "if=pflash,format=raw,unit=1,file=\(bundle.efiVars.path)"]

        // Main disk
        a += ["-drive",
              "if=virtio,format=raw,cache=writeback,aio=threads,file=\(bundle.diskImage.path)"]

        // Installer ISO (first boot)
        if FileManager.default.fileExists(atPath: bundle.installerISO.path) {
            a += ["-drive",
                  "if=virtio,format=raw,media=cdrom,readonly=on,file=\(bundle.installerISO.path)"]
        }

        // Network (user-mode for now; bridged/vmnet requires entitlement or
        // sudo). hostfwd maps mbn.local:2222 -> guest:22 for debugging.
        a += ["-netdev", "user,id=net0,hostfwd=tcp::2222-:22"]
        a += ["-device", "virtio-net-pci,netdev=net0"]

        // USB controller + input
        a += ["-device", "qemu-xhci,id=xhci"]
        a += ["-device", "usb-kbd,bus=xhci.0"]
        a += ["-device", "usb-tablet,bus=xhci.0"]

        // SPICE USB redirection slots. Host-side CSUSBManager claims devices
        // via libusb and tunnels URBs over these chardevs. One device per slot.
        for i in 0..<usbRedirSlotCount {
            a += ["-chardev", "spicevmc,name=usbredir,id=usbredirchardev\(i)"]
            a += ["-device", "usb-redir,chardev=usbredirchardev\(i),id=usbredirdev\(i),bus=xhci.0"]
        }

        // Graphics: virtio-gpu with GL (rendered by virglrenderer → SPICE).
        // Boot-time default mode sized to the main display's native pixels so
        // the guest framebuffer is large enough for the kiosk window before
        // vdagent negotiates a dynamic resize.
        let (xres, yres) = primaryScreenPixels()
        a += ["-device", "virtio-gpu-gl-pci,xres=\(xres),yres=\(yres)"]

        // RTC / entropy / balloon
        a += ["-rtc", "base=utc,clock=host"]
        a += ["-device", "virtio-rng-pci"]
        a += ["-device", "virtio-balloon-pci"]

        // Audio: qemu plays directly via CoreAudio on the host.
        // Guest sees Intel HDA (broadly-supported by Linux snd_hda_intel).
        a += ["-audiodev", "coreaudio,id=audio0"]
        a += ["-device", "intel-hda"]
        a += ["-device", "hda-duplex,audiodev=audio0"]

        // Serial log (for debugging)
        a += ["-serial", "file:\(bundle.serialLog.path)"]

        // SPICE server on a unix socket. QMP is multiplexed via spiceport.
        a += ["-spice",
              "unix=on,addr=\(bundle.spiceSocket.path),disable-ticketing=on,image-compression=off,playback-compression=off,streaming-video=off,gl=on"]
        a += ["-chardev", "spiceport,name=org.qemu.monitor.qmp.0,id=qmp"]
        a += ["-mon", "chardev=qmp,mode=control"]

        // virtio-serial-pci hosts named ports: spice-vdagent and our camera
        // side-channel.
        a += ["-device", "virtio-serial-pci"]

        // SPICE vdagent channel (clipboard / dynamic resize). Guest needs
        // `spice-vdagent` package + `spice-vdagentd.service` running.
        a += ["-chardev", "spicevmc,id=vdagent,debug=0,name=vdagent"]
        a += ["-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0"]

        // Camera side-channel. qemu listens on ~/MaixVM/camera.sock; Maix
        // connects as client and writes an MJPEG stream. Guest sees
        // /dev/virtio-ports/com.cmuav.camera — a guest-side daemon reads the
        // MJPEG stream and pipes it into v4l2loopback as /dev/video0.
        try? FileManager.default.removeItem(at: bundle.cameraSocket)
        try? FileManager.default.removeItem(at: bundle.cameraControlSocket)
        a += ["-chardev",
              "socket,id=maixcam,path=\(bundle.cameraSocket.path),server=on,wait=off"]
        a += ["-device", "virtserialport,chardev=maixcam,name=com.cmuav.camera"]
        // Control port: guest sends GO / STOP lines; host gates real capture.
        // When "stopped" the host still writes a standby frame so the guest's
        // v4l2loopback producer stays fed and consumers can STREAMON.
        a += ["-chardev",
              "socket,id=maixcamctl,path=\(bundle.cameraControlSocket.path),server=on,wait=off"]
        a += ["-device",
              "virtserialport,chardev=maixcamctl,name=com.cmuav.camera.control"]

        // No default devices / no local display — SPICE is our display.
        a += ["-nodefaults"]
        a += ["-vga", "none"]
        a += ["-display", "none"]

        return a
    }
}
