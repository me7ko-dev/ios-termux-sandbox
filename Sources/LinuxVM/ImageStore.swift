import CryptoKit
import Foundation

/// Owns the VM's files under Application Support/LinuxVM:
///
///     vmlinuz, initrd              kernel + initramfs (pinned, verified)
///     ubuntu-22.04-base.qcow2      pristine download, kept for "Reset"
///     disk.qcow2                   the VM's actual root disk (grown copy)
///
/// Application Support is excluded from iCloud backup here — a multi-GB
/// disk image has no business in the user's backup quota.
public final class ImageStore: @unchecked Sendable {
    public struct Progress: Sendable {
        public let fileName: String
        public let receivedBytes: Int64
        public let totalBytes: Int64
    }

    public enum Error: Swift.Error, LocalizedError {
        case checksumMismatch(file: String, expected: String, actual: String)
        case httpStatus(Int, URL)

        public var errorDescription: String? {
            switch self {
            case let .checksumMismatch(file, expected, actual):
                return "\(file): SHA-256 mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
            case let .httpStatus(code, url):
                return "HTTP \(code) downloading \(url.lastPathComponent)"
            }
        }
    }

    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("LinuxVM", isDirectory: true)
        }
    }

    public var kernelURL: URL { directory.appendingPathComponent(UbuntuRelease.kernel.localName) }
    public var initrdURL: URL { directory.appendingPathComponent(UbuntuRelease.initrd.localName) }
    public var baseDiskURL: URL { directory.appendingPathComponent(UbuntuRelease.rootDisk.localName) }
    public var diskURL: URL { directory.appendingPathComponent("disk.qcow2") }

    /// Everything needed to boot is on disk (checksums were verified when
    /// the files were downloaded).
    public var isInstalled: Bool {
        [kernelURL, initrdURL, diskURL].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Downloads whatever is missing, verifies each file's SHA-256, then
    /// creates the working disk and grows it to `diskSize` bytes.
    public func install(diskSize: UInt64, progress: @escaping @Sendable (Progress) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)

        for file in UbuntuRelease.all {
            let destination = directory.appendingPathComponent(file.localName)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try await download(file, to: destination, progress: progress)
        }

        if !FileManager.default.fileExists(atPath: diskURL.path) {
            let partial = diskURL.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.copyItem(at: baseDiskURL, to: partial)
            try QCOW2.grow(partial, toVirtualSize: diskSize)
            try FileManager.default.moveItem(at: partial, to: diskURL)
        }
    }

    /// Throws away the VM's disk (all installed packages and files) and
    /// recreates it from the pristine download on next `install`.
    public func resetDisk() throws {
        if FileManager.default.fileExists(atPath: diskURL.path) {
            try FileManager.default.removeItem(at: diskURL)
        }
    }

    public func diskVirtualSize() -> UInt64? {
        try? QCOW2.virtualSize(of: diskURL)
    }

    private func download(_ file: UbuntuRelease.File, to destination: URL,
                          progress: @escaping @Sendable (Progress) -> Void) async throws {
        let url = UbuntuRelease.baseURL.appendingPathComponent(file.remotePath)
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        // A plain download task (not URLSession.bytes) — streams straight to
        // disk at full speed; progress comes from the task's Progress object.
        var observation: NSKeyValueObservation?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    continuation.resume(throwing: Error.httpStatus(http.statusCode, url))
                    return
                }
                do {
                    // The temporary file is deleted once this handler returns.
                    try FileManager.default.moveItem(at: location!, to: partial)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.completedUnitCount) { taskProgress, _ in
                let total = taskProgress.totalUnitCount > 0 ? taskProgress.totalUnitCount : file.approximateSize
                progress(Progress(fileName: file.localName, receivedBytes: taskProgress.completedUnitCount, totalBytes: total))
            }
            task.resume()
        }
        observation?.invalidate()

        let digest = try sha256(of: partial)
        guard digest == file.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw Error.checksumMismatch(file: file.localName, expected: file.sha256, actual: digest)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
