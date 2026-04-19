# Maix

A macOS kiosk host for a Linux VM. It spawns QEMU and draws the guest
framebuffer in a fullscreen NSWindow with SPICE. Intended for a dedicated
Mac running one Linux desktop at login, nothing else.

## Credits

Built on top of [UTM](https://github.com/utmapp/utm). The QEMU binary, its
dependency frameworks (glib, gstreamer, spice-client-glib, virglrenderer,
usbredir, ...), the EDK2 firmware, and the Metal SPICE renderer are all
vendored from an installed copy of `/Applications/UTM.app` at build time.
The small C launcher under `Sources/MaixLauncher/` is a verbatim port of
UTM's `QEMULauncher/Bootstrap.c`. Maix would not work without UTM's work
on getting the GL/virgl stack to build against macOS.

[CocoaSpice](https://github.com/utmapp/CocoaSpice) and
[QEMUKit](https://github.com/utmapp/QEMUKit) are fetched as regular SwiftPM
dependencies.

## What it does

- Spawns `qemu-system-aarch64` as a subprocess, with Apple Silicon HVF
  acceleration, virtio-gpu-gl-pci graphics, virtio-serial channels for
  spice-vdagent and a host-fed camera side channel, Intel HDA audio wired
  straight to CoreAudio, and SPICE USB redirection for hot-plugged devices.
- Renders the SPICE display in a Metal-backed NSView inside a borderless
  NSWindow. Keyboard and pointer events are routed through CSInput; the
  host cursor is hidden, SPICE's cursor sprite is followed.
- Tails `~/MaixVM/serial.log` to an in-window console until the guest
  kernel switches the framebuffer away from the EDK2 boot screen, then
  hands off to the live Metal view.
- Streams the Mac camera to the guest as a fake USB webcam at
  `/dev/video0`, and only engages AVCapture when something in the guest
  actually reads that device. A host-side standby frame keeps the guest's
  v4l2loopback producer fed so consumers can always `VIDIOC_STREAMON`.

## Layout

```
Sources/
  MaixKiosk/        Swift app
    main.swift            argv parsing, NSApplication boot
    AppDelegate.swift     VM lifecycle, first-boot ISO picker, escape combo,
                          trial-mode timer, auto-restart
    Config.swift          CPU/memory sizing, paths, flags
    VMBundle.swift        ~/MaixVM/ layout: disk.img, efi_vars.fd, sockets
    QEMUArgs.swift        qemu argv builder
    QEMUProcess.swift     subprocess wrapper
    KioskWindow.swift     NSWindow + VMMetalView + serial console overlay
    SpiceIO.swift         CSConnection + CSSession wrapper
    SpiceInputRouter.swift VMMetalView input -> CSInput
    SpiceUSBAutoConnect.swift  CSUSBManager auto-claim on hotplug
    CameraBridge.swift    AVCapture -> unix socket (YUYV rawvideo)
    SerialConsoleView.swift  scrolling serial log with ANSI color parser
    VMMetalView.swift     ported from UTM
    VMMetalViewInputDelegate.swift  input protocol
    KeyCodeMap.swift      ported from UTM
  MaixLauncher/     tiny C launcher that dlopen's the qemu framework
  MaixStubs/        no-op stubs for iOS-static gst plugin symbols
                    referenced by CocoaSpice on macOS

build.sh            builds everything, vendors UTM's frameworks, signs
Package.swift       SwiftPM manifest
Info.plist, MaixKiosk.entitlements, LaunchAgent.plist
```

## Dependencies

- macOS 14 or later, Apple Silicon.
- `/Applications/UTM.app` installed. `build.sh` reads the qemu framework,
  the SPICE/glib/virgl stack, and the aarch64 EDK2 firmware directly out
  of it. No download step.
- Xcode command-line tools and the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).
- An Apple Development cert in the login keychain. Free Apple ID works;
  ad-hoc signing also works but drops a couple of restricted entitlements.

## Build

```
SIGN_ID="Apple Development: name (TEAMID)" ./build.sh
```

The output is `build/MaixKiosk.app`, about 280 MB. The size is the vendored
qemu + dependency frameworks.

Run it:

```
./build/MaixKiosk.app/Contents/MacOS/MaixKiosk              # windowed
./build/MaixKiosk.app/Contents/MacOS/MaixKiosk --kiosk-mode # borderless, takes the screen
./build/MaixKiosk.app/Contents/MacOS/MaixKiosk --trial-mode # kiosk + self-exit in 90s
```

## First-boot setup

Maix does not install Linux for you. On first launch it opens an
NSOpenPanel asking for an installer ISO if one isn't already at
`~/MaixVM/installer.iso`. The app then:

- creates a blank 64 GB raw disk at `~/MaixVM/disk.img` if missing
- copies `edk2-arm-vars.fd` from the UTM firmware into
  `~/MaixVM/efi_vars.fd` (padded to 64 MiB, required by aarch64 pflash)
- boots qemu with the ISO attached, you run the distribution installer
  normally

After the install reboots, delete `~/MaixVM/installer.iso` to stop
re-booting into the installer.

## Auto-launch at login

`LaunchAgent.plist` is a template. Copy it to
`~/Library/LaunchAgents/com.cmuav.maix.kiosk.plist`, edit the executable
path, then `launchctl bootstrap gui/$(id -u) <path>`. It uses
`KeepAlive = { SuccessfulExit = false }`, so a clean guest shutdown exits
the kiosk and the agent does not respawn until next login.

Set automatic login for the kiosk user in System Settings. FileVault must
be off for auto-login to work.

## Camera side-channel

qemu exposes two virtio-serial ports to the guest:

- `/dev/virtio-ports/com.cmuav.camera` (data)
- `/dev/virtio-ports/com.cmuav.camera.control` (control)

Host-side (`CameraBridge.swift`):

- default mode sends a static YUYV 1280x720 standby frame at 30 fps
- on a `GO` line from the control port, starts an AVCaptureSession and
  pipes pixel buffers straight to the data port
- on `STOP`, tears the session down (real camera LED goes off)

Guest-side (installed by `provision-camera-guest.sh`):

- v4l2loopback module loaded with `exclusive_caps=0`, creating
  `/dev/video0` advertised as MaixCamera
- an always-on ffmpeg `-f rawvideo -pix_fmt yuyv422` producer feeds the
  loopback from the data port
- a supervisor polls `lsof /dev/video0`, subtracts the producer PID, and
  emits `GO`/`STOP` on the control port when other consumers open/close
  the device

Run the provisioning script once inside the Fedora guest:

```
sudo bash provision-camera-guest.sh
```

It installs v4l2loopback via RPM Fusion's akmod, pins kernel-devel so
future `dnf upgrade; reboot` cycles keep the module in sync, writes the
supervisor and systemd unit, and loads the module.

## USB

USB passthrough is SPICE `usb-redir`, the same thing UTM does. qemu gets
four redirection slots; `CSUSBManager.autoConnectFilter` is set to the
SPICE default (skip class 0x03 = HID, claim everything else). Plug in a
webcam or microphone and it appears in the guest within a second.

`~/MaixVM/usb.conf` is an optional override list for HID devices you
specifically want forwarded anyway. Format:

```
046d:c539   Logitech Lightspeed
```

## Exit hatch

`Cmd+Esc` pops a "Stop the VM and exit?" dialog. Confirm to quit cleanly.
In `--kiosk-mode` the window is borderless at `mainMenuWindow + 1` level
and the menu bar is hidden, so this is the only way out from the UI.
Server-side recovery: SSH to the Mac, `launchctl bootout` the agent.

The Maix binary ignores clean guest shutdowns (`exit(0)`), so `poweroff`
inside the VM also exits the kiosk.

## Not included

- Installing Linux for you.
- A `.mobileconfig` to disable macOS UI features system-wide. The
  LaunchAgent presentation lockdown is the extent of it.
- FileVault policy decisions. Auto-login and FileVault are mutually
  exclusive; Maix doesn't pick for you.
