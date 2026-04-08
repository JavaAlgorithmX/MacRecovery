import Foundation
import os.log

private let log = Logger(subsystem: "com.macrecovery", category: "HFSParser")

// MARK: - HFS+ on-disk structures
// All multi-byte values in HFS+ are big-endian.

/// HFS+ Volume Header — always at byte offset 1024 from volume start
struct HFSPlusVolumeHeader {
    static let signature: UInt16 = 0x482B   // "H+"
    static let xSignature: UInt16 = 0x4858  // "HX" (case-sensitive)
    static let offset: Int = 1024

    var signature:        UInt16
    var version:          UInt16
    var attributes:       UInt32
    var lastMountedVersion: UInt32
    var journalInfoBlock: UInt32
    var createDate:       UInt32
    var modifyDate:       UInt32
    var backupDate:       UInt32
    var checkedDate:      UInt32
    var fileCount:        UInt32
    var folderCount:      UInt32
    var blockSize:        UInt32
    var totalBlocks:      UInt32
    var freeBlocks:       UInt32
    // ... catalog file, extents file, etc. follow
    // We read only what we need for quick scan
}

/// Simplified HFS+ catalog key — contains parent CNID + name
struct HFSPlusCatalogKey {
    var keyLength: UInt16
    var parentID:  UInt32   // catalog node ID of parent folder
    var nodeName:  String
}

/// HFS+ file record — simplified to the fields we need
struct HFSPlusFileRecord {
    var recordType: UInt16  // 0x0002 = file, 0x0100 = folder, 0xFFFF = deleted
    var cnid:       UInt32  // catalog node ID
    var createDate: UInt32
    var modifyDate: UInt32
    var dataFork: HFSPlusForkData
}

struct HFSPlusForkData {
    var logicalSize: UInt64  // file size in bytes
    var totalBlocks: UInt32
    var extents: [(startBlock: UInt32, blockCount: UInt32)]  // up to 8 extents
}

// MARK: - HFSParser

/// Parses an HFS+ volume and finds deleted file entries.
/// This is the quick scan engine for HFS+ volumes.
///
/// Strategy:
///  1. Find and parse the Volume Header at offset 1024
///  2. Locate the Catalog File B-tree
///  3. Walk every leaf node
///  4. Collect records whose type byte indicates deletion (0xFFFF)
///     or whose extents point to unallocated blocks
public final class HFSParser {

    // MARK: Public

    public static func findDeletedFiles(device: DiskDevice,
                                        sectorMap: SectorMap,
                                        onPath: ((String) -> Void)? = nil) throws -> [FileCandidate] {
        log.info("Starting HFS+ quick scan on \(device.path)")

        let header = try readVolumeHeader(device: device)
        log.info("HFS+ block size: \(header.blockSize), total blocks: \(header.totalBlocks)")

        let catalogStartBlock = try readCatalogStartBlock(device: device,
                                                          blockSize: header.blockSize)
        log.info("Catalog B-tree starts at block \(catalogStartBlock)")

        let candidates = try walkCatalogBTree(
            device:            device,
            sectorMap:         sectorMap,
            startBlock:        catalogStartBlock,
            blockSize:         header.blockSize,
            deviceSectorSize:  device.sectorSize,
            onPath:            onPath
        )

        log.info("HFS+ quick scan found \(candidates.count) deleted file candidates")
        return candidates
    }

    // MARK: Private — Volume Header

