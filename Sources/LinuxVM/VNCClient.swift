import CommonCrypto
import CoreGraphics
import Foundation
import Network

/// Small RFB 3.8 (VNC) client for the guest's TigerVNC desktop on the
/// loopback port forward. Implements only what a local link needs:
///
/// - VNC password auth (DES challenge, CommonCrypto)
/// - 32-bit BGRX pixels, which is the in-memory layout CoreGraphics wants
/// - Raw + CopyRect encodings, DesktopSize pseudo-encoding. Compressing
///   encodings (Tight/ZRLE) would spend emulated guest CPU to save
///   bandwidth we don't need: the "network" is a memcpy inside the phone.
///
/// Framebuffer updates are requested continuously (incremental), one at a
/// time, so a slow guest is never flooded. Frames are handed out as ready
/// CGImages, built off the main thread and at most ~30 per second: every
/// frame is a full copy of the framebuffer plus a texture upload, and the
/// phone's CPU time is better spent on the emulated guest. Pointer motion
/// is thinned to the same rate — each event is work for the guest's X
/// server, and a 120 Hz touchscreen produces far more than it can use.
final class VNCClient: @unchecked Sendable {
    enum Error: Swift.Error, LocalizedError {
        case protocolViolation(String)
        case authenticationFailed(String)
        case closed

        var errorDescription: String? {
            switch self {
            case .protocolViolation(let what): return "VNC protocol error: \(what)"
            case .authenticationFailed(let why): return "VNC authentication failed: \(why)"
            case .closed: return "VNC connection closed"
            }
        }
    }

    /// Called on a background queue with the current screen, after
    /// framebuffer updates (coalesced, see `frameInterval`).
    var onFrame: ((CGImage) -> Void)?
    var onClose: ((Swift.Error?) -> Void)?

    private let port: UInt16
    private let password: String
    private let queue = DispatchQueue(label: "LinuxVM.vnc")
    private var connection: NWConnection?
    private var inbox = Data()
    private var inboxOffset = 0
    private var waiter: (count: Int, continuation: CheckedContinuation<Data, Swift.Error>)?
    private var closed = false

    private let lock = NSLock()
    private(set) var width = 0
    private(set) var height = 0
    private var framebuffer = [UInt8]()

    private static let frameInterval = DispatchTimeInterval.milliseconds(33)
    private let renderQueue = DispatchQueue(label: "LinuxVM.vnc.render", qos: .userInteractive)
    // Guarded by `lock`.
    private var frameScheduled = false
    private var lastFrame = DispatchTime(uptimeNanoseconds: 0)

    // Pointer thinning, confined to `queue`.
    private var pointerButtons: UInt8 = 0
    private var pendingMotion: (x: Int, y: Int)?
    private var motionFlushScheduled = false
    private var lastMotion = DispatchTime(uptimeNanoseconds: 0)

    init(port: UInt16, password: String) {
        self.port = port
        self.password = password
    }

    // MARK: - Public

    func start() {
        Task {
            do {
                try await self.run()
            } catch {
                self.finish(error)
            }
        }
    }

    func stop() {
        queue.async { self.finish(nil) }
    }

