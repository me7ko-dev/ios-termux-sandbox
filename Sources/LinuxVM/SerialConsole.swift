import Foundation
import Network

/// TCP client for QEMU's serial chardev (`-chardev socket,...,server=on`)
/// on the loopback interface. Shows kernel/systemd boot output and acts as
/// the fallback terminal (auto-logged-in getty on ttyAMA0) when SSH isn't
/// up yet.
final class SerialConsole: @unchecked Sendable {
    var onData: ((Data) -> Void)?
    var onConnected: (() -> Void)?

    private let port: UInt16
    private let queue = DispatchQueue(label: "LinuxVM.serial")
    private var connection: NWConnection?
    private var stopped = false

    init(port: UInt16) {
        self.port = port
    }

    /// QEMU opens the listening socket during qemu_init, a moment after its
    /// thread starts — so keep retrying until it accepts.
    func connect() {
        queue.async { self.attempt() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
        }
    }

    func send(_ data: Data) {
        queue.async {
            self.connection?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func attempt() {
        guard !stopped else { return }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onConnected?()
                self.receive(on: connection)
            case .failed, .waiting:
                connection.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.5) { self.attempt() }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onData?(data)
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }
}
