import Foundation
import SwiftGit2
import ios_system

/// `git` — a real but deliberately partial libgit2-backed implementation,
/// not a port of the actual git CLI. Backed by SwiftGit2 (light-tech's
/// iOS-compatible fork, `spm` branch), whose public API only covers a
/// subset of libgit2 itself:
///
/// Supported: init, clone (with optional token auth), status, add, commit
/// (except a repo's very first commit — see `runCommit`), log, fetch
/// (public repos only — SwiftGit2's `fetch(_:)` wires no credentials
/// callback into `git_fetch_options` at all).
///
/// Not implemented: push, pull, merge, branch/checkout, diff, rebase.
/// SwiftGit2's Swift wrapper exposes none of libgit2's push or merge
/// machinery — only the raw C API (via the transitive Clibgit2 dependency)
/// has it, which would mean writing our own refspec/push-options bindings
/// from scratch with no device to test them on. Documented here rather than
/// guessed at. See Docs/NEXT_STEPS.md.
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
    case "init": return runInit(rest)
    case "clone": return runClone(rest)
    case "status": return runStatus(rest)
    case "add": return runAdd(rest)
    case "commit": return runCommit(rest)
    case "log": return runLog(rest)
    case "fetch": return runFetch(rest)
    default:
        writeError(
            "git: '\(subcommand)' is not supported — this is a from-scratch " +
            "libgit2-backed subset (init/clone/status/add/commit/log/fetch " +
            "only), not the real git CLI. See Docs/STATUS.md."
        )
        return 1
    }
}

// MARK: - Subcommands

private func runInit(_ args: [String]) -> Int32 {
    let dir = args.first ?? "."
    let url = URL(fileURLWithPath: dir, isDirectory: true, relativeTo: currentDirectoryURL()).standardizedFileURL

    switch Repository.create(at: url) {
    case .success:
        print("Initialized empty Git repository in \(url.path)/.git/")
        return 0
    case .failure(let error):
        writeError("git: init failed: \(error.localizedDescription)")
        return 1
    }
}

private func runClone(_ args: [String]) -> Int32 {
    guard let urlString = args.first, let remoteURL = URL(string: urlString) else {
        writeError("usage: git clone <url> [<directory>]")
        return 1
    }
    let inferredName = urlString
        .split(separator: "/")
        .last
        .map { $0.hasSuffix(".git") ? String($0.dropLast(4)) : String($0) } ?? "repo"
    let dirName = args.count > 1 ? args[1] : inferredName
    let destination = URL(fileURLWithPath: dirName, isDirectory: true, relativeTo: currentDirectoryURL())

    switch Repository.clone(from: remoteURL, to: destination, credentials: credentialsFromEnvironment()) {
    case .success:
        print("Cloned into '\(dirName)'")
        return 0
    case .failure(let error):
        writeError("git: clone failed: \(error.localizedDescription)")
        return 1
    }
}

private func runStatus(_ args: [String]) -> Int32 {
    switch discoverRepository(from: currentDirectoryURL()) {
    case .failure(let error):
        writeError("git: \(error.localizedDescription)")
        return 1
    case .success(let repo):
        switch repo.status() {
        case .failure(let error):
            writeError("git: status failed: \(error.localizedDescription)")
            return 1
        case .success(let entries):
            guard !entries.isEmpty else {
                print("nothing to commit, working tree clean")
                return 0
            }
            for entry in entries {
                let path = entry.indexToWorkDir?.newFile?.path ?? entry.headToIndex?.newFile?.path ?? "?"
                print("\(describe(entry.status)) \(path)")
            }
            return 0
        }
    }
}

private func runAdd(_ args: [String]) -> Int32 {
    guard !args.isEmpty else {
        writeError("usage: git add <path> [<path>...]")
        return 1
    }
    switch discoverRepository(from: currentDirectoryURL()) {
    case .failure(let error):
        writeError("git: \(error.localizedDescription)")
        return 1
    case .success(let repo):
        guard let repoRoot = repo.directoryURL else {
            writeError("git: bare repositories aren't supported")
            return 1
        }
        var hadError = false
        for arg in args {
            let absolute = URL(fileURLWithPath: arg, relativeTo: currentDirectoryURL()).standardizedFileURL
            let relative = relativePath(of: absolute, from: repoRoot)
            if case .failure(let error) = repo.add(path: relative) {
                writeError("git: add '\(arg)' failed: \(error.localizedDescription)")
                hadError = true
            }
        }
        return hadError ? 1 : 0
    }
}