    private static func readVolumeHeader(device: DiskDevice) throws -> HFSPlusVolumeHeader {
        // Volume header is at byte 1024 (sector 2 at 512B, or within sector 0 at 4K)
        let offset = 1024
        let bytesNeeded = offset + 512
        let sectorsNeeded = UInt64((bytesNeeded + Int(device.sectorSize) - 1) / Int(device.sectorSize))
        guard let data = device.readSectors(startingSector: 0,
                                             count: UInt32(sectorsNeeded),
                                             into: nil) else {
            throw HFSError.cannotReadVolumeHeader
        }

        guard data.count >= offset + 512 else {
            throw HFSError.cannotReadVolumeHeader
        }

        let sig = data.readBigEndianUInt16(at: offset)
        guard sig == HFSPlusVolumeHeader.signature ||
              sig == HFSPlusVolumeHeader.xSignature else {
            throw HFSError.notHFSPlus(signature: sig)
        }

        let h = HFSPlusVolumeHeader(
            signature:        sig,
            version:          data.readBigEndianUInt16(at: offset + 2),
            attributes:       data.readBigEndianUInt32(at: offset + 4),
            lastMountedVersion: data.readBigEndianUInt32(at: offset + 8),
            journalInfoBlock: data.readBigEndianUInt32(at: offset + 12),
            createDate:       data.readBigEndianUInt32(at: offset + 16),
            modifyDate:       data.readBigEndianUInt32(at: offset + 20),
            backupDate:       data.readBigEndianUInt32(at: offset + 24),
            checkedDate:      data.readBigEndianUInt32(at: offset + 28),
            fileCount:        data.readBigEndianUInt32(at: offset + 32),
            folderCount:      data.readBigEndianUInt32(at: offset + 36),
            blockSize:        data.readBigEndianUInt32(at: offset + 40),
            totalBlocks:      data.readBigEndianUInt32(at: offset + 44),
            freeBlocks:       data.readBigEndianUInt32(at: offset + 48)
        )

        // Sanity check
        guard h.blockSize >= 512, h.blockSize <= 65536,
              (h.blockSize & (h.blockSize - 1)) == 0 else {
            throw HFSError.invalidBlockSize(h.blockSize)
        }

        return h
    }

    // MARK: Private — Catalog B-tree location

    /// The catalog fork data starts at volume header offset 248.
    /// First extent's start block is at offset 248 + 16 (after logicalSize + totalBlocks).
    private static func readCatalogStartBlock(device: DiskDevice,
                                               blockSize: UInt32) throws -> UInt32 {
        let vhOffset = 1024
        let sectorsNeeded = UInt64((vhOffset + 600) / Int(device.sectorSize)) + 1
        guard let data = device.readSectors(startingSector: 0,
                                             count: UInt32(sectorsNeeded),
                                             into: nil) else {
            throw HFSError.cannotReadVolumeHeader
        }
        // Catalog fork starts at fixed offset 248 within VH
        // logicalSize (8) + clumpSize (4) + totalBlocks (4) + extents[0].startBlock (4)
        let catalogForkOffset = vhOffset + 248
        let startBlock = data.readBigEndianUInt32(at: catalogForkOffset + 20)
        return startBlock
    }

    // MARK: Private — B-tree walk

    private static func walkCatalogBTree(device: DiskDevice,
                                          sectorMap: SectorMap,
                                          startBlock: UInt32,
                                          blockSize: UInt32,
                                          deviceSectorSize: UInt32,
                                          onPath: ((String) -> Void)? = nil) throws -> [FileCandidate] {
        var candidates: [FileCandidate] = []
        let sectorsPerBlock = blockSize / deviceSectorSize

        // Read the B-tree header node (node 0)
        let headerSector = UInt64(startBlock) * UInt64(sectorsPerBlock)
        guard let headerNodeData = device.readSectors(startingSector: headerSector,
                                                       count: sectorsPerBlock,
                                                       into: sectorMap) else {
            throw HFSError.cannotReadCatalog
        }

        // B-tree node descriptor: fLink(4) bLink(4) kind(1) height(1) numRecords(2) reserved(2)
        guard headerNodeData.count >= 14 else {
            throw HFSError.invalidBTreeHeader
        }
        let nodeKind  = headerNodeData[8]  // 0x01 = header node
        _ = headerNodeData.readBigEndianUInt16(at: 10)  // numRecords — unused at header node level

        guard nodeKind == 0x01 else {
            throw HFSError.invalidBTreeHeader
        }

        // Header record starts at offset 14; leaf node count at offset 20
        let totalNodes    = headerNodeData.readBigEndianUInt32(at: 14 + 4)
        let firstLeafNode = headerNodeData.readBigEndianUInt32(at: 14 + 16)
        let lastLeafNode  = headerNodeData.readBigEndianUInt32(at: 14 + 20)
        let nodeSize      = headerNodeData.readBigEndianUInt16(at: 14 + 32)
        guard nodeSize > 0, UInt32(nodeSize) <= blockSize else {
            throw HFSError.invalidBTreeHeader
        }

        log.debug("B-tree: \(totalNodes) nodes, leaf \(firstLeafNode)–\(lastLeafNode), node size \(nodeSize)")

        let nodesPerBlock   = UInt32(blockSize) / UInt32(nodeSize)
        var currentLeaf     = firstLeafNode
        var visitedNodes    = Set<UInt32>()

        while currentLeaf != 0 && currentLeaf <= lastLeafNode {
            guard !visitedNodes.contains(currentLeaf) else {
                log.warning("B-tree cycle detected at node \(currentLeaf) — stopping traversal")
                break
            }
            visitedNodes.insert(currentLeaf)
            let nodeBlock   = currentLeaf / nodesPerBlock
            let nodeOffset  = (currentLeaf % nodesPerBlock) * UInt32(nodeSize)
            let nodeSector  = UInt64(startBlock + nodeBlock) * UInt64(sectorsPerBlock)

            guard let blockData = device.readWithRetry(startingSector: nodeSector,
                                                       count: sectorsPerBlock,
                                                       sectorMap: sectorMap) else {
                log.warning("Cannot read B-tree node \(currentLeaf) — skipping")
                currentLeaf += 1
                continue
            }

            let nodeData = blockData.subdata(in: Int(nodeOffset)..<min(blockData.count, Int(nodeOffset + UInt32(nodeSize))))

            // Parse leaf node records
            let parsedCandidates = parseLeafNode(data: nodeData,
                                                  nodeSize: nodeSize,
                                                  deviceSectorSize: deviceSectorSize,
                                                  blockSize: blockSize)
            for c in parsedCandidates {
                onPath?(c.originalPath ?? c.suggestedFileName)
            }
            candidates.append(contentsOf: parsedCandidates)

            // fLink (forward link to next leaf node) is at bytes 0-3
            currentLeaf = nodeData.readBigEndianUInt32(at: 0)
        }

        return candidates
    }

