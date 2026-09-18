import Foundation
import Citadel
import Crypto
import NIOCore
import ios_system

/// `sshc` — a modern SSH2 client command, distinct from ios_system's bundled
/// `ssh_cmd` (which wraps libssh2). Registered under a different name so both
/// can coexist while the libssh2-based one is evaluated for removal — see
/// Docs/NEXT_STEPS.md.
///
/// Usage:
///   sshc user@host [-p port] [-pw password] [-i keyfile] [-kp passphrase] [command...]
///
/// `-i` takes precedence over `-pw` when both are given — key auth is what
/// real Termux users reach for first (Docs/NEXT_STEPS.md item 3). `-kp` only
/// matters for an encrypted key file; Citadel's `decryptionKey` parameter is,
/// despite the name, the raw passphrase bytes — it runs bcrypt_pbkdf itself
/// against the key's embedded salt (see OpenSSHKey.swift upstream).
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
    let keyFile: String?
    let keyPassphrase: String?
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
        var keyFile: String?
        var keyPassphrase: String?
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
            case "-i":
                index += 1
                guard index < remaining.count else { return nil }
                keyFile = remaining[index]
            case "-kp":
                index += 1
                guard index < remaining.count else { return nil }
                keyPassphrase = remaining[index]
            default:
                commandParts.append(remaining[index])
            }
            index += 1
        }

        self.port = port
        self.password = password
        self.keyFile = keyFile
        self.keyPassphrase = keyPassphrase
        self.remoteCommand = commandParts.isEmpty ? nil : commandParts.joined(separator: " ")
    }
}

/// Builds a Citadel authentication method from a `-i keyfile [-kp passphrase]`
/// pair. Detects RSA vs. ed25519 from the key's own header rather than
/// trusting a file extension — `SSHKeyDetection` parses the OpenSSH
/// private-key structure directly.
private func keyBasedAuthenticationMethod(
    username: String,
    keyFile: String,
    passphrase: String?
) -> Result<SSHAuthenticationMethod, String> {
    let expandedPath = (keyFile as NSString).expandingTildeInPath
    guard let keyString = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
        return .failure("sshc: couldn't read key file at \(keyFile)")
    }

    let decryptionKey = passphrase.flatMap { $0.data(using: .utf8) }

    do {
        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyString)
        switch keyType {
        case .rsa:
            let privateKey = try Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: decryptionKey)
            return .success(.rsa(username: username, privateKey: privateKey))
        case .ed25519:
            let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: decryptionKey)
            return .success(.ed25519(username: username, privateKey: privateKey))
        default:
            return .failure("sshc: unsupported key type \(keyType) — only RSA and ed25519 are wired up so far")
        }
    } catch SSHKeyDetectionError.passphraseRequired, SSHKeyDetectionError.encryptedPrivateKey {
        return .failure("sshc: key at \(keyFile) is encrypted — pass -kp <passphrase>")
    } catch SSHKeyDetectionError.incorrectPassphrase {
        return .failure("sshc: incorrect passphrase for \(keyFile)")
    } catch {
        return .failure("sshc: couldn't parse key at \(keyFile): \(error)")
    }
}

private func runSSHSession(_ args: SSHArguments) async -> Int32 {
    let authenticationMethod: SSHAuthenticationMethod
    if let keyFile = args.keyFile {
        switch keyBasedAuthenticationMethod(username: args.username, keyFile: keyFile, passphrase: args.keyPassphrase) {
        case .success(let method):
            authenticationMethod = method
        case .failure(let message):
            FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
            return 1
        }
    } else if let password = args.password {
        authenticationMethod = .passwordBased(username: args.username, password: password)
    } else {
        FileHandle.standardError.write(
            "sshc: no credentials — pass -pw <password> or -i <keyfile> [-kp <passphrase>]\n"
                .data(using: .utf8)!
        )
        return 1
    }

    do {
        let client = try await SSHClient.connect(
            host: args.host,
            port: args.port,
            authenticationMethod: authenticationMethod,
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
    print("usage: sshc user@host [-p port] [-pw password] [-i keyfile] [-kp passphrase] [command...]")
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
