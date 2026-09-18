import Foundation
import ios_system
import PythonCommand

/// Runs one command line per call through `ios_system()` on a background
/// thread, redirecting that thread's stdout/stderr into a byte callback so a
/// terminal view (SwiftTerm) can render it. No fork/exec anywhere — every
/// command is a C function linked into this same process, matching the
/// App Store sandbox constraint from the brief.
///
/// Single global ios_system session for now — one TerminalViewController,
/// one shell. Multiple concurrent terminals would need `ios_switchSession`
/// with a stable per-tab token (see Docs/NEXT_STEPS.md item 4); not wired up
/// here since there's only ever one caller.
final class ShellEngine {

    /// Called on the main thread with raw output bytes as they arrive.
    var onOutput: ((Data) -> Void)?

    /// True while a command dispatched through `run` is still executing —
    /// lets the terminal controller decide whether a keystroke should be
    /// forwarded live to that command's stdin (see `sendInput`) or buffered
    /// as a new command line (see Docs/NEXT_STEPS.md item 2).
    private(set) var isRunning = false

    private let workingDirectory: URL
    private var didInitialize = false
    private var stdinPipe: Pipe?

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    func start() {
        guard !didInitialize else { return }
        didInitialize = true

        ios_setDirectoryURL(workingDirectory)
        // Confines all path resolution inside ios_system to the app sandbox —
        // required so `cd /`, `ls /private`, etc. don't leak outside our container.
        ios_setMiniRoot(workingDirectory.path)

        initializeEnvironment()
        loadBundledCommandDictionary()
        configurePython()
        CommandRegistry.registerAll()
    }

    /// `python`/`python3` (Docs/NEXT_STEPS.md item 5) need PYTHONHOME
    /// pointed at the bundled stdlib before the first invocation. That
    /// resource lives in this target's bundle (`Bundle.module` is
    /// per-target), so it's resolved here and handed to PythonCommand
    /// rather than PythonCommand looking it up itself.
    private func configurePython() {
        guard let stdlibURL = Bundle.module.url(forResource: "python-stdlib", withExtension: nil) else {
            assertionFailure("python-stdlib resource missing from bundle")
            return
        }
        PythonCommand.configure(pythonHome: stdlibURL.path)
    }

    /// `initializeEnvironment()` alone does not register `man`/`perl` or the
    /// network_ios commands (dig/ping/ssh-agent's siblings etc.) — confirmed
    /// by diffing ios_system's own default plist against a-Shell's shipped
    /// one, which explicitly loads its own bundled dictionary via
    /// `addCommandList()` at startup. We mirror that: ship the same mapping,
    /// filtered to only the frameworks this project actually links (see
    /// Docs/NEXT_STEPS.md item 1), and load it the same way.
    private func loadBundledCommandDictionary() {
        guard let path = Bundle.module.path(forResource: "commandDictionary", ofType: "plist") else {
            assertionFailure("commandDictionary.plist missing from bundle resources")
            return
        }
        if let error = addCommandList(path) {
            print("ShellEngine: addCommandList failed: \(error)")
        }
    }

    /// Runs `commandLine` (e.g. "ls -la", "sysinfo", "sshc user@host ls") and
    /// invokes `completion` on the main thread once it returns. While this is
    /// in flight, `isRunning` is true and bytes handed to `sendInput` go
    /// straight to the command's stdin — that's what lets `python3`'s REPL,
    /// `sshc` in interactive mode, etc. actually read something.
    func run(_ commandLine: String, completion: @escaping (Int32) -> Void) {
        let outputPipe = Pipe()
        let readSource = outputPipe.fileHandleForReading
        let inputPipe = Pipe()
        stdinPipe = inputPipe
        isRunning = true

        readSource.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.onOutput?(data)
            }
        }

        Thread.detachNewThread { [weak self, workingDirectory] in
            let writeFD = outputPipe.fileHandleForWriting.fileDescriptor
            let readFD = inputPipe.fileHandleForReading.fileDescriptor
            guard let outStream = fdopen(writeFD, "w"), let inStream = fdopen(readFD, "r") else {
                DispatchQueue.main.async { completion(-1) }
                return
            }

            ios_setDirectoryURL(workingDirectory)
            ios_setStreams(inStream, outStream, outStream)

            let status = ios_system(commandLine)

            fflush(outStream)
            fclose(outStream)
            fclose(inStream)
            readSource.readabilityHandler = nil

            DispatchQueue.main.async {
                self?.isRunning = false
                self?.stdinPipe = nil
                completion(status)
            }
        }
    }

    /// Forwards raw keystroke bytes to the currently running command's
    /// stdin. No-op when nothing is running (there's no reader on the other
    /// end) — the caller is expected to check `isRunning` first and treat
    /// input as a new command line instead. See Docs/NEXT_STEPS.md item 2.
    func sendInput(_ data: Data) {
        guard let stdinPipe else { return }
        stdinPipe.fileHandleForWriting.write(data)
    }
}
