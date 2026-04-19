import Foundation
import AVFoundation
import CoreImage
import VideoToolbox
import Accelerate
import AppKit
import Darwin

/// Streams raw UYVY422 frames at a fixed resolution/framerate to a qemu
/// virtio-serial unix socket. No JPEG: host encoding and guest decoding are
/// eliminated, which removes ~1 frame of latency each way.
///
/// Two modes:
///   * idle: streams a pre-built static UYVY frame at the target framerate so
///     v4l2loopback's producer stays fed and consumers can always STREAMON.
///     Real camera isn't opened; LED off.
///   * live: AVCaptureSession at target res/fps. Pixel buffers come out in
///     UYVY natively (no conversion).
///
/// Guest ffmpeg reads rawvideo and writes to /dev/video0 with one pix-fmt
/// conversion (UYVY → YUV420p). No JPEG decode.
final class CameraBridge: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let dataSocketPath: String
    private let controlSocketPath: String
    private let q = DispatchQueue(label: "maix.camera", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var dataFD: Int32 = -1
    private var controlFD: Int32 = -1
    private var controlBuffer = Data()
    private var connectTimer: DispatchSourceTimer?
    private var controlSource: DispatchSourceRead?
    private var idleTimer: DispatchSourceTimer?
    private var idleFrame: Data = Data()
    private var mode: Mode = .idle
    private var cameraIndex: Int = 0
    private var xferSession: VTPixelTransferSession?
    private var outPool: CVPixelBufferPool?

    private enum Mode { case idle, live }

    // Keep in sync with provision-camera-guest.sh and Info.plist for the
    // advertised /dev/video0 format. If you change these, update the guest
    // supervisor's ffmpeg args too.
    static let captureWidth  = 1280
    static let captureHeight = 720
    static let targetFPS: Int32 = 30

    init(dataSocketPath: String, controlSocketPath: String) {
        self.dataSocketPath = dataSocketPath
        self.controlSocketPath = controlSocketPath
    }

    func start() {
        q.async { [weak self] in
            self?.idleFrame = Self.makeStandbyUYVY(
                width: Self.captureWidth, height: Self.captureHeight)
            self?.connectLoop()
        }
    }

    func stop() {
        q.async { [weak self] in
            self?.stopCapture()
            self?.stopIdleSender()
            if let fd = self?.dataFD, fd >= 0 { close(fd); self?.dataFD = -1 }
            if let fd = self?.controlFD, fd >= 0 { close(fd); self?.controlFD = -1 }
            self?.connectTimer?.cancel(); self?.connectTimer = nil
            self?.controlSource?.cancel(); self?.controlSource = nil
        }
    }

    // MARK: - Socket wiring

    private func connectLoop() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tryConnect() }
        t.resume()
        connectTimer = t
    }

    private func tryConnect() {
        if dataFD < 0,
           FileManager.default.fileExists(atPath: dataSocketPath),
           let fd = Self.connectUnixSocket(path: dataSocketPath) {
            dataFD = fd
            NSLog("CameraBridge: data port connected")
            startIdleSender()
        }
        if controlFD < 0,
           FileManager.default.fileExists(atPath: controlSocketPath),
           let fd = Self.connectUnixSocket(path: controlSocketPath) {
            controlFD = fd
            Self.setNonBlocking(fd)
            installControlReader(fd: fd)
            NSLog("CameraBridge: control port connected")
        }
        if dataFD >= 0 && controlFD >= 0 {
            connectTimer?.cancel(); connectTimer = nil
        }
    }

    private static func connectUnixSocket(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
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

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    // MARK: - Control channel

    private func installControlReader(fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
        src.setEventHandler { [weak self] in self?.drainControl() }
        src.resume()
        controlSource = src
    }

    private func drainControl() {
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let n = read(controlFD, &buf, buf.count)
            if n <= 0 { break }
            controlBuffer.append(contentsOf: buf.prefix(n))
        }
        while let nl = controlBuffer.firstIndex(of: 0x0A) {
            let line = controlBuffer.subdata(in: 0..<nl)
            controlBuffer.removeSubrange(0...nl)
            if let cmd = String(data: line, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) {
                handleCommand(cmd)
            }
        }
    }

    private func handleCommand(_ cmd: String) {
        switch cmd.uppercased() {
        case "GO":   switchToLive()
        case "STOP": switchToIdle()
        case "NEXT": cycleCamera()
        default:     NSLog("CameraBridge: unknown control \(cmd)")
        }
    }

    private func cycleCamera() {
        let devices = availableCameraDevices()
        guard !devices.isEmpty else {
            NSLog("CameraBridge: NEXT requested but no cameras available")
            return
        }
        cameraIndex = (cameraIndex + 1) % devices.count
        NSLog("CameraBridge: NEXT → \(devices[cameraIndex].localizedName) (index \(cameraIndex))")
        if mode == .live {
            stopCapture()
            startCapture()
        }
    }

    private func availableCameraDevices() -> [AVCaptureDevice] {
        // macOS exposes Continuity Camera as a single AVCaptureDevice plus
        // a separate Desk View device. Switching between the iPhone's lenses
        // (wide / ultra-wide / front) is iOS-side — do it from Control
        // Center on the phone. The iOS-only DeviceType values
        // (builtInUltraWideCamera, etc.) are not available on macOS.
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
        ]
        if #available(macOS 13.0, *) {
            types.append(.deskViewCamera)
        }
        if #available(macOS 14.0, *) {
            types.append(.continuityCamera)
        }
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices

        var seen = Set<String>()
        return discovered.filter { seen.insert($0.uniqueID).inserted }
    }

    // MARK: - Mode switching

    private func switchToLive() {
        guard mode != .live else { return }
        NSLog("CameraBridge: switching to live")
        stopIdleSender()
        startCapture()
        mode = .live
    }

    private func switchToIdle() {
        guard mode != .idle else { return }
        NSLog("CameraBridge: switching to idle")
        stopCapture()
        startIdleSender()
        mode = .idle
    }

    // MARK: - Idle UYVY stream

    private func startIdleSender() {
        stopIdleSender()
        guard dataFD >= 0 else { return }
        let interval = 1.0 / Double(Self.targetFPS)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.writeBytes(self.idleFrame)
        }
        t.resume()
        idleTimer = t
    }

    private func stopIdleSender() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// Solid dark-gray UYVY frame (byte order U Y V Y per 2 pixels).
    /// Values are in BT.601 video range.
    private static func makeStandbyUYVY(width: Int, height: Int) -> Data {
        var d = Data(count: width * height * 2)
        let y: UInt8 = 24    // dark gray luma (video range, near black)
        let uv: UInt8 = 128  // neutral chroma
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < p.count {
                p[i] = uv; p[i+1] = y; p[i+2] = uv; p[i+3] = y
                i += 4
            }
        }
        return d
    }

    // MARK: - Live capture

    private func startCapture() {
        guard session == nil else { return }
        guard let device = bestCameraDevice() else {
            NSLog("CameraBridge: no camera available"); return
        }
        let session = AVCaptureSession()
        let preset: AVCaptureSession.Preset =
            session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        session.sessionPreset = preset

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            try configureActiveFormat(on: device)
        } catch {
            NSLog("CameraBridge: input error: \(error)"); return
        }

        let output = AVCaptureVideoDataOutput()
        // UYVY ('2vuy') — native camera format, zero software conversion.
        // '2vuy' = packed UYVY, video-range BT.601 Y'CbCr (16..235/240). Ask
        // AVFoundation for UYVY at the camera's native resolution; we resize
        // to (captureWidth, captureHeight) ourselves via VTPixelTransferSession
        // so that every frame fed into v4l2loopback has the exact dimensions
        // the guest-side ffmpeg rawvideo demuxer expects. WidthKey/HeightKey
        // here are advisory and most Continuity / iPhone capture paths ignore
        // them, which produces a tile-pattern garbage frame in the guest.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_422YpCbCr8,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: q)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video),
           conn.isVideoMinFrameDurationSupported {
            conn.videoMinFrameDuration = CMTime(value: 1, timescale: Self.targetFPS)
        }
        session.startRunning()
        self.session = session
        NSLog("CameraBridge: capture started (\(device.localizedName))")
    }

    private func stopCapture() {
        session?.stopRunning()
        session = nil
    }

    private func bestCameraDevice() -> AVCaptureDevice? {
        let devices = availableCameraDevices()
        if devices.isEmpty { return AVCaptureDevice.default(for: .video) }
        if cameraIndex >= devices.count { cameraIndex = 0 }
        return devices[cameraIndex]
    }

    private func configureActiveFormat(on device: AVCaptureDevice) throws {
        var best: AVCaptureDevice.Format?
        var bestScore = Double.infinity
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let dw = Int(dims.width), dh = Int(dims.height)
            let maxFPS = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            if maxFPS < Double(Self.targetFPS) { continue }
            let score = abs(Double(dw - Self.captureWidth)) + abs(Double(dh - Self.captureHeight))
            if score < bestScore { bestScore = score; best = f }
        }
        guard let chosen = best else { return }
        try device.lockForConfiguration()
        device.activeFormat = chosen
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Self.targetFPS)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Self.targetFPS)
        device.unlockForConfiguration()
    }

    // MARK: - Delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard mode == .live, dataFD >= 0,
              let inBuf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        ensurePixelTransfer()
        guard let pool = outPool, let xfer = xferSession else { return }

        var outBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf) == kCVReturnSuccess,
              let outBuf = outBuf,
              VTPixelTransferSessionTransferImage(xfer, from: inBuf, to: outBuf) == noErr
        else { return }

        CVPixelBufferLockBaseAddress(outBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outBuf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(outBuf) else { return }
        let bpr  = CVPixelBufferGetBytesPerRow(outBuf)
        let h    = CVPixelBufferGetHeight(outBuf)
        let rowBytes = Self.captureWidth * 2
        if bpr == rowBytes {
            writeBytesRaw(pointer: base.assumingMemoryBound(to: UInt8.self),
                          count: bpr * h)
        } else {
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                writeBytesRaw(pointer: p.advanced(by: y * bpr), count: rowBytes)
            }
        }
    }

    private func ensurePixelTransfer() {
        if xferSession == nil {
            var s: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s)
            if let s = s {
                // Fit the source into the target keeping aspect; any extra
                // space is filled black. Avoids subtle stretch when camera
                // aspect doesn't match 16:9.
                VTSessionSetProperty(s,
                    key: kVTPixelTransferPropertyKey_ScalingMode,
                    value: kVTScalingMode_Letterbox)
            }
            xferSession = s
        }
        if outPool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8,
                kCVPixelBufferWidthKey: Self.captureWidth,
                kCVPixelBufferHeightKey: Self.captureHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            outPool = pool
        }
    }

    // MARK: - Socket write

    private func writeBytes(_ data: Data) {
        guard dataFD >= 0 else { return }
        data.withUnsafeBytes { raw in
            if let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                writeBytesRaw(pointer: p, count: data.count)
            }
        }
    }

    private func writeBytesRaw(pointer: UnsafePointer<UInt8>, count: Int) {
        guard dataFD >= 0 else { return }
        var written = 0
        while written < count {
            let w = write(dataFD, pointer + written, count - written)
            if w <= 0 {
                if errno == EPIPE || errno == ECONNRESET {
                    NSLog("CameraBridge: data socket closed; reconnecting.")
                    close(dataFD); dataFD = -1
                    stopIdleSender()
                    connectLoop()
                    return
                }
                if errno == EAGAIN || errno == EWOULDBLOCK { usleep(500); continue }
                NSLog("CameraBridge: write error \(errno)")
                return
            }
            written += w
        }
    }
}