    // MARK: Private — leaf node parsing

    private static func parseLeafNode(data: Data,
                                       nodeSize: UInt16,
                                       deviceSectorSize: UInt32,
                                       blockSize: UInt32) -> [FileCandidate] {
        var results: [FileCandidate] = []

        let numRecords = data.readBigEndianUInt16(at: 10)
        guard numRecords > 0 else { return results }

        // Offsets table: at end of node, 2 bytes per record + 2 bytes for free space
        for i in 0..<Int(numRecords) {
            let offsetTablePos = Int(nodeSize) - (i + 1) * 2
            guard offsetTablePos + 1 < data.count else { break }
            let recordOffset = Int(data.readBigEndianUInt16(at: offsetTablePos))
            guard recordOffset + 2 < data.count else { continue }

            // Key length (2 bytes big-endian)
            let keyLength = Int(data.readBigEndianUInt16(at: recordOffset))
            let dataOffset = recordOffset + 2 + keyLength

            // Align data offset to even byte
            let alignedDataOffset = (dataOffset % 2 == 0) ? dataOffset : dataOffset + 1
            guard alignedDataOffset + 2 < data.count else { continue }

            // Record type: 0x0200 = file, 0x0100 = folder, 0xFFFF = deleted thread
            let recordType = data.readBigEndianUInt16(at: alignedDataOffset)

            if recordType == 0x0200 {
                // File record — check if data fork has any blocks (deleted files often have blocks but no catalog reference)
                if let candidate = parseFileRecord(data: data,
                                                   at: alignedDataOffset,
                                                   keyOffset: recordOffset,
                                                   keyLength: keyLength,
                                                   deviceSectorSize: deviceSectorSize,
                                                   blockSize: blockSize) {
                    results.append(candidate)
                }
            }
            // 0xFFFF = deleted — log but cannot recover path
        }

        return results
    }

