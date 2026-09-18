import Foundation
import SwiftGit2
import ios_system

/// `git` — a minimal but real libgit2-backed git client, registered like
/// every other in-process command (see SysInfoCommand.register()).
///
/// Upstream SwiftGit2/SwiftGit2 has no SPM manifest at all; this uses the
/// joehinkle11/SwiftGit3 fork instead, which vendors prebuilt libgit2/
/// libssh2/openssl xcframeworks with a real ios-arm64 device slice — see
/// Docs/ROADMAP.md Track A item 4 for why that avoids the network_ios
/// checksum problem (Docs/NEXT_STEPS.md, dependencies section).
///
/// Usage:
///   git clone <url> [dir] [-u user -pw pass] [-i keyfile [-kp passphrase]]
///   git status [dir]
///   git add <path> [dir]
///   git commit -m <message> [-n name] [-e email] [dir]
///   git log [-n count] [dir]
///   git push [-u user -pw pass] [dir]
///
/// Every subcommand's trailing `[dir]` defaults to the shell's current
/// working directory. `clone`'s `dir` is instead the destination to create
/// (defaulting to the repo name inferred from the URL) since there's no
/// existing repo to default to yet.
public enum GitCommand {

    public static func register() {
        replaceCommand("git", "git_main", true)
    }
}

@_cdecl("git_main")
public func git_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    let args = commandLineArguments(argc: argc, argv: argv)
    guard let subcommand = args.first else {
        printUsage()
        return 1
    }

    let rest = Array(args.dropFirst())
    switch subcommand {
    case "clone":
        return runClone(rest)
    case "status":
        return runStatus(rest)
    case "add":
        return runAdd(rest)
    case "commit":
        return runCommit(rest)
    case "log":
        return runLog(rest)
    case "push":
        return runPush(rest)
    default:
        FileHandle.standardError.write("git: unknown subcommand '\(subcommand)'\n".data(using: .utf8)!)
        printUsage()
        return 1
    }
}

// MARK: - clone

private func runClone(_ args: [String]) -> Int32 {
    var positional: [String] = []
    var username: String?
    var password: String?
    var keyFile: String?
    var keyPassphrase: String?

    var index = 0
    while index < args.count {
        switch args[index] {
        case "-u":
            index += 1
            guard index < args.count else { return usageError("git clone <url> [dir] [-u user -pw pass] [-i keyfile [-kp passphrase]]") }
            username = args[index]
        case "-pw":
            index += 1
            guard index < args.count else { return usageError("git clone <url> [dir] [-u user -pw pass] [-i keyfile [-kp passphrase]]") }
            password = args[index]
        case "-i":
            index += 1
            guard index < args.count else { return usageError("git clone <url> [dir] [-u user -pw pass] [-i keyfile [-kp passphrase]]") }
            keyFile = args[index]
        case "-kp":
            index += 1
            guard index < args.count else { return usageError("git clone <url> [dir] [-u user -pw pass] [-i keyfile [-kp passphrase]]") }
            keyPassphrase = args[index]
        default:
            positional.append(args[index])
        }
        index += 1
    }

    guard let urlString = positional.first, let remoteURL = URL(string: urlString) else {
        return usageError("git clone <url> [dir]")
    }

    let destinationName = positional.count > 1
        ? positional[1]
        : String(urlString.split(separator: "/").last?.replacingOccurrences(of: ".git", with: "") ?? "repo")
    let destinationURL = URL(fileURLWithPath: currentDirectoryPath()).appendingPathComponent(destinationName)

    let credentials: Credentials
    if let keyFile {
        guard let privateKey = try? String(contentsOfFile: (keyFile as NSString).expandingTildeInPath, encoding: .utf8) else {
            printError("git: couldn't read key file at \(keyFile)")
            return 1
        }
        credentials = .sshMemory(username: username ?? "git", privateKey: privateKey, passphrase: keyPassphrase ?? "")
    } else if let username, let password {
        credentials = .plaintext(username: username, password: password)
    } else {
        credentials = .default
    }

    switch Repository.clone(from: remoteURL, to: destinationURL, credentials: credentials) {
    case .success:
        print("Cloned into '\(destinationURL.lastPathComponent)'")
        return 0
    case .failure(let error):
        printError("git: clone failed: \(error.localizedDescription)")
        return 1
    }
}

// MARK: - status

private func runStatus(_ args: [String]) -> Int32 {
    guard let repository = openRepository(at: args.first) else { return 1 }

    switch repository.status() {
    case .success(let entries):
        if entries.isEmpty {
            print("nothing to commit, working tree clean")
        } else {
            for entry in entries {
                let path = entry.indexToWorkDir?.newFile?.path ?? entry.headToIndex?.newFile?.path ?? "?"
                print("\(statusLabel(entry.status))\t\(path)")
            }
        }
        return 0
    case .failure(let error):
        printError("git: status failed: \(error.localizedDescription)")
        return 1
    }
}

