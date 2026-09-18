import Foundation
import ios_system
import PythonCommand

/// Runs one command line per call through `ios_system()` on a background
/// thread, redirecting that thread's stdout/stderr into a byte callback so a
/// terminal view (SwiftTerm) can render it. No fork/exec anywhere — every
/// command is a C function linked into this same process, matching the
/// App Store sandbox constraint from the brief.
///
/// One `ShellEngine` per tab (Docs/NEXT_STEPS.md item 4 / Docs/ROADMAP.md
/// Track A item 9). Isolation between tabs is `ios_switchSession`, keyed by
/// each engine's own identity (`Unmanaged.passUnretained(self).toOpaque()`)
/// rather than a separately-tracked UUID→pointer map — the engine instance
/// already lives exactly as long as its tab, so its own address is already
/// a stable, unique-for-its-lifetime token, and `deinit` closing the
/// session closes that narrow window before ARC could hand the same
/// address to an unrelated object. `ios_system` never dereferences the
/// token (confirmed against its header — it's used purely as an opaque
/// dictionary key), so this is safe even though the pointer stops pointing
/// at a live `ShellEngine` the instant `deinit` runs.
///
/// Command registration (`replaceCommand`/`addCommandList`) is global
/// dispatch-table state, not per-session — `bootstrapGlobalEnvironmentOnce`
/// runs it exactly once no matter how many tabs get created.
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

    /// This tab's `ios_switchSession` key. `lazy` so it's computed once
    /// `self` is a fully-formed instance rather than during `init`.
    private lazy var sessionToken: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    deinit {
        ios_closeSession(sessionToken)
    }

    func start() {
        guard !didInitialize else { return }
        didInitialize = true

        ShellEngine.bootstrapGlobalEnvironmentOnce()

        ios_switchSession(sessionToken)
        ios_setDirectoryURL(workingDirectory)
        // Confines all path resolution inside ios_system to the app sandbox —
        // required so `cd /`, `ls /private`, etc. don't leak outside our container.
        ios_setMiniRoot(workingDirectory.path)
    }

    // MARK: - One-time, process-wide setup

    private static var didBootstrapGlobalEnvironment = false

    private static func bootstrapGlobalEnvironmentOnce() {
        guard !didBootstrapGlobalEnvironment else { return }
        didBootstrapGlobalEnvironment = true

        initializeEnvironment()
        loadBundledCommandDictionary()
        configurePython()
        CommandRegistry.registerAll()
    }

    /// `python`/`python3` (Docs/NEXT_STEPS.md item 5) need PYTHONHOME
    /// pointed at the bundled stdlib before the first invocation.
    private static func configurePython() {
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
    private static func loadBundledCommandDictionary() {
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

        Thread.detachNewThread { [weak self, workingDirectory, sessionToken] in
            let writeFD = outputPipe.fileHandleForWriting.fileDescriptor
            let readFD = inputPipe.fileHandleForReading.fileDescriptor
            guard let outStream = fdopen(writeFD, "w"), let inStream = fdopen(readFD, "r") else {
                DispatchQueue.main.async { completion(-1) }
                return
            }

            // ios_system's session state (`thread_stdin`/`thread_stdout`/
            // current directory/environment) hangs off __thread storage —
            // since every command here runs on a freshly detached thread,
            // that storage starts blank each time. Switching to this tab's
            // session token is what makes the *tab's* persistent state
            // (not some other tab's, not a blank default) the one that
            // gets bound to this thread before the command runs.
            ios_switchSession(sessionToken)
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
