import Foundation
import CocoaSpice
import CocoaSpiceRenderer

/// Wraps CSMain + CSConnection for a unix-socket SPICE server.
/// Pared-down port of UTM's UTMSpiceIO for our single-display use case.
final class SpiceIO: NSObject, CSConnectionDelegate {
    let socketURL: URL
    private var spice: CSMain?
    private(set) var connection: CSConnection?
    private(set) var primaryDisplay: CSDisplay?
    private(set) var primaryInput: CSInput?

    /// Called on main queue when the primary display first appears.
    var onPrimaryDisplay: ((CSDisplay) -> Void)?
    /// Called on main queue when primary input becomes available.
    var onPrimaryInput: ((CSInput) -> Void)?
    /// Called on main queue when the connection drops.
    var onDisconnect: (() -> Void)?
    /// Called on main queue on SPICE error.
    var onError: ((String) -> Void)?
    /// Called on main queue when CSDisplay.displaySize changes.
    var onDisplayUpdated: ((CSDisplay) -> Void)?
    /// Called on main queue once the guest's spice-vdagent connects.
    var onAgentConnected: (() -> Void)?

    init(socketURL: URL) {
        self.socketURL = socketURL
    }

    func start() throws {
        let spice = CSMain.shared
        self.spice = spice
        // Don't decode audio locally — we're not routing it anywhere in Phase 2b.
        setenv("SPICE_DISABLE_OPUS", "1", 1)

        // AF_UNIX sun_path is 104 bytes; chdir so we can use just the basename.
        let parent = socketURL.deletingLastPathComponent().path
        guard FileManager.default.changeCurrentDirectoryPath(parent) else {
            throw NSError(domain: "Maix", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Failed chdir to \(parent)"
            ])
        }
        guard spice.spiceStart() else {
            throw NSError(domain: "Maix", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "CSMain.spiceStart() failed"
            ])
        }

        let relative = URL(fileURLWithPath: socketURL.lastPathComponent)
        let conn = CSConnection(unixSocketFile: relative)
        conn.delegate = self
        conn.audioEnabled = false
        connection = conn
    }

    func connect() -> Bool {
        return connection?.connect() ?? false
    }

    func disconnect() {
        connection?.disconnect()
        connection = nil
    }

    // MARK: - CSConnectionDelegate

    /// Called on main queue once the SPICE main channel is open (usbManager available).
    var onConnected: ((CSConnection) -> Void)?

    func spiceConnected(_ connection: CSConnection) {
        NSLog("SPICE connected.")
        DispatchQueue.main.async { [weak self] in
            self?.onConnected?(connection)
        }
    }

    func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.primaryInput == nil {
                self.primaryInput = input
                self.onPrimaryInput?(input)
            }
        }
    }

    func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        DispatchQueue.main.async { [weak self] in
            if self?.primaryInput == input { self?.primaryInput = nil }
        }
    }

    func spiceDisconnected(_ connection: CSConnection) {
        DispatchQueue.main.async { [weak self] in
            self?.primaryDisplay = nil
            self?.primaryInput = nil
            self?.onDisconnect?()
        }
    }

    func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        NSLog("SPICE error \(code.rawValue): \(message ?? "")")
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message ?? "code=\(code.rawValue)")
        }
    }

    func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        NSLog("SPICE display created, monitorID=\(display.monitorID), primary=\(display.isPrimaryDisplay)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard display.isPrimaryDisplay else { return }
            if self.primaryDisplay == nil {
                self.primaryDisplay = display
                self.onPrimaryDisplay?(display)
            }
        }
    }

    func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        DispatchQueue.main.async { [weak self] in
            self?.onDisplayUpdated?(display)
        }
    }

    func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        DispatchQueue.main.async { [weak self] in
            if self?.primaryDisplay == display { self?.primaryDisplay = nil }
        }
    }

    func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        NSLog("SPICE agent connected, features=\(features.rawValue)")
        DispatchQueue.main.async { [weak self] in
            self?.onAgentConnected?()
        }
    }
    func spiceAgentDisconnected(_ connection: CSConnection) {}

    func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
}