private func runCommit(_ args: [String]) -> Int32 {
    var message: String?
    var i = 0
    while i < args.count {
        if (args[i] == "-m" || args[i] == "--message"), i + 1 < args.count {
            message = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }
    guard let message else {
        writeError("usage: git commit -m <message>")
        return 1
    }

    switch discoverRepository(from: currentDirectoryURL()) {
    case .failure(let error):
        writeError("git: \(error.localizedDescription)")
        return 1
    case .success(let repo):
        switch repo.commit(message: message, signature: signatureFromEnvironment()) {
        case .success(let commit):
            print("[\(String(commit.oid.description.prefix(7)))] \(message)")
            return 0
        case .failure(let error):
            // SwiftGit2's commit(message:signature:) convenience looks up
            // HEAD as the (sole) parent internally and simply fails if
            // there isn't one yet — it doesn't fall back to a zero-parent
            // root commit. The tree-writing/parent-list API that would let
            // us handle that case ourselves (`unsafeIndex()`) isn't public.
            writeError(
                "git: commit failed: \(error.localizedDescription) " +
                "(this git subset can't create a repo's very first commit — " +
                "only commits with an existing HEAD/parent, e.g. right after " +
                "`git clone` — see Docs/STATUS.md)"
            )
            return 1
        }
    }
}

private func runLog(_ args: [String]) -> Int32 {
    switch discoverRepository(from: currentDirectoryURL()) {
    case .failure(let error):
        writeError("git: \(error.localizedDescription)")
        return 1
    case .success(let repo):
        switch repo.HEAD() {
        case .failure(let error):
            writeError("git: log failed: \(error.localizedDescription) (no commits yet?)")
            return 1
        case .success(let head):
            guard let branch = head as? Branch else {
                writeError("git: log only supports a branch HEAD right now, not a detached one")
                return 1
            }
            var count = 0
            for result in repo.commits(in: branch) {
                if count >= 50 {
                    print("... (truncated at 50 commits)")
                    break
                }
                switch result {
                case .success(let commit):
                    let firstLine = commit.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                    print("commit \(commit.oid)")
                    print("Author: \(commit.author.name) <\(commit.author.email)>")
                    print("")
                    print("    \(firstLine)")
                    print("")
                case .failure(let error):
                    writeError("git: log: \(error.localizedDescription)")
                    return 1
                }
                count += 1
            }
            return 0
        }
    }
}

private func runFetch(_ args: [String]) -> Int32 {
    let remoteName = args.first ?? "origin"
    switch discoverRepository(from: currentDirectoryURL()) {
    case .failure(let error):
        writeError("git: \(error.localizedDescription)")
        return 1
    case .success(let repo):
        switch repo.remote(named: remoteName) {
        case .failure(let error):
            writeError("git: fetch: no remote '\(remoteName)': \(error.localizedDescription)")
            return 1
        case .success(let remote):
            switch repo.fetch(remote) {
            case .success:
                print("Fetched \(remoteName)")
                return 0
            case .failure(let error):
                writeError(
                    "git: fetch failed: \(error.localizedDescription) " +
                    "(note: fetch has no credentials support in this build — " +
                    "only works against public repos, see Docs/STATUS.md)"
                )
                return 1
            }
        }
    }
}

// MARK: - Helpers

private func currentDirectoryURL() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

/// Walks up from `startURL` looking for a `.git` entry, matching how real
/// git lets you run commands from any subdirectory of a repo. SwiftGit2 has
/// no discovery helper of its own (`Repository.at` needs the exact root).
private func discoverRepository(from startURL: URL) -> Result<Repository, NSError> {
    var url = startURL.standardizedFileURL
    while true {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
            return Repository.at(url)
        }
        let parent = url.deletingLastPathComponent()
        if parent.path == url.path {
            return .failure(NSError(
                domain: "GitCommand",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "not a git repository (or any parent up to /)"]
            ))
        }
        url = parent
    }
}

private func relativePath(of url: URL, from base: URL) -> String {
    let baseComponents = base.standardizedFileURL.pathComponents
    let urlComponents = url.standardizedFileURL.pathComponents
    guard urlComponents.starts(with: baseComponents) else { return url.path }
    return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
}

/// `GIT_USERNAME` + (`GIT_TOKEN` or `GIT_PASSWORD`) enables HTTPS
/// token/password auth for `clone`, e.g. a GitHub personal access token as
/// the password. Falls back to anonymous access, which is all a public
/// repo needs.
private func credentialsFromEnvironment() -> Credentials {
    let env = ProcessInfo.processInfo.environment
    if let username = env["GIT_USERNAME"], let token = env["GIT_TOKEN"] ?? env["GIT_PASSWORD"] {
        return .plaintext(username: username, password: token)
    }
    return .default
}

private func signatureFromEnvironment() -> Signature {
    let env = ProcessInfo.processInfo.environment
    let name = env["GIT_AUTHOR_NAME"] ?? env["GIT_COMMITTER_NAME"] ?? "ios-termux-sandbox"
    let email = env["GIT_AUTHOR_EMAIL"] ?? env["GIT_COMMITTER_EMAIL"] ?? "termux@localhost"
    return Signature(name: name, email: email)
}

private func describe(_ status: Diff.Status) -> String {
    if status.contains(.indexNew) || status.contains(.workTreeNew) { return "new file:" }
    if status.contains(.indexDeleted) || status.contains(.workTreeDeleted) { return "deleted:" }
    if status.contains(.indexRenamed) || status.contains(.workTreeRenamed) { return "renamed:" }
    if status.contains(.indexModified) || status.contains(.workTreeModified) { return "modified:" }
    if status.contains(.conflicted) { return "conflicted:" }
    return "changed:"
}

private func printUsage() {
    print("usage: git <init|clone|status|add|commit|log|fetch> [args...]")
}

private func writeError(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
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
