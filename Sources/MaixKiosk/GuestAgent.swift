import Foundation
import Virtualization
import Darwin

/// Exposes the standard qemu-guest-agent channel to the host.
///
/// Guest side:
///   - virtio_console driver binds the named port as /dev/virtio-ports/org.qemu.guest_agent.0
///   - qemu-guest-agent.service opens that path and speaks QMP guest-agent JSON
///
/// Host side:
///   - We create a socketpair. One end goes to VZ as the port's FileHandle.
///   - The other end we expose via a Unix domain socket at `hostSocketPath`.
///     Any process that connects to that path gets a bidirectional byte stream
///     to qga in the guest.
///
/// Usage from the host:
///   echo '{"execute":"guest-info"}' | socat - UNIX-CONNECT:/tmp/maix-qga.sock
///   echo '{"execute":"guest-ping"}'  | socat - UNIX-CONNECT:/tmp/maix-qga.sock
final class GuestAgentBridge {
    let hostSocketPath: String
    let portName = "org.qemu.guest_agent.0"

    private var vmSideFD: Int32 = -1
    private var hostSideFD: Int32 = -1
    private var listenerFD: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var guestSource: DispatchSourceRead?
    private var connectedClient: Int32 = -1
    private let q = DispatchQueue(label: "maix.guest-agent", qos: .utility)

    init(hostSocketPath: String = "/tmp/maix-qga.sock") {
        self.hostSocketPath = hostSocketPath
    }

    /// Build the VZ console port config. Returns the port, ready to be added to
    /// a VZVirtioConsoleDeviceConfiguration.
    func makePortConfiguration() throws -> VZVirtioConsolePortConfiguration {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
        }
        vmSideFD = pair[0]
        hostSideFD = pair[1]

        let port = VZVirtioConsolePortConfiguration()
        port.name = portName
        port.isConsole = false
        let vmHandle = FileHandle(fileDescriptor: vmSideFD, closeOnDealloc: true)
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: vmHandle,
            fileHandleForWriting: vmHandle
        )
        return port
    }

    /// Begin listening on the host-side Unix socket. Safe to call after VM start.
    func start() throws {
        // Tear down stale socket.
        unlink(hostSocketPath)

        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard lfd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }
        listenerFD = lfd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(hostSocketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }
        guard listen(lfd, 1) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }

        let src = DispatchSource.makeReadSource(fileDescriptor: lfd, queue: q)
        src.setEventHandler { [weak self] in self?.acceptClient() }
        src.resume()
        listenerSource = src

        installGuestReader()
        NSLog("GuestAgentBridge listening at \(hostSocketPath) (port \(portName))")
    }

    func stop() {
        listenerSource?.cancel(); listenerSource = nil
        clientSource?.cancel(); clientSource = nil
        guestSource?.cancel(); guestSource = nil
        if connectedClient >= 0 { close(connectedClient); connectedClient = -1 }
        if listenerFD >= 0 { close(listenerFD); listenerFD = -1 }
        if hostSideFD >= 0 { close(hostSideFD); hostSideFD = -1 }
        unlink(hostSocketPath)
    }

    // MARK: - Plumbing

    private func acceptClient() {
        let cfd = accept(listenerFD, nil, nil)
        guard cfd >= 0 else { return }

        if connectedClient >= 0 {
            // Only one client at a time; new connection replaces the old one.
            clientSource?.cancel(); clientSource = nil
            close(connectedClient)
        }
        connectedClient = cfd
        setNonBlocking(cfd)

        let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: q)
        src.setEventHandler { [weak self] in self?.clientReadable() }
        src.setCancelHandler { close(cfd) }
        src.resume()
        clientSource = src
    }

    private func installGuestReader() {
        setNonBlocking(hostSideFD)
        let src = DispatchSource.makeReadSource(fileDescriptor: hostSideFD, queue: q)
        src.setEventHandler { [weak self] in self?.guestReadable() }
        src.resume()
        guestSource = src
    }

    private func clientReadable() {
        guard connectedClient >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(connectedClient, &buf, buf.count)
        if n <= 0 {
            clientSource?.cancel(); clientSource = nil
            close(connectedClient); connectedClient = -1
            return
        }
        writeAll(hostSideFD, buf, Int(n))
    }

    private func guestReadable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(hostSideFD, &buf, buf.count)
        if n <= 0 { return }
        if connectedClient >= 0 {
            writeAll(connectedClient, buf, Int(n))
        }
    }

    private func writeAll(_ fd: Int32, _ buf: [UInt8], _ count: Int) {
        var written = 0
        buf.withUnsafeBufferPointer { ptr in
            while written < count {
                let w = write(fd, ptr.baseAddress! + written, count - written)
                if w <= 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    break
                }
                written += w
            }
        }
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}
