import CQEMUBootstrap
import Foundation

/// Finds the right QEMU build in the app bundle and runs it in-process.
///
/// The app embeds two builds of `qemu-aarch64-softmmu` (see
/// Scripts/fetch-qemu-frameworks.sh, which extracts them from UTM's
/// release IPAs):
///
/// - `qemu-aarch64-softmmu.framework` — TCG with a real JIT. Needs
///   writable+executable memory, which stock iOS only grants to a
///   development-signed app while a debugger is attached (SideStore/AltStore
///   + StikDebug, or Xcode). This is the fast one.
/// - `qemu-aarch64-softmmu-tcti.framework` — UTM SE's "TCTI" backend:
///   threaded-code interpreter, no JIT needed, works from any install,
///   several times slower.
///
/// There is no hardware virtualization for third-party apps on stock iOS
/// (Hypervisor.framework needs a private entitlement), so TCG-with-JIT is
/// the ceiling.
public enum QEMURuntime {
    public enum Backend: String, Sendable {
        case jit = "JIT (TCG)"
        case interpreter = "Interpreter (TCTI, no JIT)"
    }

    public enum Error: Swift.Error, LocalizedError {
        case notBundled
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notBundled:
                return "No QEMU framework in the app bundle. Build the app with Scripts/fetch-qemu-frameworks.sh (the CI 'Package IPA' job does this)."
            case .launchFailed(let message):
                return message
            }
        }
    }

    public static var jitAvailable: Bool { lvm_jit_available() }

    static func framework(named name: String) -> URL? {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let binary = frameworks.appendingPathComponent("\(name).framework/\(name)")
        return FileManager.default.fileExists(atPath: binary.path) ? binary : nil
    }

    /// JIT build when JIT is actually usable right now, otherwise the
    /// interpreter build. Never picks the JIT build without JIT: it would
    /// fail to map its code buffer and abort.
    public static func selectBackend() -> (Backend, URL)? {
        if jitAvailable, let jit = framework(named: "qemu-aarch64-softmmu") {
            return (.jit, jit)
        }
        if let tcti = framework(named: "qemu-aarch64-softmmu-tcti") {
            return (.interpreter, tcti)
        }
        return nil
    }

    /// Directory with QEMU's data files (firmware/option ROMs), if bundled.
    static var dataDirectory: URL? {
        Bundle.main.url(forResource: "qemu", withExtension: nil)
    }

    private final class ExitBox {
        let handler: (Int32, Bool) -> Void
        init(_ handler: @escaping (Int32, Bool) -> Void) { self.handler = handler }
    }

    /// Starts QEMU on its own thread and returns immediately. `onExit` runs
    /// on the QEMU thread once the VM has stopped (`fatal` = QEMU called
    /// exit(), typically a bad argument or a missing file).
    static func start(binary: URL, arguments: [String],
                      onExit: @escaping (_ status: Int32, _ fatal: Bool) -> Void) throws {
        let argv = ["qemu-system-aarch64"] + arguments
        let environment = ["TMPDIR=\(FileManager.default.temporaryDirectory.path)"]
        let box = Unmanaged.passRetained(ExitBox(onExit)).toOpaque()

        var cArgv = argv.map { strdup($0) }
        var cEnv = environment.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        let messageCapacity = 1024
        var message = [CChar](repeating: 0, count: messageCapacity)
        let status = cArgv.withUnsafeMutableBufferPointer { argvBuffer in
            cEnv.withUnsafeMutableBufferPointer { envBuffer in
                argvBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: argvBuffer.count) { argvPointer in
                    envBuffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: envBuffer.count) { envPointer in
                        lvm_qemu_start(binary.path, Int32(argv.count), argvPointer, envPointer, { status, fatal, context in
                            let box = Unmanaged<ExitBox>.fromOpaque(context!).takeRetainedValue()
                            box.handler(status, fatal)
                        }, box, &message, messageCapacity)
                    }
                }
            }
        }
        if status != 0 {
            Unmanaged<ExitBox>.fromOpaque(box).release()
            throw Error.launchFailed(String(cString: message))
        }
    }
}