    /// Pointer state in framebuffer pixels. `buttons` is the RFB mask:
    /// 1 left, 2 middle, 4 right, 8/16 wheel up/down. Button changes go out
    /// at once; plain motion at most once per `frameInterval`, latest wins.
    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        queue.async {
            guard buttons == self.pointerButtons else {
                // Carries its own position, so pending motion is moot.
                self.pendingMotion = nil
                self.pointerButtons = buttons
                self.writePointer(x: x, y: y, buttons: buttons)
                return
            }
            self.pendingMotion = (x, y)
            guard !self.motionFlushScheduled else { return }
            self.motionFlushScheduled = true
            self.queue.asyncAfter(deadline: max(DispatchTime.now(), self.lastMotion + Self.frameInterval)) {
                self.motionFlushScheduled = false
                guard let motion = self.pendingMotion else { return }
                self.pendingMotion = nil
                self.lastMotion = .now()
                self.writePointer(x: motion.x, y: motion.y, buttons: self.pointerButtons)
            }
        }
    }

    private func writePointer(x: Int, y: Int, buttons: UInt8) {
        lock.lock()
        let (width, height) = (self.width, self.height)
        lock.unlock()
        var message = Data([5, buttons])
        message.append(be16(clamp(x, width)))
        message.append(be16(clamp(y, height)))
        connection?.send(content: message, completion: .contentProcessed { _ in })
    }

    func sendKey(_ keysym: UInt32, down: Bool) {
        var message = Data([4, down ? 1 : 0, 0, 0])
        message.append(be32(keysym))
        send(message)
    }

    func tapKey(_ keysym: UInt32) {
        sendKey(keysym, down: true)
        sendKey(keysym, down: false)
    }

    // MARK: - Protocol

    private func run() async throws {
        try await open()

        let version = try await read(12)
        guard version.starts(with: Data("RFB 003.".utf8)) else {
            throw Error.protocolViolation("not an RFB server")
        }
        send(Data("RFB 003.008\n".utf8))

        let typeCount = Int(try await read(1)[0])
        if typeCount == 0 {
            throw Error.authenticationFailed(try await readReason())
        }
        let types = [UInt8](try await read(typeCount))
        if types.contains(2) {
            send(Data([2]))
            let challenge = try await read(16)
            send(try Self.vncAuthResponse(challenge: challenge, password: password))
        } else if types.contains(1) {
            send(Data([1]))
        } else {
            throw Error.authenticationFailed("no supported security type in \(types)")
        }
        let result = u32(try await read(4))
        if result != 0 {
            throw Error.authenticationFailed(try await readReason())
        }

        send(Data([1])) // ClientInit: shared session
        let serverInit = try await read(24)
        let nameLength = Int(u32(serverInit.subdata(in: 20..<24)))
        _ = try await read(nameLength)
        resize(width: Int(u16(serverInit.subdata(in: 0..<2))), height: Int(u16(serverInit.subdata(in: 2..<4))))

        // SetPixelFormat: 32 bpp, depth 24, little endian, true colour,
        // 255 max per channel, R<<16 G<<8 B<<0 => bytes B,G,R,X in memory.
        send(Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]))
        // SetEncodings: CopyRect(1), Raw(0), DesktopSize(-223)
        var encodings = Data([2, 0])
        encodings.append(be16(3))
        encodings.append(be32(1))
        encodings.append(be32(0))
        encodings.append(be32(UInt32(bitPattern: -223)))
        send(encodings)

        requestUpdate(incremental: false)
        while true {
            let type = try await read(1)[0]
            switch type {
            case 0:
                try await readFramebufferUpdate()
                requestUpdate(incremental: true)
            case 1: // SetColourMapEntries (unused with true colour)
                let header = try await read(5)
                _ = try await read(Int(u16(header.subdata(in: 3..<5))) * 6)
            case 2: // Bell
                break
            case 3: // ServerCutText
                let header = try await read(7)
                _ = try await read(Int(u32(header.subdata(in: 3..<7))))
            default:
                throw Error.protocolViolation("unknown server message \(type)")
            }
        }
    }

    private func readFramebufferUpdate() async throws {
        let header = try await read(3)
        let rectangles = Int(u16(header.subdata(in: 1..<3)))
        for _ in 0..<rectangles {
            let rect = try await read(12)
            let x = Int(u16(rect.subdata(in: 0..<2)))
            let y = Int(u16(rect.subdata(in: 2..<4)))
            let w = Int(u16(rect.subdata(in: 4..<6)))
            let h = Int(u16(rect.subdata(in: 6..<8)))
            let encoding = Int32(bitPattern: u32(rect.subdata(in: 8..<12)))
            switch encoding {
            case 0:
                let pixels = try await read(w * h * 4)
                blit(pixels, x: x, y: y, w: w, h: h)
            case 1:
                let source = try await read(4)
                copyRect(fromX: Int(u16(source.subdata(in: 0..<2))), fromY: Int(u16(source.subdata(in: 2..<4))),
                         x: x, y: y, w: w, h: h)
            case -223:
                resize(width: w, height: h)
            default:
                throw Error.protocolViolation("unexpected encoding \(encoding)")
            }
        }
        frameChanged()
    }

    private func requestUpdate(incremental: Bool) {
        var message = Data([3, incremental ? 1 : 0])
        message.append(be16(0))
        message.append(be16(0))
        message.append(be16(width))
        message.append(be16(height))
        send(message)
    }

    // MARK: - Framebuffer

    /// Schedules one frame for the render queue, no sooner than
    /// `frameInterval` after the previous one; updates arriving meanwhile
    /// are folded into it.
    private func frameChanged() {
        lock.lock()
        defer { lock.unlock() }
        guard !frameScheduled else { return }
        frameScheduled = true
        renderQueue.asyncAfter(deadline: max(DispatchTime.now(), lastFrame + Self.frameInterval)) { [weak self] in
            self?.renderFrame()
        }
    }

    private func renderFrame() {
        lock.lock()
        frameScheduled = false
        lastFrame = .now()
        let image = Self.makeImage(framebuffer, width: width, height: height)
        lock.unlock()
        if let image { onFrame?(image) }
    }

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private func resize(width: Int, height: Int) {
        lock.lock()
        self.width = width
        self.height = height
        framebuffer = [UInt8](repeating: 0, count: width * height * 4)
        lock.unlock()
    }

    private func blit(_ pixels: Data, x: Int, y: Int, w: Int, h: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard x + w <= width, y + h <= height else { return }
        let stride = width * 4
        pixels.withUnsafeBytes { source in
            framebuffer.withUnsafeMutableBytes { destination in
                for row in 0..<h {
                    let from = source.baseAddress! + row * w * 4
                    let to = destination.baseAddress! + (y + row) * stride + x * 4
                    to.copyMemory(from: from, byteCount: w * 4)
                }
            }
        }
    }

    private func copyRect(fromX: Int, fromY: Int, x: Int, y: Int, w: Int, h: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard fromX + w <= width, fromY + h <= height, x + w <= width, y + h <= height else { return }
        let stride = width * 4
        let rows = fromY < y ? Array((0..<h).reversed()) : Array(0..<h)
        framebuffer.withUnsafeMutableBytes { buffer in
            for row in rows {
                memmove(buffer.baseAddress! + (y + row) * stride + x * 4,
                        buffer.baseAddress! + (fromY + row) * stride + fromX * 4,
                        w * 4)
            }
        }
    }

    // MARK: - Auth

    /// VNC authentication: DES-encrypt the 16-byte challenge with the
    /// password (truncated/zero-padded to 8 bytes) as key, each key byte's
    /// bits mirrored — a quirk of the original VNC implementation.
    static func vncAuthResponse(challenge: Data, password: String) throws -> Data {
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.prefix(8).enumerated() {
            var mirrored: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 {
                mirrored |= 1 << (7 - bit)
            }
            key[index] = mirrored
        }
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let input = [UInt8](challenge)
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, kCCKeySizeDES, nil, input, 16, &output, 16, &moved)
        guard status == kCCSuccess, moved == 16 else {
            throw Error.authenticationFailed("DES failed (\(status))")
        }
        return Data(output)
    }

    private func readReason() async throws -> String {
        let length = Int(u32(try await read(4)))
        return String(decoding: try await read(length), as: UTF8.self)
    }

    // MARK: - Transport

    private func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready where !once.done:
                    once.done = true
                    continuation.resume()
                case .failed(let error) where !once.done, .waiting(let error) where !once.done:
                    once.done = true
                    connection.cancel()
                    continuation.resume(throwing: error)
                case .failed, .cancelled:
                    self.finish(Error.closed)
                default:
                    break
                }
            }
            self.connection = connection
            connection.start(queue: queue)
        }
        queue.async { self.receiveLoop() }
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.inbox.append(data) }
            self.deliver()
            if isComplete || error != nil {
                self.finish(error ?? Error.closed)
                return
            }
            self.receiveLoop()
        }
    }

    /// Reads exactly `count` bytes.
    private func read(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if self.closed {
                    continuation.resume(throwing: Error.closed)
                    return
                }
                self.waiter = (count, continuation)
                self.deliver()
            }
        }
    }

    private func deliver() {
        guard let waiter, inbox.count - inboxOffset >= waiter.count else { return }
        self.waiter = nil
        let start = inbox.startIndex + inboxOffset
        let chunk = Data(inbox[start..<start + waiter.count])
        inboxOffset += waiter.count
        // Compact only once consumed bytes dominate, so small header reads
        // don't copy megabytes of pending pixel data each time.
        if inboxOffset >= 1 << 16, inboxOffset * 2 >= inbox.count {
            inbox = Data(inbox[(inbox.startIndex + inboxOffset)...])
            inboxOffset = 0
        }
        waiter.continuation.resume(returning: chunk)
    }

    private func send(_ data: Data) {
        queue.async { self.connection?.send(content: data, completion: .contentProcessed { _ in }) }
    }

    private func finish(_ error: Swift.Error?) {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        waiter?.continuation.resume(throwing: error ?? Error.closed)
        waiter = nil
        onClose?(error)
    }

    // MARK: - Bytes

    private func clamp(_ value: Int, _ limit: Int) -> Int { max(0, min(value, max(0, limit - 1))) }
    private func be16(_ value: Int) -> Data { Data([UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
    private func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private func u16(_ data: Data) -> UInt16 { data.reduce(0) { $0 << 8 | UInt16($1) } }
    private func u32(_ data: Data) -> UInt32 { data.reduce(0) { $0 << 8 | UInt32($1) } }
}