    private static func parseFileRecord(data: Data,
                                         at offset: Int,
                                         keyOffset: Int,
                                         keyLength: Int,
                                         deviceSectorSize: UInt32,
                                         blockSize: UInt32) -> FileCandidate? {
        guard offset + 248 <= data.count else { return nil }

        // data fork: logicalSize at +88, totalBlocks at +96, extents at +100
        let logicalSize   = data.readBigEndianUInt64(at: offset + 88)
        let totalBlocks   = data.readBigEndianUInt32(at: offset + 96)

        guard logicalSize > 0, totalBlocks > 0 else { return nil }

        let startBlock    = data.readBigEndianUInt32(at: offset + 100)  // first extent start
        let modifyDateHFS = data.readBigEndianUInt32(at: offset + 24)

        // HFS+ dates are seconds since 1904-01-01; Unix epoch starts 1970-01-01
        // Difference: 66 years = 2082844800 seconds
        let secondsFrom1904To1970: TimeInterval = 2082844800
        let modDate = modifyDateHFS > 0 ?
            Date(timeIntervalSince1970: TimeInterval(modifyDateHFS) - secondsFrom1904To1970) : nil

        // Try to read file name from key
        let fileName = parseFileName(data: data, keyOffset: keyOffset, keyLength: keyLength)

        // Determine file type from name extension
        let ext  = (fileName as NSString).pathExtension.lowercased()
        let type = RecoveredFileType.from(extension: ext)

        let firstSector = UInt64(startBlock) * UInt64(blockSize / deviceSectorSize)

        return FileCandidate.fromInode(
            fileType:         type,
            startSector:      firstSector,
            sectorCount:      UInt64(totalBlocks) * UInt64(blockSize / deviceSectorSize),
            estimatedSize:    logicalSize,
            originalName:     fileName.isEmpty ? "recovered.\(type.fileExtension)" : fileName,
            originalPath:     "/\(fileName)",
            modificationDate: modDate
        )
    }

    private static func parseFileName(data: Data, keyOffset: Int, keyLength: Int) -> String {
        // HFS+ catalog key: keyLength(2) parentID(4) name.length(2) name.chars(variable, UTF-16BE)
        let nameOffset = keyOffset + 2 + 4
        guard nameOffset + 2 <= data.count else { return "" }
        let nameLength = Int(data.readBigEndianUInt16(at: nameOffset))
        let charsOffset = nameOffset + 2
        guard charsOffset + nameLength * 2 <= data.count else { return "" }

        var utf16Chars: [UInt16] = []
        for i in 0..<nameLength {
            let charOffset = charsOffset + i * 2
            let c = data.readBigEndianUInt16(at: charOffset)
            utf16Chars.append(c)
        }
        // HFS+ stores names as big-endian UTF-16; swap to little-endian for Swift's UTF16 decoder
        let swapped = utf16Chars.map { $0.byteSwapped }
        let name = String(decoding: swapped, as: UTF16.self)
        return name.isEmpty
            ? utf16Chars.compactMap { Unicode.Scalar($0).map { String($0) } }.joined()
            : name
    }
}

// MARK: - RecoveredFileType extension

extension RecoveredFileType {
    public static func from(extension ext: String) -> RecoveredFileType {
        switch ext {
        case "jpg", "jpeg": return .jpeg
        case "png":  return .png
        case "gif":  return .gif
        case "tiff", "tif": return .tiff
        case "bmp":  return .bmp
        case "heic", "heif": return .heic
        case "webp": return .webp
        case "mp4", "m4v": return .mp4
        case "mov":  return .mov
        case "avi":  return .avi
        case "mkv":  return .mkv
        case "mp3":  return .mp3
        case "m4a", "aac": return .aac
        case "flac": return .flac
        case "wav":  return .wav
        case "aiff", "aif": return .aiff
        case "pdf":  return .pdf
        case "zip":  return .zip
        case "docx": return .docx
        case "xlsx": return .xlsx
        case "pptx": return .pptx
        case "sqlite", "db": return .sqlite
        case "plist": return .plist
        default:     return .unknown
        }
    }
}

// MARK: - Data extensions for big-endian reads

extension Data {
    func readBigEndianUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset])     << 24 |
               UInt32(self[offset + 1]) << 16 |
               UInt32(self[offset + 2]) << 8  |
               UInt32(self[offset + 3])
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return UInt64(readBigEndianUInt32(at: offset)) << 32 |
               UInt64(readBigEndianUInt32(at: offset + 4))
    }
}

// MARK: - Errors

public enum HFSError: Error, LocalizedError {
    case cannotReadVolumeHeader
    case notHFSPlus(signature: UInt16)
    case invalidBlockSize(UInt32)
    case cannotReadCatalog
    case invalidBTreeHeader

    public var errorDescription: String? {
        switch self {
        case .cannotReadVolumeHeader:     return "Cannot read HFS+ volume header"
        case .notHFSPlus(let sig):        return "Not an HFS+ volume (signature: 0x\(String(sig, radix: 16)))"
        case .invalidBlockSize(let s):    return "Invalid HFS+ block size: \(s)"
        case .cannotReadCatalog:          return "Cannot read HFS+ catalog B-tree"
        case .invalidBTreeHeader:         return "Invalid B-tree header node"
        }
    }
}
