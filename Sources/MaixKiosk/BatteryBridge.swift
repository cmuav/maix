import Foundation
import IOKit.ps
import Darwin

/// Streams macOS power-source state to the guest over a qemu virtio-serial
/// unix socket. Event-driven: the host is silent between state changes.
///
/// Wire format: one JSON object per line.
///   {"pct":75,"state":"charging","on_ac":true,"ttl_min":180}
/// `state` is one of "charging", "discharging", "full", "not_charging".
/// `ttl_min` is remaining minutes (to empty when discharging, to full when
/// charging); -1 when the system hasn't computed one yet.
///
/// Guest-side daemon in provision-battery-guest.sh writes these into
/// /sys/module/test_power/parameters/* so upower/GNOME surface a native
/// battery indicator.
final class BatteryBridge {
    private let socketPath: String
    private let q = DispatchQueue(label: "maix.battery", qos: .utility)
    private var fd: Int32 = -1
    private var connectTimer: DispatchSourceTimer?
    private var pushTimer: DispatchSourceTimer?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        q.async { [weak self] in
            self?.connectLoop()
            self?.startPushTimer()
        }
    }

    func stop() {
        q.async { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd); self?.fd = -1 }
            self?.connectTimer?.cancel(); self?.connectTimer = nil
            self?.pushTimer?.cancel(); self?.pushTimer = nil
        }
    }

    private func startPushTimer() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.readAndPush() }
        t.resume()
        pushTimer = t
    }

    // MARK: - Socket plumbing

    private func connectLoop() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tryConnect() }
        t.resume()
        connectTimer = t
    }

    private func tryConnect() {
        guard fd < 0,
              FileManager.default.fileExists(atPath: socketPath),
              let newFD = Self.connectUnixSocket(path: socketPath)
        else { return }
        fd = newFD
        connectTimer?.cancel(); connectTimer = nil
        NSLog("BatteryBridge: connected to \(socketPath)")
        // Seed the guest with the current state immediately; otherwise it'd
        // stay at test_power's defaults until the next power-source event.
        readAndPush()
    }

    private static func connectUnixSocket(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }

    // MARK: - Push

    private func readAndPush() {
        guard fd >= 0 else { return }
        guard let line = currentStateJSON() else { return }
        writeLine(line)
    }

    private func currentStateJSON() -> String? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                as? [CFTypeRef] else { return nil }
        for entry in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, entry)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            let pct = (desc[kIOPSCurrentCapacityKey] as? Int) ?? -1
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let srcState = (desc[kIOPSPowerSourceStateKey] as? String) ?? ""
            let onAC = srcState == kIOPSACPowerValue
            let isFull = (desc[kIOPSIsChargedKey] as? Bool) ?? false

            let state: String
            if isFull { state = "full" }
            else if isCharging { state = "charging" }
            else if onAC { state = "not_charging" }
            else { state = "discharging" }

            let ttl: Int = {
                if isCharging, let m = desc[kIOPSTimeToFullChargeKey] as? Int, m > 0 { return m }
                if !isCharging, let m = desc[kIOPSTimeToEmptyKey] as? Int, m > 0 { return m }
                return -1
            }()

            let obj: [String: Any] = [
                "pct": pct,
                "state": state,
                "on_ac": onAC,
                "ttl_min": ttl,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
               let s = String(data: data, encoding: .utf8) {
                return s + "\n"
            }
            return nil
        }
        return nil
    }

    // MARK: - Writes

    private func writeLine(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < buf.count {
                let w = write(fd, base + written, buf.count - written)
                if w <= 0 {
                    if errno == EPIPE || errno == ECONNRESET {
                        NSLog("BatteryBridge: socket closed; reconnecting.")
                        close(fd); fd = -1
                        connectLoop()
                        return
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK { usleep(500); continue }
                    NSLog("BatteryBridge: write error \(errno)")
                    return
                }
                written += w
            }
        }
    }
}
