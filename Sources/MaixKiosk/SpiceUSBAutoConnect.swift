import Foundation
import CocoaSpice

/// Auto-redirects USB devices to the guest on attach. Uses SPICE's built-in
/// auto-connect filter, which by default claims everything except HID class
/// (so we don't steal the host's own keyboard/mouse). Additional user-listed
/// VID:PIDs in `~/MaixVM/usb.conf` act as an explicit override for devices
/// that would otherwise be filtered out (e.g. a HID device you want forwarded).
final class SpiceUSBAutoConnect: NSObject, CSUSBManagerDelegate {
    private let manager: CSUSBManager
    private var wanted: Set<Key>
    private var claimed: Set<Key> = []

    private struct Key: Hashable { let vid: Int; let pid: Int }

    init(manager: CSUSBManager, wanted: [(Int, Int)]) {
        self.manager = manager
        self.wanted = Set(wanted.map { Key(vid: $0.0, pid: $0.1) })
        super.init()
        manager.delegate = self

        // SPICE-level auto-connect. Skip HID (class 0x03) so we don't steal
        // the host's keyboard/mouse. Allow everything else: audio (0x01),
        // imaging/UVC (0x0e), mass storage (0x08), etc.
        //
        // Note: CSUSBManager.isRedirectOnConnect is buggy on this
        // spice-client-glib build — the underlying `redirect-on-connect`
        // property expects a filter string but the setter passes a gboolean,
        // crashing usbredirfilter_string_to_rules. Do not use it.
        manager.autoConnectFilter = "0x03,-1,-1,-1,0|-1,-1,-1,-1,1"
        manager.isAutoConnect = true

        // spice-client-glib evaluates auto-connect against *currently*
        // attached devices when the property flips to true, so previously
        // plugged non-HID devices get claimed without us doing anything.
        // For user-explicit VID:PIDs in usb.conf (HID overrides), we still
        // force-claim the existing set.
        for device in manager.usbDevices {
            if self.wanted.contains(key(device)) {
                tryClaim(device)
            }
        }
    }

    func updateWanted(_ list: [(Int, Int)]) {
        wanted = Set(list.map { Key(vid: $0.0, pid: $0.1) })
        for device in manager.usbDevices {
            if self.wanted.contains(key(device)) {
                tryClaim(device)
            }
        }
    }

    private func key(_ d: CSUSBDevice) -> Key {
        Key(vid: Int(d.usbVendorId), pid: Int(d.usbProductId))
    }

    private func label(_ d: CSUSBDevice) -> String {
        let v = String(format: "%04x", d.usbVendorId)
        let p = String(format: "%04x", d.usbProductId)
        let name = [d.usbManufacturerName, d.usbProductName]
            .compactMap { $0 }.joined(separator: " ")
        return "\(v):\(p) \(name)"
    }

    private func tryClaim(_ device: CSUSBDevice) {
        if manager.isUsbDeviceConnected(device) { return }
        var reason: NSString?
        guard manager.canRedirectUsbDevice(device, errorMessage: &reason) else { return }
        NSLog("USB: claiming \(label(device))")
        manager.connectUsbDevice(device) { [weak self] err in
            guard let self = self else { return }
            if let err = err {
                NSLog("USB: connect failed \(self.label(device)): \(err.localizedDescription)")
            } else {
                NSLog("USB: connected \(self.label(device))")
                self.claimed.insert(self.key(device))
            }
        }
    }

    // MARK: - CSUSBManagerDelegate

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceAttached device: CSUSBDevice) {
        NSLog("USB attached: \(label(device))")
        // isAutoConnect=true handles non-HID devices automatically. Only
        // force-claim if the user listed this specific VID:PID in usb.conf
        // (override for HID devices they want forwarded anyway).
        if wanted.contains(key(device)) {
            tryClaim(device)
        }
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceRemoved device: CSUSBDevice) {
        NSLog("USB removed: \(label(device))")
        claimed.remove(key(device))
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceError error: String, for device: CSUSBDevice) {
        NSLog("USB error \(label(device)): \(error)")
    }
}
