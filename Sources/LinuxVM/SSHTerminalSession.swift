import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Interactive login shell in the guest over SSH, with a real PTY: correct
/// window size and resize events (vim, htop, tmux work properly), Ctrl-C
/// handled by the guest's line discipline — none of which a serial line can
/// carry. Connects to QEMU's loopback port forward to the guest's sshd.
final class SSHTerminalSession: @unchecked Sendable {
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let port: Int
    private let username: String
    private let password: String
    private var writer: TTYStdinWriter?
    private var client: SSHClient?
    private var task: Task<Void, Never>?
    private var pendingSize: (cols: Int, rows: Int)

    init(port: Int, username: String, password: String, cols: Int, rows: Int) {
        self.port = port
        self.username = username
        self.password = password
        self.pendingSize = (cols, rows)
    }

    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
                self.onClose?(nil)
            } catch {
                self.onClose?(error)
            }
        }
    }

    private func run() async throws {
        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            // Loopback-only port forward into our own VM, whose host key is
            // generated on its first boot — nothing to pin it against.
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        self.client = client
        // The guest has no RTC driver and its clock stops while iOS has
        // the app suspended; bring it back to the phone's time on every
        // connect (passwordless sudo is set up by the seed ISO).
        _ = try? await client.executeCommand("sudo -n date -u -s @\(Int(Date().timeIntervalSince1970)) >/dev/null 2>&1")
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: pendingSize.cols,
            terminalRowHeight: pendingSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )
        try await client.withPTY(request) { inbound, outbound in
            self.writer = outbound
            for try await output in inbound {
                switch output {
                case .stdout(let buffer), .stderr(let buffer):
                    self.onData?(Data(buffer.readableBytesView))
                }
            }
        }
        writer = nil
        try? await client.close()
    }

    func send(_ data: Data) {
        guard let writer else { return }
        Task {
            try? await writer.write(ByteBuffer(bytes: data))
        }
    }

    func resize(cols: Int, rows: Int) {
        pendingSize = (cols, rows)
        guard let writer else { return }
        Task {
            try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    func stop() {
        task?.cancel()
        let client = client
        Task { try? await client?.close() }
    }
}
