import Foundation

/// Minimal qcow2 header editing — just enough to grow the virtual disk size
/// of the downloaded cloud image in place, the one thing `qemu-img resize`
/// would otherwise be needed for (and there is no qemu-img on iOS).
///
/// Growing is safe without touching data clusters: new guest sectors are
/// simply unallocated (read as zeros). The only structure that has to cover
/// the new size is the L1 table; this only enlarges it within the clusters
/// already allocated to it (one 64 KiB cluster maps 4 TiB), zeroing the new
/// entries, and refuses anything that would need the table moved. Verified
/// against the real Ubuntu image with `qemu-img check` (see Docs/STATUS.md).
enum QCOW2 {
    enum Error: Swift.Error, LocalizedError {
        case notQCOW2
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notQCOW2: return "Not a qcow2 image"
            case .unsupported(let why): return "Cannot grow qcow2 image: \(why)"
            }
        }
    }

    /// Returns the image's virtual size after the call.
    @discardableResult
    static func grow(_ url: URL, toVirtualSize newSize: UInt64) throws -> UInt64 {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let header = try read(handle, at: 0, count: 72)
        guard header.prefix(4) == Data([0x51, 0x46, 0x49, 0xFB]) else { throw Error.notQCOW2 }

        let clusterBits = be32(header, 20)
        let size = be64(header, 24)
        let cryptMethod = be32(header, 32)
        let l1Size = UInt64(be32(header, 36))
        let l1Offset = be64(header, 40)
        let snapshotCount = be32(header, 60)

        guard cryptMethod == 0 else { throw Error.unsupported("encrypted") }
        guard snapshotCount == 0 else { throw Error.unsupported("has internal snapshots") }
        guard newSize > size else { return size }

        let clusterSize = UInt64(1) << UInt64(clusterBits)
        let bytesPerL1Entry = clusterSize * (clusterSize / 8)
        let newL1Size = (newSize + bytesPerL1Entry - 1) / bytesPerL1Entry
        let l1Clusters = (l1Size * 8 + clusterSize - 1) / clusterSize
        let l1Capacity = l1Clusters * clusterSize / 8
        guard newL1Size <= l1Capacity else {
            throw Error.unsupported("L1 table would need to be reallocated")
        }
        guard newL1Size <= UInt64(UInt32.max) else { throw Error.unsupported("size too large") }

        if newL1Size > l1Size {
            try handle.seek(toOffset: l1Offset + l1Size * 8)
            handle.write(Data(count: Int((newL1Size - l1Size) * 8)))
        }
        try handle.seek(toOffset: 24)
        handle.write(bigEndian(newSize))
        try handle.seek(toOffset: 36)
        handle.write(bigEndian(UInt32(newL1Size)))
        try handle.synchronize()
        return newSize
    }

    static func virtualSize(of url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try read(handle, at: 0, count: 32)
        guard header.prefix(4) == Data([0x51, 0x46, 0x49, 0xFB]) else { throw Error.notQCOW2 }
        return be64(header, 24)
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw Error.notQCOW2
        }
        return data
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
