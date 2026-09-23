import Foundation
import Network

/// Minimal QEMU Machine Protocol client (JSON lines over TCP on loopback).
/// Used for exactly what the app needs: `stop`/`cont` when iOS moves the
/// app to and from the background, and `savevm`/`delvm` (via
/// human-monitor-command) for the resume-where-you-left-off snapshot.
/// Commands are serialised; QMP answers them in order.
final class QMPClient: @unchecked Sendable {
    enum Error: Swift.Error, LocalizedError {
        case notConnected
        case qmp(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "QMP not connected"
            case .qmp(let message): return "QEMU: \(message)"
            }
        }
    }

    private let port: UInt16
    private let queue = DispatchQueue(label: "LinuxVM.qmp")
    private var connection: NWConnection?
    private var buffer = Data()
    private var pending: [CheckedContinuation<[String: Any], Swift.Error>] = []
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    init(port: UInt16) {
        self.port = port
    }

    /// Keeps retrying until QEMU's QMP socket accepts, then negotiates
    /// capabilities. Returns once commands can be sent.
    func connect() async {
        queue.async { self.attempt() }
        await withCheckedContinuation { continuation in
            queue.async {
                if self.ready { continuation.resume() } else { self.readyWaiters.append(continuation) }
            }
        }
    }

    func stop() {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.ready = false
            self.pending.forEach { $0.resume(throwing: Error.notConnected) }
            self.pending.removeAll()
        }
    }

    @discardableResult
    func execute(_ command: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        var message: [String: Any] = ["execute": command]
        if !arguments.isEmpty { message["arguments"] = arguments }
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let connection = self.connection, self.ready || command == "qmp_capabilities" else {
                    continuation.resume(throwing: Error.notConnected)
                    return
                }
                self.pending.append(continuation)
                connection.send(content: line, completion: .contentProcessed { _ in })
            }
        }
    }

    /// Runs a human monitor (HMP) command such as `savevm tag`. HMP reports
    /// failures as text in the return value rather than as a QMP error.
    func hmp(_ commandLine: String) async throws -> String {
        let reply = try await execute("human-monitor-command", ["command-line": commandLine])
        let output = reply["return"] as? String ?? ""
        if output.lowercased().contains("error") {
            throw Error.qmp(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private func attempt() {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        buffer.removeAll()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive(on: connection)
            case .failed, .waiting:
                connection.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    if self.connection === connection { self.attempt() }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                self.handle(line)
            }
            if isComplete || error != nil {
                self.stop()
                return
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if object["QMP"] != nil {
            // Greeting: capabilities negotiation must come first.
            Task {
                _ = try? await self.execute("qmp_capabilities")
                self.queue.async {
                    self.ready = true
                    self.readyWaiters.forEach { $0.resume() }
                    self.readyWaiters.removeAll()
                }
            }
            return
        }
        if object["event"] != nil { return }
        guard !pending.isEmpty else { return }
        let continuation = pending.removeFirst()
        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: Error.qmp(error["desc"] as? String ?? "\(error)"))
        } else {
            continuation.resume(returning: object)
        }
    }
}
