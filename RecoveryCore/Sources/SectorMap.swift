import Foundation

// MARK: - Sector state

/// Every 512-byte (or 4096-byte) block on disk has one of these states.
/// The SectorMap is the single source of truth for scan progress and
/// bad-sector tracking. Everything else in the engine reads from it.
public enum SectorState: UInt8 {
    case unread      = 0   // not yet visited
    case clean       = 1   // read successfully, no candidate found
    case candidate   = 2   // read successfully, contains a file signature or inode
    case badSector   = 3   // I/O error — log and skip
    case skipped     = 4   // intentionally bypassed (e.g. known-zero region)
}

// MARK: - SectorMap

/// A compact, thread-safe bitmap over every sector on a device.
/// Uses one byte per sector (fast random access, ~2 GB per 1 TB at 512B sectors).
///
/// Thread safety: all mutations go through a serial DispatchQueue so the
/// progress reporter and scanner can run concurrently without locks in callers.
public final class SectorMap: @unchecked Sendable {

    // MARK: Public interface

    public let totalSectors: UInt64
    public let sectorSize: UInt32

    /// Total bytes on the device
    public var totalBytes: UInt64 { totalSectors * UInt64(sectorSize) }

    public init(totalSectors: UInt64, sectorSize: UInt32 = 512) {
        guard totalSectors <= UInt64(Int.max) else {
            fatalError("Device too large: \(totalSectors) sectors exceeds addressable memory")
        }
        self.totalSectors = totalSectors
        self.sectorSize   = sectorSize
        self.map          = [UInt8](repeating: SectorState.unread.rawValue,
                                   count: Int(totalSectors))
    }

    // MARK: Read / write

    public func status(at sector: UInt64) -> SectorState {
        guard sector < totalSectors else { return .skipped }
        return queue.sync { SectorState(rawValue: map[Int(sector)]) ?? .unread }
    }

    public func mark(sector: UInt64, as state: SectorState) {
        guard sector < totalSectors else { return }
        queue.sync { map[Int(sector)] = state.rawValue }
    }

    public func mark(range: Range<UInt64>, as state: SectorState) {
        let clamped = range.clamped(to: 0..<totalSectors)
        queue.sync {
            for i in clamped { map[Int(i)] = state.rawValue }
        }
    }

    // MARK: Progress reporting

    public struct Progress {
        public let scanned:    UInt64   // sectors with any state != .unread
        public let total:      UInt64
        public let badSectors: UInt64
        public let candidates: UInt64

        public var percentComplete: Double {
            total == 0 ? 0 : Double(scanned) / Double(total) * 100
        }
    }

    public func progress() -> Progress {
        queue.sync {
            var scanned:    UInt64 = 0
            var bad:        UInt64 = 0
            var candidates: UInt64 = 0
            for byte in map {
                let s = SectorState(rawValue: byte) ?? .unread
                if s != .unread  { scanned    += 1 }
                if s == .badSector  { bad       += 1 }
                if s == .candidate  { candidates += 1 }
            }
            return Progress(scanned: scanned, total: totalSectors,
                            badSectors: bad, candidates: candidates)
        }
    }

    /// Returns the first unread sector at or after `from`, or nil if none remain.
    public func nextUnread(from: UInt64 = 0) -> UInt64? {
        queue.sync {
            for i in Int(from)..<map.count {
                if map[i] == SectorState.unread.rawValue { return UInt64(i) }
            }
            return nil
        }
    }

    /// All bad sector numbers — for logging and the sector-map UI later.
    public func badSectors() -> [UInt64] {
        queue.sync {
            map.enumerated().compactMap { idx, byte in
                byte == SectorState.badSector.rawValue ? UInt64(idx) : nil
            }
        }
    }

    // MARK: Persistence (pause/resume support)

    /// Save map state to disk so a scan can be resumed later.
    public func save(to url: URL) throws {
        let data = queue.sync { Data(map) }
        try data.write(to: url, options: .atomic)
    }

    /// Load a previously saved map. Validates sector count matches.
    public static func load(from url: URL, totalSectors: UInt64,
                            sectorSize: UInt32 = 512) throws -> SectorMap {
        let data = try Data(contentsOf: url)
        guard data.count == Int(totalSectors) else {
            throw SectorMapError.sectorCountMismatch(
                expected: totalSectors, got: UInt64(data.count))
        }
        let m = SectorMap(totalSectors: totalSectors, sectorSize: sectorSize)
        m.queue.sync { m.map = [UInt8](data) }
        return m
    }

    // MARK: Private

    private var map: [UInt8]
    private let queue = DispatchQueue(label: "com.macrecovery.sectormap")
}

// MARK: - Errors

public enum SectorMapError: Error, LocalizedError {
    case sectorCountMismatch(expected: UInt64, got: UInt64)

    public var errorDescription: String? {
        switch self {
        case .sectorCountMismatch(let e, let g):
            return "Sector map size mismatch: expected \(e) sectors, file has \(g)"
        }
    }
}
