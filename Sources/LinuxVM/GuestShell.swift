import Citadel
import Foundation
import NIOCore

/// Non-interactive command channel into the guest over SSH (separate from
/// the terminal's PTY session): clock sync, tune-up, desktop install/start.
final class GuestShell: @unchecked Sendable {
    private let port: Int
    private let username: String
    private let password: String
    private var client: SSHClient?

    init(port: Int, username: String, password: String) {
        self.port = port
        self.username = username
        self.password = password
    }

    /// Retries until sshd in the guest accepts a login, or `timeout` passes.
    func waitUntilReachable(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                _ = try await connectedClient()
                return
            } catch {
                if Date() > deadline { throw error }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Runs a command and returns its stdout. Throws on non-zero exit.
    @discardableResult
    func run(_ command: String) async throws -> String {
        let client = try await connectedClient()
        do {
            let output = try await client.executeCommand(command)
            return String(buffer: output)
        } catch let error as SSHClient.CommandFailed {
            throw error
        } catch {
            self.client = nil
            throw error
        }
    }

    /// Runs a command, streaming stdout+stderr as it arrives.
    func stream(_ command: String, onOutput: @escaping (String) -> Void) async throws {
        let client = try await connectedClient()
        let output = try await client.executeCommandStream(command)
        for try await chunk in output {
            switch chunk {
            case .stdout(let buffer), .stderr(let buffer):
                onOutput(String(buffer: buffer))
            }
        }
    }

    /// Wraps a bundled script so it runs as a file (not via stdin, which
    /// apt/dpkg or the script's own heredocs could otherwise consume).
    static func scriptCommand(_ script: String, arguments: [String] = [], environment: [String: String] = [:]) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        let env = environment.map { "\($0.key)=\(quote($0.value))" }.joined(separator: " ")
        let args = arguments.map(quote).joined(separator: " ")
        return "f=$(mktemp) && printf %s '\(encoded)' | base64 -d > \"$f\" && \(env) bash \"$f\" \(args); rc=$?; rm -f \"$f\"; exit $rc"
    }

    /// Like `scriptCommand`, but detaches the script (nohup, output to
    /// `logPath` in the guest) so the SSH command returns immediately.
    static func backgroundScriptCommand(_ script: String, name: String, logPath: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return "mkdir -p ~/.cache && f=~/.cache/\(name).sh && printf %s '\(encoded)' | base64 -d > \"$f\" && (nohup bash \"$f\" > \(logPath) 2>&1 < /dev/null &)"
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func close() {
        let client = client
        self.client = nil
        Task { try? await client?.close() }
    }

    private func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected {
            return client
        }
        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        self.client = client
        return client
    }
}
