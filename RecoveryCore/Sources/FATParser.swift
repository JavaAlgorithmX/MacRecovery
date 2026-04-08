import Foundation
import os.log

private let log = Logger(subsystem: "com.macrecovery", category: "FATParser")

// MARK: - FATError

public enum FATError: Error, LocalizedError {
    case unreadableBootSector
    case notFAT(oemName: String)
    case unsupportedVariant(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableBootSector:      return "Cannot read FAT/exFAT boot sector"
        case .notFAT(let name):          return "Not a FAT volume (OEM ID: '\(name)')"
        case .unsupportedVariant(let v): return "Unsupported FAT variant: \(v)"
        }
    }
}

// MARK: - FATParser

/// Parses FAT32 and exFAT volumes, surfacing all files — both live (to mark sectors
/// as claimed) and deleted (the actual recovery targets).
///
/// **FAT32 strategy**
///  1. Parse the BIOS Parameter Block (BPB) from sector 0.
///  2. Load the FAT table into memory.
///  3. Walk the directory tree from the root cluster, following cluster chains.
///  4. 32-byte entries with `name[0] == 0xE5` are deleted; all others are live.
///
/// **exFAT strategy**
///  1. Parse the exFAT volume boot record from sector 0.
///  2. Load the FAT table.
///  3. Walk directory entry sets (primary + stream extension + name extensions).
///  4. Entry type bit-7 = 0 means the set was deleted.
///
/// Usage:
/// ```swift
/// let candidates = try FATParser.findFiles(device: device, sectorMap: map)
/// ```
public struct FATParser {

    // MARK: - Public API

    /// Find all files on a FAT32 or exFAT volume.
    /// Matches the `HFSParser.findDeletedFiles` / `APFSParser.findFiles` call surface.
    public static func findFiles(device: DiskDevice,
                                  sectorMap: SectorMap,
                                  onPath: ((String) -> Void)? = nil) throws -> [FileCandidate] {
        guard let boot = device.readSector(0), boot.count >= 512 else {
            throw FATError.unreadableBootSector
        }

        // Identify variant by OEM name (bytes 3–10)
        let oemName = String(bytes: boot[3..<min(11, boot.count)], encoding: .ascii) ?? ""
        if oemName.hasPrefix("EXFAT") {
            log.info("FATParser: detected exFAT")
            return try walkExFAT(device: device, boot: boot, sectorMap: sectorMap, onPath: onPath)
        }
        guard isFAT32(boot: boot) else {
            throw FATError.notFAT(oemName: oemName.trimmingCharacters(in: .whitespaces))
        }
        log.info("FATParser: detected FAT32")
        return try walkFAT32(device: device, boot: boot, sectorMap: sectorMap, onPath: onPath)
    }

    // MARK: - FAT32 variant check (internal — used by engine detection too)

    /// Returns true if `boot` looks like a FAT32 BPB (sector 0 of a FAT32 volume).
    static func isFAT32(boot: Data) -> Bool {
        guard boot.count >= 512 else { return false }
        // Boot sector signature
        guard boot[510] == 0x55, boot[511] == 0xAA else { return false }
        // FAT32: BPB_FATSz16 == 0, BPB_FATSz32 > 0
        let fatSize16 = boot.readLE16(at: 22)
        let fatSize32 = boot.readLE32(at: 36)
        if fatSize16 == 0, fatSize32 > 0 { return true }
        // Or: explicit system ID "FAT32   " at offset 82
        if boot.count >= 90 {
            let sysID = String(bytes: boot[82..<90], encoding: .ascii) ?? ""
            if sysID.hasPrefix("FAT32") { return true }
        }
        return false
    }

    // MARK: - FAT32 directory walker

