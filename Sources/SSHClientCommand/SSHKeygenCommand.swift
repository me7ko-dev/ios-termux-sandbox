import Foundation
import Citadel
import Crypto
import ios_system

/// `keygen` — generates a new ed25519 SSH keypair directly usable with
/// `sshc -i`/`git clone -i` (Docs/ROADMAP.md item 8). Termux users reach for
/// the real `ssh-keygen` for exactly this, so this stays a command rather
/// than a bespoke SwiftUI picker/wizard — it fits how everything else in
/// this app already works, and needs no Files-app document-picker
/// integration to be useful.
///
/// Usage:
///   keygen -f <path> [-C comment]
///
/// Writes the private key to `<path>` and the public key to `<path>.pub`,
/// in standard OpenSSH format — the same format `sshc -i`/`git clone -i`
/// already parse.
///
/// **Scope cut:** ed25519 only, unencrypted (no `-N passphrase` to encrypt
/// the private key at rest). Citadel's own
/// `Curve25519.Signing.PrivateKey.makeSSHRepresentation(comment:)` (the
/// only *public* key-serialization API it exposes — the matching
/// `PublicKey`/RSA writers are `internal` to Citadel, hence hand-rolling
/// the public key line below instead of reusing them) only emits
/// `cipher=none`/`kdf=none`; encrypting the output would mean
/// reimplementing OpenSSH's bcrypt_pbkdf-based private-key encryption from
/// scratch, out of scope here. RSA generation isn't wired up for the same
/// reason (no public keypair-generation entry point) — ed25519 is what
/// real Termux users reach for first anyway (Docs/NEXT_STEPS.md item 3).
enum SSHKeygenCommand {

    static func register() {
        replaceCommand("keygen", "keygen_main", true)
    }
}

@_cdecl("keygen_main")
public func keygen_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    let args = commandLineArguments(argc: argc, argv: argv)

    var path: String?
    var comment = ""

    var index = 0
    while index < args.count {
        switch args[index] {
        case "-f":
            index += 1
            guard index < args.count else { return keygenUsageError() }
            path = args[index]
        case "-C":
            index += 1
            guard index < args.count else { return keygenUsageError() }
            comment = args[index]
        default:
            return keygenUsageError()
        }
        index += 1
    }

    guard let path else { return keygenUsageError() }

    let expandedPath = (path as NSString).expandingTildeInPath
    let publicKeyPath = expandedPath + ".pub"

    guard !FileManager.default.fileExists(atPath: expandedPath) else {
        FileHandle.standardError.write("keygen: \(path) already exists, refusing to overwrite\n".data(using: .utf8)!)
        return 1
    }

    let privateKey = Curve25519.Signing.PrivateKey()
    let privateKeyPEM = privateKey.makeSSHRepresentation(comment: comment)
    let publicKeyLine = sshEd25519PublicKeyLine(privateKey.publicKey, comment: comment)

    do {
        try privateKeyPEM.write(toFile: expandedPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expandedPath)
        try (publicKeyLine + "\n").write(toFile: publicKeyPath, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write("keygen: couldn't write key: \(error)\n".data(using: .utf8)!)
        return 1
    }

    print("Generated ed25519 keypair:")
    print("  private: \(path)")
    print("  public:  \(path).pub")
    print(publicKeyLine)
    return 0
}

/// Hand-rolled rather than reusing Citadel's own `PublicKey.write(to:)` —
/// that conformance is `internal` to the Citadel module (see this file's
/// doc comment). The format itself is tiny and standard (RFC 4253 §6.6):
/// two SSH wire-format strings, "ssh-ed25519" and the 32 raw key bytes,
/// concatenated and base64-encoded.
private func sshEd25519PublicKeyLine(_ publicKey: Curve25519.Signing.PublicKey, comment: String) -> String {
    var blob = Data()

    func appendSSHString(_ bytes: [UInt8]) {
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: bytes)
    }

    appendSSHString(Array("ssh-ed25519".utf8))
    appendSSHString(Array(publicKey.rawRepresentation))

    let base64 = blob.base64EncodedString()
    return comment.isEmpty ? "ssh-ed25519 \(base64)" : "ssh-ed25519 \(base64) \(comment)"
}

private func keygenUsageError() -> Int32 {
    FileHandle.standardError.write("usage: keygen -f <path> [-C comment]\n".data(using: .utf8)!)
    return 1
}

private func commandLineArguments(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> [String] {
    guard let argv else { return [] }
    return (1..<Int(argc)).compactMap { i in
        argv[i].map { String(cString: $0) }
    }
}
