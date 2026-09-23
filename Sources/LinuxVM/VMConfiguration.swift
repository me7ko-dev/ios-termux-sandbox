import CQEMUBootstrap
import Foundation

/// Everything that decides the QEMU command line. The exact same argument
/// set (paths aside) was booted end to end with qemu-system-aarch64 8.2 on
/// Linux before it went in here — see Docs/STATUS.md.
public struct VMConfiguration: Sendable {
    public var cpuCount: Int
    public var memoryMiB: Int
    public var diskSize: UInt64
    /// Loopback port QEMU forwards to the guest's sshd.
    public var sshPort: UInt16 = 2222
    /// Loopback port QEMU listens on for the guest's serial console.
    public var serialPort: UInt16 = 45022
    /// Loopback port for QMP (pause/resume/savevm).
    public var qmpPort: UInt16 = 45023
    /// Loopback port forwarded to the guest's VNC desktop (display :1).
    public var vncPort: UInt16 = 5901
    /// Internal qcow2 snapshot to restore instead of booting (`-loadvm`).
    public var restoreSnapshot: String?
    /// TCG translation cache size in MiB.
    public var translationCacheMiB: Int
    /// Masks snapd on the kernel command line. Seeding snaps (lxd, core22)
    /// on every boot costs minutes under emulation and almost nobody needs
    /// snaps in a phone terminal; apt is unaffected. Set to false to get the
    /// stock Ubuntu behaviour back.
    public var disableSnapd = true

    public init(cpuCount: Int, memoryMiB: Int, diskSize: UInt64, translationCacheMiB: Int) {
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.diskSize = diskSize
        self.translationCacheMiB = translationCacheMiB
    }

    @MainActor
    public static func recommended() -> VMConfiguration {
        let profile = DeviceProfile.current()
        return VMConfiguration(
            cpuCount: profile.cpuCount,
            memoryMiB: profile.memoryMiB,
            diskSize: 32 * 1024 * 1024 * 1024,
            translationCacheMiB: profile.translationCacheMiB
        )
    }

    // Never add/remove/reorder -device entries lightly: a snapshot saved by
    // one build only restores (-loadvm) on the exact same machine config.
    func arguments(store: ImageStore, seedISO: URL, dataDirectory: URL?) -> [String] {
        var kernelCommandLine = [
            "root=LABEL=\(UbuntuRelease.rootLabel)",
            "rw",
            "console=ttyAMA0",
            "ds=nocloud",
            // Read by /usr/local/sbin/ios-clock in the guest — the cloud
            // image kernel has no RTC driver (see Guest/cloud-init/user-data).
            "ios.epoch=\(Int(Date().timeIntervalSince1970))",
        ]
        if disableSnapd {
            kernelCommandLine += [
                "systemd.mask=snapd.service",
                "systemd.mask=snapd.socket",
                "systemd.mask=snapd.seeded.service",
            ]
        }

        var args = [
            "-nodefaults",
            "-display", "none",
            "-monitor", "none",
            "-machine", "virt",
            "-cpu", "cortex-a72",
            "-accel", "tcg,thread=multi,tb-size=\(translationCacheMiB)",
            "-smp", "\(cpuCount)",
            "-m", "\(memoryMiB)",
            "-kernel", store.kernelURL.path,
            "-initrd", store.initrdURL.path,
            "-append", kernelCommandLine.joined(separator: " "),
            "-drive", "if=none,id=root,file=\(store.diskURL.path),format=qcow2,discard=unmap",
            "-device", "virtio-blk-pci,drive=root",
            "-drive", "if=none,id=seed,file=\(seedISO.path),format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=seed",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(sshPort)-:22,hostfwd=tcp:127.0.0.1:\(vncPort)-:5901",
            // romfile= : no PXE option ROM, so QEMU doesn't go looking for
            // efi-virtio.rom in a data directory we don't ship.
            "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-device", "virtio-rng-pci",
            "-chardev", "socket,id=con0,host=127.0.0.1,port=\(serialPort),server=on,wait=off",
            "-serial", "chardev:con0",
            "-qmp", "tcp:127.0.0.1:\(qmpPort),server=on,wait=off",
        ]
        if let restoreSnapshot {
            args += ["-loadvm", restoreSnapshot]
        }
        if let dataDirectory {
            args += ["-L", dataDirectory.path]
        }
        return args
    }
}