    private static func walkFAT32(device: DiskDevice,
                                   boot: Data,
                                   sectorMap: SectorMap,
                                   onPath: ((String) -> Void)?) throws -> [FileCandidate] {
        // ── Parse BPB ────────────────────────────────────────────────────────
        let bytesPerSector    = Int(boot.readLE16(at: 11))
        let sectorsPerCluster = Int(boot[13])
        let reservedSectors   = Int(boot.readLE16(at: 14))
        let numFATs           = Int(boot[16])
        let fatSize32         = Int(boot.readLE32(at: 36))
        let rootCluster       = UInt32(boot.readLE32(at: 44))

        guard bytesPerSector > 0, sectorsPerCluster > 0,
              fatSize32 > 0, rootCluster >= 2 else {
            throw FATError.unsupportedVariant("FAT32 BPB fields are zero or invalid")
        }

        let fatStart  = UInt64(reservedSectors)
        let dataStart = UInt64(reservedSectors + numFATs * fatSize32)
        // Upper bound on valid cluster numbers
        let maxCluster = UInt32(2) + UInt32(min(
            UInt64(UInt32.max - 2),
            device.totalSectors > dataStart
                ? (device.totalSectors - dataStart) / UInt64(sectorsPerCluster)
                : 0
        ))

        // ── Load FAT (first copy) into memory ────────────────────────────────
        var fatData = Data(capacity: fatSize32 * bytesPerSector)
        for s in 0..<UInt64(fatSize32) {
            fatData.append(device.readSector(fatStart + s) ?? Data(count: bytesPerSector))
        }

        // ── FAT32 helpers ─────────────────────────────────────────────────────
        func nextCluster(_ c: UInt32) -> UInt32 {
            let off = Int(c) * 4
            guard off + 4 <= fatData.count else { return 0x0FFF_FFF7 }
            return fatData.readLE32(at: off) & 0x0FFF_FFFF
        }

        func clusterToSector(_ c: UInt32) -> UInt64 {
            dataStart + UInt64(c - 2) * UInt64(sectorsPerCluster)
        }

        /// Read all sectors in a cluster chain (capped at `maxClusters` to avoid loops).
        func readChain(_ start: UInt32, maxClusters: Int = 8192) -> Data {
            var out = Data()
            var c = start
            var guard_ = 0
            while c >= 2, c < maxCluster, c < 0x0FFF_FFF7, guard_ < maxClusters {
                let s0 = clusterToSector(c)
                for off in 0..<UInt64(sectorsPerCluster) {
                    out.append(device.readSector(s0 + off) ?? Data(count: bytesPerSector))
                }
                c = nextCluster(c)
                guard_ += 1
            }
            return out
        }

        // ── Recursive directory walk ─────────────────────────────────────────
        var candidates: [FileCandidate] = []
        var visited = Set<UInt32>()

        func walkDir(_ startCluster: UInt32, _ path: String) {
            guard startCluster >= 2, startCluster < maxCluster else { return }
            guard !visited.contains(startCluster) else { return }
            visited.insert(startCluster)

            let dir = readChain(startCluster)
            let entryCount = dir.count / 32

            for i in 0..<entryCount {
                let b = i * 32
                guard b + 32 <= dir.count else { break }

                let byte0 = dir[b]
                if byte0 == 0x00 { break }   // end of directory
                if byte0 == 0x2E { continue } // "." / ".."

                let attr = dir[b + 11]
                if attr == 0x0F          { continue }  // LFN entry
                if attr & 0x08 != 0      { continue }  // volume label

                let isDeleted = (byte0 == 0xE5)
                let isDir     = (attr  & 0x10 != 0)

                // Reconstruct short name.
                // Deleted entries have 0xE5 as first byte (not valid ASCII),
                // so we substitute '_' before decoding to avoid getting nil.
                var nameRaw = Array(dir[b..<(b + 8)])
                if isDeleted, !nameRaw.isEmpty { nameRaw[0] = UInt8(ascii: "_") }
                let rawName = String(bytes: nameRaw, encoding: .ascii)?
                    .trimmingCharacters(in: .init(charactersIn: " ")) ?? ""
                let rawExt  = String(bytes: dir[(b + 8)..<(b + 11)], encoding: .ascii)?
                    .trimmingCharacters(in: .init(charactersIn: " ")) ?? ""
                let shortName = rawExt.isEmpty ? rawName : "\(rawName).\(rawExt)"
                let fullPath  = path.isEmpty ? shortName : "\(path)/\(shortName)"

                let clHigh = UInt32(dir.readLE16(at: b + 20))
                let clLow  = UInt32(dir.readLE16(at: b + 26))
                let firstCluster = (clHigh << 16) | clLow
                let fileSize     = UInt64(dir.readLE32(at: b + 28))

                if isDir, !isDeleted, firstCluster >= 2 {
                    // Live directory — descend
                    onPath?(fullPath)
                    walkDir(firstCluster, fullPath)
                } else if !isDir, firstCluster >= 2, firstCluster < maxCluster {
                    // File (live or deleted)
                    let ext      = rawExt.lowercased()
                    let fileType = RecoveredFileType.from(extension: ext)
                    // Skip unknown extensions on live files; always include deleted
                    guard fileType != .unknown || isDeleted else { continue }

                    let startSector  = clusterToSector(firstCluster)
                    let clusterBytes = UInt64(sectorsPerCluster) * UInt64(bytesPerSector)
                    let byteCount    = fileSize > 0 ? fileSize : clusterBytes
                    let numClusters  = max(1, (byteCount + clusterBytes - 1) / clusterBytes)
                    let sectorCount  = numClusters * UInt64(sectorsPerCluster)
                    guard startSector + sectorCount <= device.totalSectors else { continue }

                    // Infer type from magic bytes when extension is unknown
                    let effectiveType = fileType != .unknown
                        ? fileType
                        : inferType(startSector: startSector, device: device)

                    let modDate = fatDateToDate(
                        dateFld: dir.readLE16(at: b + 24),
                        timeFld: dir.readLE16(at: b + 22)
                    )
                    onPath?(fullPath)

                    candidates.append(FileCandidate.fromInode(
                        fileType:         effectiveType,
                        startSector:      startSector,
                        sectorCount:      sectorCount,
                        estimatedSize:    byteCount,
                        originalName:     shortName,
                        originalPath:     "/\(fullPath)",
                        modificationDate: modDate
                    ))

                    // Mark live file sectors so deep scan can skip them
                    if !isDeleted {
                        for s in 0..<sectorCount {
                            sectorMap.mark(sector: startSector + s, as: .candidate)
                        }
                    }
                }
            }
        }

        walkDir(rootCluster, "")
        log.info("FATParser (FAT32): found \(candidates.count) file(s)")
        return candidates
    }