private func statusLabel(_ status: Diff.Status) -> String {
    if status.contains(.indexNew) || status.contains(.workTreeNew) { return "??" }
    if status.contains(.indexModified) || status.contains(.workTreeModified) { return " M" }
    if status.contains(.indexDeleted) || status.contains(.workTreeDeleted) { return " D" }
    return "  "
}

// MARK: - add

private func runAdd(_ args: [String]) -> Int32 {
    guard let path = args.first else {
        return usageError("git add <path> [dir]")
    }
    guard let repository = openRepository(at: args.count > 1 ? args[1] : nil) else { return 1 }

    switch repository.add(path: path) {
    case .success:
        return 0
    case .failure(let error):
        printError("git: add failed: \(error.localizedDescription)")
        return 1
    }
}

// MARK: - commit

private func runCommit(_ args: [String]) -> Int32 {
    var message: String?
    var name = "TermuxSandbox"
    var email = "termuxsandbox@localhost"
    var positional: [String] = []

    var index = 0
    while index < args.count {
        switch args[index] {
        case "-m":
            index += 1
            guard index < args.count else { return usageError("git commit -m <message> [-n name] [-e email] [dir]") }
            message = args[index]
        case "-n":
            index += 1
            guard index < args.count else { return usageError("git commit -m <message> [-n name] [-e email] [dir]") }
            name = args[index]
        case "-e":
            index += 1
            guard index < args.count else { return usageError("git commit -m <message> [-n name] [-e email] [dir]") }
            email = args[index]
        default:
            positional.append(args[index])
        }
        index += 1
    }

    guard let message else {
        return usageError("git commit -m <message> [-n name] [-e email] [dir]")
    }
    guard let repository = openRepository(at: positional.first) else { return 1 }

    let signature = Signature(name: name, email: email)
    switch repository.commit(message: message, signature: signature) {
    case .success(let commit):
        print("[commit \(commit.oid)] \(message)")
        return 0
    case .failure(let error):
        printError("git: commit failed: \(error.localizedDescription)")
        return 1
    }
}

// MARK: - log

private func runLog(_ args: [String]) -> Int32 {
    var limit = 10
    var positional: [String] = []

    var index = 0
    while index < args.count {
        if args[index] == "-n" {
            index += 1
            guard index < args.count, let n = Int(args[index]) else { return usageError("git log [-n count] [dir]") }
            limit = n
        } else {
            positional.append(args[index])
        }
        index += 1
    }

    guard let repository = openRepository(at: positional.first) else { return 1 }

    guard case .success(let head) = repository.HEAD() else {
        printError("git: log failed: no HEAD (empty repository?)")
        return 1
    }

    var currentOID: OID? = head.oid
    var printed = 0
    let formatter = ISO8601DateFormatter()

    while let oid = currentOID, printed < limit {
        guard case .success(let commit) = repository.commit(oid) else { break }
        print("commit \(oid)")
        print("Author: \(commit.author.name) <\(commit.author.email)>")
        print("Date:   \(formatter.string(from: commit.author.time))")
        print("")
        print("    \(commit.message.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("")
        printed += 1
        currentOID = commit.parents.first?.oid
    }

    return 0
}

// MARK: - push

private func runPush(_ args: [String]) -> Int32 {
    var username: String?
    var password: String?
    var positional: [String] = []

    var index = 0
    while index < args.count {
        switch args[index] {
        case "-u":
            index += 1
            guard index < args.count else { return usageError("git push -u user -pw pass [dir]") }
            username = args[index]
        case "-pw":
            index += 1
            guard index < args.count else { return usageError("git push -u user -pw pass [dir]") }
            password = args[index]
        default:
            positional.append(args[index])
        }
        index += 1
    }

    guard let username, let password else {
        return usageError("git push -u user -pw pass [dir] — HTTPS credentials only for now, key-based push is a Docs/ROADMAP.md follow-up")
    }
    guard let repository = openRepository(at: positional.first) else { return 1 }

    // Upstream's push() is fire-and-forget (returns Void, not a Result) —
    // it prints libgit2's raw integer status codes to stdout itself.
    repository.push(repository, username, password)
    return 0
}

// MARK: - shared helpers

private func openRepository(at path: String?) -> Repository? {
    let url = URL(fileURLWithPath: path ?? currentDirectoryPath())
    switch Repository.at(url) {
    case .success(let repository):
        return repository
    case .failure(let error):
        printError("git: not a git repository: \(url.path) (\(error.localizedDescription))")
        return nil
    }
}

private func currentDirectoryPath() -> String {
    FileManager.default.currentDirectoryPath
}

private func usageError(_ message: String) -> Int32 {
    printError("usage: \(message)")
    return 1
}

private func printError(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

private func printUsage() {
    print("""
    usage: git <command> [args]
      clone <url> [dir] [-u user -pw pass] [-i keyfile [-kp passphrase]]
      status [dir]
      add <path> [dir]
      commit -m <message> [-n name] [-e email] [dir]
      log [-n count] [dir]
      push -u user -pw pass [dir]
    """)
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
