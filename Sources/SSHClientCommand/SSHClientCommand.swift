import Foundation
import Citadel
import NIOCore
import ios_system

/// `sshc` — a modern SSH2 client command, distinct from ios_system's bundled
/// `ssh_cmd` (which wraps libssh2). Registered under a different name so both
/// can coexist while the libssh2-based one is evaluated for removal — see
/// Docs/NEXT_STEPS.md.
///
/// Usage:
///   sshc user@host [-p port] [-pw password] [command...]
///
/// With a trailing command it runs non-interactively and exits (like
/// `ssh host cmd`); without one it currently prints a notice instead of
/// opening an interactive PTY loop — that needs ios_system's raw stdin
/// stream wired to Citadel's channel, which is the next increment
/// (Docs/NEXT_STEPS.md item 2).
public enum SSHClientCommand {

    public static func register() {
        // See SysInfoCommand.register() — functionName is resolved by dlsym,
        // not passed as a raw pointer.
        replaceCommand("sshc", "sshc_main", true)
    }
}

@_cdecl("sshc_main")
public func sshc_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    let args = commandLineArguments(argc: argc, argv: argv)

    guard let parsed = SSHArguments(args) else {
        printUsage()
        return 1
    }

    // ios_system commands are synchronous C entry points; Citadel is async.
    // Bridge with a semaphore + detached Task, same pattern as ios_system's
    // own curl_ios wrapper around URLSession.
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1

    Task {
        exitCode = await runSSHSession(parsed)
        semaphore.signal()
    }
    semaphore.wait()

    return exitCode
}

private struct SSHArguments {
    let username: String
    let host: String
    let port: Int
    let password: String?
    let remoteCommand: String?

    init?(_ args: [String]) {
        var remaining = args
        guard !remaining.isEmpty else { return nil }

        let target = remaining.removeFirst()
        let parts = target.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        username = String(parts[0])
        host = String(parts[1])

        var port = 22
        var password: String?
        var commandParts: [String] = []

        var index = 0
        while index < remaining.count {
            switch remaining[index] {
            case "-p":
                index += 1
                guard index < remaining.count, let p = Int(remaining[index]) else { return nil }
                port = p
            case "-pw":
                index += 1
                guard index < remaining.count else { return nil }
                password = remaining[index]
            default:
                commandParts.append(remaining[index])
            }
            index += 1
        }

        self.port = port
        self.password = password
        self.remoteCommand = commandParts.isEmpty ? nil : commandParts.joined(separator: " ")
    }
}

private func runSSHSession(_ args: SSHArguments) async -> Int32 {
    guard let password = args.password else {
        FileHandle.standardError.write(
            "sshc: password auth only for now — pass -pw <password> (key-based auth is Docs/NEXT_STEPS.md item 3)\n"
                .data(using: .utf8)!
        )
        return 1
    }

    do {
        let client = try await SSHClient.connect(
            host: args.host,
            port: args.port,
            authenticationMethod: .passwordBased(username: args.username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        // `close()` is `async throws`, so it can't live in a `defer` (defer
        // bodies run synchronously) — close explicitly before every return.
        let result: Int32
        if let remoteCommand = args.remoteCommand {
            do {
                let output = try await client.executeCommand(remoteCommand)
                FileHandle.standardOutput.write(Data(output.readableBytesView))
                result = 0
            } catch {
                FileHandle.standardError.write("sshc: \(error)\n".data(using: .utf8)!)
                result = 1
            }
        } else {
            print("sshc: connected to \(args.host) — interactive PTY loop not wired up yet (Docs/NEXT_STEPS.md item 2)")
            result = 0
        }

        try? await client.close()
        return result
    } catch {
        FileHandle.standardError.write("sshc: \(error)\n".data(using: .utf8)!)
        return 1
    }
}

private func printUsage() {
    print("usage: sshc user@host [-p port] [-pw password] [command...]")
}

private func commandLineArguments(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> [String] {
    guard let argv else { return [] }
    // Skip argv[0] (the command name itself), matching standard argv convention.
    return (1..<Int(argc)).compactMap { i in
        argv[i].map { String(cString: $0) }
    }
}