    // MARK: - exFAT directory walker

    private static func walkExFAT(device: DiskDevice,
                                   boot: Data,
                                   sectorMap: SectorMap,
                                   onPath: ((String) -> Void)?) throws -> [FileCandidate] {
        guard boot.count >= 512 else { throw FATError.unreadableBootSector }

        // ── Parse exFAT VBR ───────────────────────────────────────────────────
        let bpsSh = Int(boot[108])  // BytesPerSectorShift
        let spcSh = Int(boot[109])  // SectorsPerClusterShift
        guard bpsSh >= 9, bpsSh <= 12 else {
            throw FATError.unsupportedVariant("exFAT: invalid BytesPerSectorShift \(bpsSh)")
        }

        let bytesPerSector    = 1 << bpsSh
        let sectorsPerCluster = 1 << spcSh
        let fatOffset         = UInt64(boot.readLE32(at: 80))
        let fatLength         = UInt64(boot.readLE32(at: 84))
        let heapOffset        = UInt64(boot.readLE32(at: 88))
        let clusterCount      = UInt32(boot.readLE32(at: 92))
        let rootCluster       = UInt32(boot.readLE32(at: 96))

        guard rootCluster >= 2, heapOffset > 0, fatLength > 0 else {
            throw FATError.unsupportedVariant("exFAT: invalid VBR fields")
        }

        // ── Load FAT ──────────────────────────────────────────────────────────
        var fatData = Data(capacity: Int(fatLength) * bytesPerSector)
        for s in 0..<fatLength {
            fatData.append(device.readSector(fatOffset + s) ?? Data(count: bytesPerSector))
        }

        // ── exFAT helpers ─────────────────────────────────────────────────────
        func nextClusterEx(_ c: UInt32) -> UInt32 {
            let off = Int(c) * 4
            guard off + 4 <= fatData.count else { return 0xFFFF_FFFF }
            return fatData.readLE32(at: off)
        }

        func clusterToSectorEx(_ c: UInt32) -> UInt64 {
            heapOffset + UInt64(c - 2) * UInt64(sectorsPerCluster)
        }

        func readChainEx(_ start: UInt32, maxClusters: Int = 8192) -> Data {
            var out = Data()
            var c = start
            var guard_ = 0
            while c >= 2, c <= clusterCount + 1, c < 0xFFFF_FFF7, guard_ < maxClusters {
                let s0 = clusterToSectorEx(c)
                for off in 0..<UInt64(sectorsPerCluster) {
                    out.append(device.readSector(s0 + off) ?? Data(count: bytesPerSector))
                }
                c = nextClusterEx(c)
                guard_ += 1
            }
            return out
        }

        // ── Recursive directory walk ──────────────────────────────────────────
        var candidates: [FileCandidate] = []
        var visited = Set<UInt32>()

        func walkDirEx(_ startCluster: UInt32, _ path: String) {
            guard startCluster >= 2, startCluster <= clusterCount + 1 else { return }
            guard !visited.contains(startCluster) else { return }
            visited.insert(startCluster)

            let dir = readChainEx(startCluster)
            let n   = dir.count / 32
            var i   = 0

            while i < n {
                let b = i * 32
                guard b + 32 <= dir.count else { break }

                let entryType = dir[b]
                if entryType == 0x00 { break }   // end of directory

                let typeBase = entryType & 0x7F   // strip active bit
                let isActive = (entryType & 0x80) != 0

                // Only handle file primary entries (0x85 active, 0x05 deleted)
                guard typeBase == 0x05 else { i += 1; continue }

                let secondaryCount = Int(dir[b + 1])
                guard secondaryCount >= 2,
                      (i + secondaryCount) * 32 <= dir.count else {
                    i += secondaryCount + 1; continue
                }

                let attributes = dir.readLE16(at: b + 4)
                let isDir      = (attributes & 0x10) != 0

                // Stream extension (must immediately follow, type 0xC0 or 0x40)
                let si = (i + 1) * 32
                guard si + 32 <= dir.count,
                      (dir[si] & 0x7F) == 0x40 else {
                    i += secondaryCount + 1; continue
                }

                let nameLen      = Int(dir[si + 3])
                let dataLen      = dir.readLE64(at: si + 24)
                let firstCluster = UInt32(dir.readLE32(at: si + 20))

                // Collect UTF-16LE filename from name extension entries
                var fileName = ""
                for j in 2...secondaryCount {
                    let ni = (i + j) * 32
                    guard ni + 32 <= dir.count,
                          (dir[ni] & 0x7F) == 0x41 else { break }
                    for k in 0..<15 {
                        let co = ni + 2 + k * 2
                        guard co + 2 <= dir.count else { break }
                        let cu = dir.readLE16(at: co)
                        if cu == 0 { break }
                        if let scalar = Unicode.Scalar(cu) { fileName.append(Character(scalar)) }
                    }
                    if fileName.count >= nameLen { break }
                }

                guard !fileName.isEmpty else { i += secondaryCount + 1; continue }

                let fullPath = path.isEmpty ? fileName : "\(path)/\(fileName)"

                if isDir, isActive, firstCluster >= 2 {
                    onPath?(fullPath)
                    walkDirEx(firstCluster, fullPath)
                } else if !isDir, firstCluster >= 2, firstCluster <= clusterCount + 1 {
                    let ext      = (fileName as NSString).pathExtension.lowercased()
                    let fileType = RecoveredFileType.from(extension: ext)
                    guard fileType != .unknown || !isActive else {
                        i += secondaryCount + 1; continue
                    }

                    let startSec    = clusterToSectorEx(firstCluster)
                    let cBytes      = UInt64(sectorsPerCluster) * UInt64(bytesPerSector)
                    let byteCount   = dataLen > 0 ? dataLen : cBytes
                    let numClusters = max(1, (byteCount + cBytes - 1) / cBytes)
                    let sectorCount = numClusters * UInt64(sectorsPerCluster)
                    guard startSec + sectorCount <= device.totalSectors else {
                        i += secondaryCount + 1; continue
                    }

                    let effectiveType = fileType != .unknown
                        ? fileType
                        : inferType(startSector: startSec, device: device)

                    onPath?(fullPath)
                    candidates.append(FileCandidate.fromInode(
                        fileType:         effectiveType,
                        startSector:      startSec,
                        sectorCount:      sectorCount,
                        estimatedSize:    byteCount,
                        originalName:     fileName,
                        originalPath:     "/\(fullPath)",
                        modificationDate: nil
                    ))

                    if isActive {
                        for s in 0..<sectorCount {
                            sectorMap.mark(sector: startSec + s, as: .candidate)
                        }
                    }
                }

                i += secondaryCount + 1
            }
        }

        walkDirEx(rootCluster, "")
        log.info("FATParser (exFAT): found \(candidates.count) file(s)")
        return candidates
    }

