import Foundation
import os.log

private let log = Logger(subsystem: "com.macrecovery", category: "DiskDevice")

// MARK: - DiskDevice

/// A read-only abstraction over a block device or disk image file.
///
/// All reads are strictly read-only. The device is opened with O_RDONLY and
/// never written to. Bad sectors are caught, logged, and reported via the
/// SectorMap rather than crashing.
///
/// Works with:
///   - Raw block devices:  /dev/disk2, /dev/disk2s1
///   - Disk image files:   /path/to/image.dmg  (for testing)
///
/// Note: opening /dev/diskN directly requires Full Disk Access (TCC) or the
/// caller must be the privileged XPC helper running as root.
public final class DiskDevice {

    // MARK: Public properties

    public let path: String
    public let sectorSize: UInt32
    public let totalSectors: UInt64
    public let totalBytes: UInt64

    // MARK: Init / open

    public static func open(path: String,
                            sectorSize: UInt32 = 512) throws -> DiskDevice {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            throw DiskError.openFailed(path: path, errno: errno)
        }

        // Determine device size.
        // For block devices use DKIOCGETBLOCKCOUNT ioctl.
        // For regular files (disk images) use fstat.
        var totalBytes: UInt64 = 0

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            Darwin.close(fd)
            throw DiskError.statFailed(path: path, errno: errno)
        }

        if (st.st_mode & S_IFMT) == S_IFBLK {
            // Block device — use IOKit ioctl
            var blockCount: UInt64 = 0
            var blockSize:  UInt32 = 0
            if ioctl(fd, _DKIOCGETBLOCKCOUNT, &blockCount) == 0,
               ioctl(fd, _DKIOCGETBLOCKSIZE, &blockSize) == 0 {
                totalBytes = blockCount * UInt64(blockSize)
            } else {
                Darwin.close(fd)
                throw DiskError.ioctlFailed(path: path, errno: errno)
            }
        } else {
            // Regular file (disk image)
            totalBytes = UInt64(st.st_size)
        }

        let totalSectors = totalBytes / UInt64(sectorSize)
        log.info("Opened \(path): \(totalBytes) bytes, \(totalSectors) sectors @ \(sectorSize)B")

        return DiskDevice(path: path, fd: fd,
                          sectorSize: sectorSize,
                          totalSectors: totalSectors,
                          totalBytes: totalBytes)
    }

    deinit { Darwin.close(fd) }

    // MARK: Reading

    /// Read `count` sectors starting at `sector` into a Data buffer.
    /// Returns nil and marks sectors bad on I/O error rather than throwing —
    /// partial reads are normal on damaged drives.
    @discardableResult
    public func readSectors(startingSector: UInt64,
                            count: UInt32,
                            into sectorMap: SectorMap?) -> Data? {
        let byteOffset = Int64(startingSector) * Int64(sectorSize)
        let byteCount  = Int(count) * Int(sectorSize)

        guard byteOffset + Int64(byteCount) <= Int64(totalBytes) else {
            log.warning("Read out of bounds: sector \(startingSector)+\(count)")
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: byteCount)
        let bytesRead = pread(fd, &buffer, byteCount, byteOffset)

        if bytesRead == byteCount {
            // Full successful read
            return Data(buffer)
        } else if bytesRead > 0 {
            // Partial read — rare but possible near device end
            log.warning("Partial read at sector \(startingSector): got \(bytesRead)/\(byteCount)")
            return Data(buffer.prefix(bytesRead))
        } else {
            // I/O error — mark bad sectors in map
            log.error("I/O error at sector \(startingSector): errno \(errno)")
            if let map = sectorMap {
                let range = startingSector..<(startingSector + UInt64(count))
                map.mark(range: range, as: .badSector)
            }
            return nil
        }
    }

    /// Convenience: read a single sector
    public func readSector(_ sector: UInt64,
                           into sectorMap: SectorMap? = nil) -> Data? {
        readSectors(startingSector: sector, count: 1, into: sectorMap)
    }

    /// Read with automatic bad-sector retry using smaller read sizes.
    /// On a damaged drive, a 64-sector read may fail while individual
    /// sectors within it are actually readable.
    public func readWithRetry(startingSector: UInt64,
                              count: UInt32,
                              sectorMap: SectorMap) -> Data? {
        // Try the full read first (fast path)
        if let data = readSectors(startingSector: startingSector,
                                  count: count, into: nil) {
            sectorMap.mark(range: startingSector..<(startingSector + UInt64(count)),
                           as: .clean)
            return data
        }

        // Fall back to sector-by-sector reads
        log.info("Falling back to sector-by-sector read at \(startingSector)")
        var result = Data()
        var anyGood = false

        for i in 0..<UInt64(count) {
            let s = startingSector + i
            if let sectorData = readSectors(startingSector: s, count: 1, into: sectorMap) {
                result.append(sectorData)
                sectorMap.mark(sector: s, as: .clean)
                anyGood = true
            } else {
                // Pad with zeros so downstream offsets stay valid
                result.append(Data(count: Int(sectorSize)))
                sectorMap.mark(sector: s, as: .badSector)
            }
        }

        return anyGood ? result : nil
    }

    // MARK: Private

    private let fd: Int32

    private init(path: String, fd: Int32, sectorSize: UInt32,
                 totalSectors: UInt64, totalBytes: UInt64) {
        self.path         = path
        self.fd           = fd
        self.sectorSize   = sectorSize
        self.totalSectors = totalSectors
        self.totalBytes   = totalBytes
    }
}

// MARK: - IOKit ioctl constants
// These mirror the values from <sys/disk.h> — defined here so we don't need
// a bridging header just for two constants.

private let _DKIOCGETBLOCKCOUNT = IOKit_DKIOCGETBLOCKCOUNT()
private let _DKIOCGETBLOCKSIZE  = IOKit_DKIOCGETBLOCKSIZE()

// Inline C shims — compiled as part of the Swift package via a small C target
// if needed. For now we define them directly using the standard ioctl encoding.
// DKIOCGETBLOCKCOUNT = _IOR('d', 24, uint64_t)  = 0x40086418
// DKIOCGETBLOCKSIZE  = _IOR('d', 20, uint32_t)  = 0x40046414
private func IOKit_DKIOCGETBLOCKCOUNT() -> UInt { 0x40086418 }
private func IOKit_DKIOCGETBLOCKSIZE()  -> UInt { 0x40046414 }

// MARK: - Errors

public enum DiskError: Error, LocalizedError {
    case openFailed(path: String, errno: Int32)
    case statFailed(path: String, errno: Int32)
    case ioctlFailed(path: String, errno: Int32)
    case readFailed(sector: UInt64, errno: Int32)
    case outOfBounds(sector: UInt64, total: UInt64)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let p, let e):
            return "Cannot open \(p): \(String(cString: strerror(e)))"
        case .statFailed(let p, let e):
            return "Cannot stat \(p): \(String(cString: strerror(e)))"
        case .ioctlFailed(let p, let e):
            return "ioctl failed on \(p): \(String(cString: strerror(e)))"
        case .readFailed(let s, let e):
            return "Read failed at sector \(s): \(String(cString: strerror(e)))"
        case .outOfBounds(let s, let t):
            return "Sector \(s) out of range (device has \(t) sectors)"
        }
    }
}
