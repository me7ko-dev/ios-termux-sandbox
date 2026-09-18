import Foundation
#if canImport(UIKit)
import UIKit
#endif
import ios_system

/// `sysinfo` — a Termux-style `neofetch`-lite command with zero external
/// dependencies. Its only job is to prove the full registration/dispatch/
/// stdout-redirection pipeline works before anything heavier (SSH, Python)
/// is layered on top.
///
/// Registration happens once at app launch — see
/// `CommandRegistry.registerCustomCommands()` in TermuxSandboxApp.
public enum SysInfoCommand {

    /// Call once during app startup, before the first command is dispatched.
    public static func register() {
        // ios_system's real signature (verified against master's ios_system.h)
        // is `replaceCommand(NSString* commandName, NSString* functionName, bool)`
        // — it resolves the function by name via dlsym, which finds this symbol
        // whether it's statically linked (our case, via SwiftPM) or loaded from
        // a separate framework. `@_cdecl` keeps the symbol name unmangled so
        // dlsym can find it.
        replaceCommand("sysinfo", "sysinfo_main", true)
    }
}

@_cdecl("sysinfo_main")
public func sysinfo_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    let device = deviceModelIdentifier()
    let systemVersion: String
    let sandboxHome = NSHomeDirectory()

    #if canImport(UIKit)
    systemVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    #else
    systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
    #endif

    let (freeBytes, totalBytes) = diskSpace()
    let processMemoryBytes = residentMemoryBytes()

    print("device      : \(device)")
    print("os          : \(systemVersion)")
    print("sandbox home: \(sandboxHome)")
    print("disk free   : \(formatBytes(freeBytes)) / \(formatBytes(totalBytes))")
    print("app memory  : \(formatBytes(processMemoryBytes))")
    print("shell       : ios_system (in-process, no fork/exec)")

    return 0
}

private func deviceModelIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    let identifier = mirror.children.reduce(into: "") { result, element in
        guard let value = element.value as? Int8, value != 0 else { return }
        result.append(Character(UnicodeScalar(UInt8(value))))
    }
    return identifier.isEmpty ? "unknown" : identifier
}

private func diskSpace() -> (free: Int64, total: Int64) {
    guard let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first,
          let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
          let free = attributes[.systemFreeSize] as? Int64,
          let total = attributes[.systemSize] as? Int64
    else {
        return (0, 0)
    }
    return (free, total)
}

private func residentMemoryBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
