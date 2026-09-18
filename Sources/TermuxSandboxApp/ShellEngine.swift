import Foundation
import ios_system

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

    private let workingDirectory: URL
    private var didInitialize = false

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
        CommandRegistry.registerAll()
    }

    /// Runs `commandLine` (e.g. "ls -la", "sysinfo", "sshc user@host ls") and
    /// invokes `completion` on the main thread once it returns.
    func run(_ commandLine: String, completion: @escaping (Int32) -> Void) {
        let outputPipe = Pipe()
        let readSource = outputPipe.fileHandleForReading

        readSource.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.onOutput?(data)
            }
        }

        Thread.detachNewThread { [workingDirectory] in
            let writeFD = outputPipe.fileHandleForWriting.fileDescriptor
            guard let outStream = fdopen(writeFD, "w") else {
                DispatchQueue.main.async { completion(-1) }
                return
            }

            ios_setDirectoryURL(workingDirectory)
            // stdin here is the process's real stdin, which nothing writes to in
            // a sandboxed app — fine for sysinfo/sshc (neither reads stdin), but
            // any future interactive command (python REPL, vim) needs an input
            // pipe fed by terminal keystrokes, mirroring the output pipe below.
            // See Docs/NEXT_STEPS.md item 2.
            ios_setStreams(stdin, outStream, outStream)

            let status = ios_system(commandLine)

            fflush(outStream)
            fclose(outStream)
            readSource.readabilityHandler = nil

            DispatchQueue.main.async { completion(status) }
        }
    }
}
