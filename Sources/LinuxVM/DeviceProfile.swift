import CQEMUBootstrap
import Foundation
import UIKit

/// Per-device tuning. The generic fallback sizes everything from what the
/// process can actually get; known devices get hand-picked values.
///
/// iPhone 13 Pro Max (iPhone14,3): A15 = 2 performance + 4 efficiency
/// cores, 6 GB RAM, 2778x1284 px display (926x428 pt landscape, @3x).
///  - 4 vCPUs: MTTCG runs one host thread per vCPU; two land on P-cores,
///    two on E-cores, which still beats 2 vCPUs for apt/compiles and a
///    desktop session (measured guidance from UTM users, not by us).
///  - 2560 MiB guest RAM: XFCE + a browser-class app fits; with the
///    increased-memory-limit entitlement the app can hold ~3.5-4 GB, and
///    QEMU + a 256 MiB TCG cache + UI need the rest.
///  - Desktop 1616x744: the landscape screen at 1.75x its point size (a
///    multiple of 8 for VNC). With Xft DPI 120 (desktop-install.sh) text is
///    readable without zooming; pinch to zoom still works.
public struct DeviceProfile: Sendable {
    public let name: String
    public let cpuCount: Int
    public let memoryMiB: Int
    public let translationCacheMiB: Int
    public let desktopWidth: Int
    public let desktopHeight: Int

    public var desktopGeometry: String { "\(desktopWidth)x\(desktopHeight)" }

    /// The desktop size for another pixels-per-point factor than the
    /// profile's 1.75 (fewer pixels = less for the emulated guest to draw
    /// and send), still a multiple of 8.
    public func desktopGeometry(scale: Double) -> String {
        let factor = scale / 1.75
        let width = Int(Double(desktopWidth) * factor) / 8 * 8
        let height = Int(Double(desktopHeight) * factor) / 8 * 8
        return "\(width)x\(height)"
    }

    static var machineIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static let known: [String: DeviceProfile] = [
        "iPhone14,3": DeviceProfile(
            name: "iPhone 13 Pro Max",
            cpuCount: 4, memoryMiB: 2560, translationCacheMiB: 256,
            desktopWidth: 1616, desktopHeight: 744
        ),
    ]

    /// The hand-picked RAM assumes the increased-memory-limit entitlement,
    /// which free (personal team) signing doesn't grant. Without it iOS
    /// allows the whole app ~3 GB, so a 2560 MiB guest gets the app killed
    /// once the guest has touched most of its RAM (Claude Code, a desktop)
    /// or during savevm, which reads all of it. Leave room for QEMU itself,
    /// its TCG cache and the UI.
    func fitted(toAvailableMiB available: Int) -> DeviceProfile {
        guard available > 0 else { return self }
        let budget = (available - translationCacheMiB - 768) / 256 * 256
        guard budget < memoryMiB else { return self }
        return DeviceProfile(
            name: name, cpuCount: cpuCount, memoryMiB: max(768, budget),
            translationCacheMiB: translationCacheMiB,
            desktopWidth: desktopWidth, desktopHeight: desktopHeight
        )
    }

    @MainActor
    public static func current() -> DeviceProfile {
        if let profile = known[machineIdentifier] {
            return profile.fitted(toAvailableMiB: Int(lvm_available_memory() / (1024 * 1024)))
        }
        let available = Int(lvm_available_memory() / (1024 * 1024))
        let budget = available > 0 ? available : Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) / 3
        let bounds = UIScreen.main.bounds
        let long = max(bounds.width, bounds.height)
        let short = min(bounds.width, bounds.height)
        return DeviceProfile(
            name: machineIdentifier,
            cpuCount: max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)),
            memoryMiB: min(4096, max(768, (budget / 2) / 256 * 256)),
            translationCacheMiB: budget >= 3072 ? 256 : 128,
            desktopWidth: Int(long * 1.75) / 8 * 8,
            desktopHeight: Int(short * 1.75) / 8 * 8
        )
    }
}
