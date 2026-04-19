# Maix

Swift host app. Virtualization.framework. Fullscreen Linux VM at login.

## Layout
- `Package.swift` — SwiftPM target (macOS 14+, arm64).
- `Sources/MaixKiosk/`
  - `main.swift` — bootstraps `NSApplication`.
  - `Config.swift` — tunables (CPU, RAM, paths, escape combo).
  - `VMBundle.swift` — `~/MaixVM/` layout (disk.img, nvram, machineIdentifier).
  - `VMFactory.swift` — builds `VZVirtualMachineConfiguration` (EFI, virtio-blk/net/gpu/input/console/rng/balloon/vsock, optional Rosetta + virtio-fs host share).
  - `KioskWindow.swift` — borderless window above main menu, `VZVirtualMachineView`, escape combo.
  - `AppDelegate.swift` — presentation lockdown, VM lifecycle, auto-restart, reactivation watchdog.
- `Info.plist`, `MaixKiosk.entitlements`, `LaunchAgent.plist`, `build.sh`.

## Provision guest disk
Build it once before first launch; this app does not install Linux.

```
mkdir -p ~/MaixVM
qemu-img create -f raw ~/MaixVM/disk.img 64G
# Boot an installer ISO with any VZ example app, or run a one-shot provisioning tool,
# then let Maix own ~/MaixVM/disk.img afterwards.
```

## Build
```
SIGN_ID="Developer ID Application: YOUR TEAM (TEAMID)" ./build.sh
```
Copy `build/MaixKiosk.app` to `/Applications/`.

## Auto-launch at login
1. Enable auto-login for the kiosk user (System Settings → Users & Groups).
2. Install the LaunchAgent:
   ```
   cp LaunchAgent.plist ~/Library/LaunchAgents/com.cmuav.maix.kiosk.plist
   launchctl load -w ~/Library/LaunchAgents/com.cmuav.maix.kiosk.plist
   ```

## Escape hatch
`Ctrl+Opt+Cmd+Escape` → maintenance prompt → quit.
Pair with SSH (key-only) on the host for remote recovery.

## Not handled here
- macOS UI lockdown profile (`.mobileconfig`).
- Disabling Dock/Finder/Spotlight agents.
- Guest OS install.
- FileVault policy.
