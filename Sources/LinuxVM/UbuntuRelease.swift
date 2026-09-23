import Foundation

/// The exact Ubuntu build the app installs. Pinned to a dated release
/// directory (not `release/`, which is re-pointed every few weeks) so the
/// SHA-256 values below stay valid; they were copied from that directory's
/// SHA256SUMS files and double-checked against a real download.
///
/// Boots with QEMU's direct kernel boot (`-kernel`/`-initrd`) instead of
/// UEFI firmware: one fewer file, and noticeably faster to reach userspace
/// under TCG.
public enum UbuntuRelease {
    public static let name = "Ubuntu 22.04 LTS (Jammy) arm64 — cloud image 20260913"

    static let baseURL = URL(string: "https://cloud-images.ubuntu.com/releases/22.04/release-20260913/")!

    public struct File: Sendable {
        public let remotePath: String
        public let localName: String
        public let sha256: String
        public let approximateSize: Int64
    }

    static let kernel = File(
        remotePath: "unpacked/ubuntu-22.04-server-cloudimg-arm64-vmlinuz-generic",
        localName: "vmlinuz",
        sha256: "3d61a3fc6c50ad4724de8149847204d601443c86ef3b494a95d49baf9a7b1605",
        approximateSize: 15_400_717
    )

    static let initrd = File(
        remotePath: "unpacked/ubuntu-22.04-server-cloudimg-arm64-initrd-generic",
        localName: "initrd",
        sha256: "9c827b22e5b98be89cf8c408732a066cd111ba8614adf949c9349c968dd3b65f",
        approximateSize: 33_113_446
    )

    /// qcow2, 2.2 GiB virtual size — grown in place before first boot, see
    /// `QCOW2.grow`.
    static let rootDisk = File(
        remotePath: "ubuntu-22.04-server-cloudimg-arm64.img",
        localName: "ubuntu-22.04-base.qcow2",
        sha256: "ab5fcc80611a98bf999018045119d87b3a0e7c78f3b43b254b93d5c22bae3ff6",
        approximateSize: 704_972_800
    )

    static let all = [kernel, initrd, rootDisk]

    /// Root filesystem label inside the cloud image.
    static let rootLabel = "cloudimg-rootfs"
}