    // MARK: - Helpers

    /// Sniff the first sector at `startSector` for magic-byte file type hints.
    private static func inferType(startSector: UInt64, device: DiskDevice) -> RecoveredFileType {
        guard let sec = device.readSector(startSector) else { return .unknown }
        let detections = SignatureScanner.scan(
            buffer: sec,
            bufferStartByte: startSector * UInt64(device.sectorSize),
            sectorSize: device.sectorSize
        )
        return detections.first?.fileType ?? .unknown
    }

    /// Convert FAT-packed date + time fields to a Swift `Date`.
    ///
    /// FAT date: bits 15-9 = year offset from 1980, 8-5 = month (1–12), 4-0 = day
    /// FAT time: bits 15-11 = hour (0–23), 10-5 = minute, 4-0 = seconds/2
    static func fatDateToDate(dateFld: UInt16, timeFld: UInt16) -> Date? {
        guard dateFld != 0 else { return nil }
        let year   = Int((dateFld >> 9) & 0x7F) + 1980
        let month  = Int((dateFld >> 5) & 0x0F)
        let day    = Int( dateFld       & 0x1F)
        let hour   = Int((timeFld >> 11) & 0x1F)
        let minute = Int((timeFld >>  5) & 0x3F)
        let second = Int( timeFld        & 0x1F) * 2
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)
    }
}
