import Foundation
import Virtualization

/// Drives the guest memory balloon in response to host memory pressure.
///
/// Boot the VM with a generous memorySize. When macOS signals memory pressure,
/// inflate the balloon (reducing guest-visible RAM, returning pages to the host).
/// When pressure clears, deflate (returning RAM to the guest).
///
/// Levels (fractions of the configured ceiling returned to the guest):
///   .normal   -> 100%
///   .warning  -> 75%
///   .critical -> 50%
final class BalloonController {
    private let balloon: VZVirtioTraditionalMemoryBalloonDevice
    private let ceiling: UInt64
    private var pressureSource: DispatchSourceMemoryPressure?
    private var pollTimer: DispatchSourceTimer?
    private var currentLevel: DispatchSource.MemoryPressureEvent = .normal

    init?(vm: VZVirtualMachine, ceiling: UInt64) {
        guard let device = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else {
            NSLog("Balloon: no VZVirtioTraditionalMemoryBalloonDevice on VM, controller disabled.")
            return nil
        }
        self.balloon = device
        self.ceiling = ceiling
    }

    func start() {
        balloon.targetVirtualMachineMemorySize = ceiling

        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let level = src.data
            self.apply(level: level)
        }
        src.resume()
        pressureSource = src

        // Idle nudge: even without OS pressure events, re-apply target occasionally
        // so a stale balloon setting (e.g. after guest reboot) converges.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.apply(level: self.currentLevel, reason: "periodic")
        }
        t.resume()
        pollTimer = t

        NSLog("Balloon controller started. Ceiling = \(ceiling / (1024*1024)) MiB.")
    }

    func stop() {
        pressureSource?.cancel()
        pressureSource = nil
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func apply(level: DispatchSource.MemoryPressureEvent, reason: String = "pressure") {
        currentLevel = level
        let fraction: Double
        switch level {
        case .critical: fraction = 0.50
        case .warning:  fraction = 0.75
        default:        fraction = 1.00
        }
        let mib: UInt64 = 1024 * 1024
        let target = (UInt64(Double(ceiling) * fraction) / mib) * mib
        if balloon.targetVirtualMachineMemorySize != target {
            NSLog("Balloon [\(reason)]: level=\(describe(level)), target=\(target/mib) MiB (\(Int(fraction*100))% of ceiling)")
            balloon.targetVirtualMachineMemorySize = target
        }
    }

    private func describe(_ e: DispatchSource.MemoryPressureEvent) -> String {
        if e.contains(.critical) { return "critical" }
        if e.contains(.warning)  { return "warning" }
        return "normal"
    }
}
