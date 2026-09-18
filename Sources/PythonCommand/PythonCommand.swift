import Foundation
import CPythonEmbed
import ios_system

/// `python`/`python3` — an embedded CPython 3.13 interpreter (Docs/NEXT_STEPS.md
/// item 5), vendored from beeware/Python-Apple-support rather than
/// holzschu/python_ios: the latter is an unmaintained Python *2.7* fork with
/// no SPM manifest at all, requiring a manual patch-then-Xcode-project build
/// (see its README) — beeware's is a maintained, modern Python 3, and ships
/// prebuilt xcframeworks the same way SwiftGit3/network_ios do here.
///
/// **Real, deliberate scope cut — read before assuming full stdlib parity:**
/// only ~28 modules are compiled directly into `Python.framework/Python`
/// itself (`posix`, `io`, `_sre`, `itertools`, `time`, ... — CPython's
/// always-builtin set). Everything else the stdlib needs as a C extension
/// (`math`, `socket`, `ssl`, `_sqlite3`, `zlib`, `_ctypes`, `_hashlib`, ...)
/// ships as separate `.so` dylibs bundled under
/// `Resources/python-stdlib/lib/python3.13/lib-dynload/`, loaded via the
/// same dlopen+dlsym mechanism `ios_system` itself already relies on for
/// every other bundled command framework in this project. That mechanism is
/// well-established for whole *frameworks* linked into the app at build
/// time (network_ios, SwiftGit3, Citadel); whether iOS's code-signing
/// still allows `dlopen()` on *loose* `.so` files copied in as plain bundle
/// resources (not a Framework/PlugIn Xcode explicitly code-signs on copy)
/// is the one thing in this whole session that could not be verified
/// without a real device — if `import math` fails at runtime with a
/// codesigning-flavored error rather than ModuleNotFoundError, that's why,
/// and the fix is almost certainly making each lib-dynload module its own
/// embedded/signed micro-framework instead (exactly what Briefcase's own
/// iOS packaging step does under the hood, at a level of complexity out of
/// scope for a hand-assembled SwiftPM project). Pure-Python stdlib modules
/// (`json`, `re`, most of `os`, `pathlib`, `asyncio`, ...) do not depend on
/// this and should work regardless.
///
/// `Lib/test`, `idlelib`, `tkinter`, `turtledemo`, and `ensurepip` (useless
/// here — no `subprocess`/`fork` to run `pip` with) were stripped from the
/// vendored stdlib; CPython's own test-only C extensions (`_testcapi` and
/// friends) were stripped from lib-dynload the same way.
public enum PythonCommand {

    fileprivate static var pythonHome: String?

    /// Called once at app startup — see CommandRegistry.registerAll(). Takes
    /// the PYTHONHOME path as a parameter rather than looking it up itself
    /// because `Bundle.module` for the vendored `python-stdlib` resource
    /// belongs to the TermuxSandboxApp target (that's the target whose
    /// Package.swift `resources:` list copies it in), not this one.
    public static func configure(pythonHome: String) {
        self.pythonHome = pythonHome
    }

    public static func register() {
        replaceCommand("python", "python_main", true)
        replaceCommand("python3", "python3_main", true)
    }
}

@_cdecl("python_main")
public func python_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    runPython(argc: argc, argv: argv)
}

@_cdecl("python3_main")
public func python3_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    runPython(argc: argc, argv: argv)
}

private func runPython(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let pythonHome = PythonCommand.pythonHome else {
        FileHandle.standardError.write(
            "python: PYTHONHOME not configured — PythonCommand.configure(pythonHome:) was never called\n"
                .data(using: .utf8)!
        )
        return 1
    }

    // Rebuild argv with "python" as argv[0] (CPython's CLI parser only ever
    // reads argv[1...] for -c/-m/script/flags, but Py_RunMain still expects
    // a conventional argv[0] program name to exist).
    var args = ["python"]
    if let argv, argc > 1 {
        args.append(contentsOf: (1..<Int(argc)).compactMap { i in
            argv[i].map { String(cString: $0) }
        })
    }

    var cArgs = args.map { strdup($0) }
    defer { cArgs.forEach { free($0) } }

    return cArgs.withUnsafeMutableBufferPointer { buffer in
        pythonHome.withCString { home in
            termux_run_python(Int32(buffer.count), buffer.baseAddress, home)
        }
    }
}
