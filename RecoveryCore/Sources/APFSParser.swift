import Foundation
import os.log

private let log = Logger(subsystem: "com.macrecovery", category: "APFSParser")

// MARK: - APFS On-Disk Constants
// All APFS multi-byte values are little-endian.

enum APFS {
    // Magic numbers
    static let nxMagic:  UInt32 = 0x4253584E  // "NXSB" LE
    static let apMagic:  UInt32 = 0x42535041  // "APSB" LE
    static let btMagic:  UInt32 = 0x4642544E  // "BTRN" LE (B-tree node)
    static let omMagic:  UInt32 = 0x4F4D4150  // "OMAP" LE

    // Object types (low 16 bits of type field)
    static let objTypeNxSuperblock: UInt32  = 0x00000001
    static let objTypeOmap:         UInt32  = 0x0000000B
    static let objTypeFSTree:       UInt32  = 0x0000000E
    static let objTypeBTreeNode:    UInt32  = 0x00000002

    // B-tree node flags
    static let btnFlagRoot:    UInt16 = 0x0001
    static let btnFlagLeaf:    UInt16 = 0x0002
    static let btnFlagFixed:   UInt16 = 0x0004

    // File-system record types (j_obj_types)
    static let jObjTypeInode:    UInt8 = 0x03
    static let jObjTypeDirRec:   UInt8 = 0x09  // directory record (dentry)

    // Inode internal flags
    static let inodeFlagIsDir: UInt64 = 0x00000010

    // NX superblock layout offsets (after 32-byte object header)
    static let nxBlockSize:       Int = 32        // offset within obj header
    static let nxOmapOidOffset:   Int = 32 + 96   // nx_omap_oid
    static let nxMaxFileSystems:  Int = 100
    static let nxFSArrayOffset:   Int = 32 + 104  // nx_fs_oid[0..99]

    // Volume superblock (APSB) layout offsets (after 32-byte obj header)
    static let apOmapOidOffset:   Int = 32 + 96   // apfs_omap_oid
    static let apRootTreeOidOffset: Int = 32 + 104 // apfs_root_tree_oid

    // Object map (omap) node offsets (after 32-byte obj header)
    static let omTreeOidOffset: Int = 32 + 40     // om_tree_oid

    // B-tree node header (after 32-byte obj header)
    static let btnFlagsOffset:    Int = 32 + 0    // btn_flags
    static let btnNKeysOffset:    Int = 32 + 4    // btn_nkeys  (UInt32)
    static let btnTableSpaceOffset: Int = 32 + 8  // toc offset (UInt16) + length (UInt16)
    static let btnKeyAreaOffset:  Int = 32 + 12   // key area offset (UInt16) + length (UInt16)
    static let btnFreeAreaOffset: Int = 32 + 16   // free area offset/length
    static let btnValAreaOffset:  Int = 32 + 20   // val area offset (UInt16) + length (UInt16)

    // Fixed entry sizes for fixed-key/val nodes
    static let omapKeySize: Int = 16   // omap_key: oid(8) + xid(8)
    static let omapValSize: Int = 16   // omap_val: flags(4) + size(4) + paddr(8)

    // J-key header
    static let jKeySize: Int = 8       // obj_id_and_type (UInt64)

    // Inode val minimum size
    static let inodeValMinSize: Int = 92

    // HFS->Unix epoch delta (not needed for APFS — APFS uses Unix nanoseconds)
}

// MARK: - APFS data structures

struct APFSObjectHeader {
    var checksum: UInt64
    var oid:      UInt64
    var xid:      UInt64
    var type:     UInt32
    var subtype:  UInt32
    static let size = 32
}

struct APFSOmapKey {
    var oid: UInt64
    var xid: UInt64
}

struct APFSOmapVal {
    var flags: UInt32
    var size:  UInt32
    var paddr: UInt64   // physical block address
}

struct APFSInodeVal {
    var parentId:        UInt64
    var privateId:       UInt64
    var createTime:      UInt64  // nanoseconds since Unix epoch
    var modTime:         UInt64
    var changeTime:      UInt64
    var accessTime:      UInt64
    var internalFlags:   UInt64
    var nchildren:       Int32   // or nlink for files
    var defaultProtClass: UInt32
    var writeGenCounter: UInt32
    var bsdFlags:        UInt32
    var uid:             UInt32
    var gid:             UInt32
    var mode:            UInt16
    var pad1:            UInt16
    var uncompressedSz:  UInt64
}

// MARK: - APFSParser

/// Parses an APFS container/volume and finds file entries.
/// This is the Phase 2 quick scan engine for APFS volumes.
///
/// Strategy:
///  1. Read Container Superblock (NXSB) at block 0 — get block size + volume OIDs
///  2. Resolve each volume OID → physical block via Container Object Map
///  3. Read Volume Superblock (APSB) — get file-system B-tree OID
///  4. Resolve fs-tree OID via Volume Object Map
///  5. Walk B-tree leaf nodes, collect inode + dentry records
///  6. Emit FileCandidate for every file found
public final class APFSParser {

    // MARK: - Public entry point

    public static func findFiles(device: DiskDevice,
                                 sectorMap: SectorMap,
                                 onPath: ((String) -> Void)? = nil) throws -> [FileCandidate] {
        log.info("Starting APFS quick scan on \(device.path)")

        let nx = try readContainerSuperblock(device: device)
        log.info("APFS block size: \(nx.blockSize), \(nx.volumeOids.count) volume(s) found")

        let containerOmap = try readOmapTree(device: device,
                                             omapOid: nx.omapOid,
                                             blockSize: nx.blockSize)

        var allCandidates: [FileCandidate] = []

        for volOid in nx.volumeOids {
            guard volOid != 0 else { continue }
            do {
                let candidates = try scanVolume(device: device,
                                                sectorMap: sectorMap,
                                                volumeOid: volOid,
                                                containerOmap: containerOmap,
                                                blockSize: nx.blockSize,
                                                onPath: onPath)
                allCandidates.append(contentsOf: candidates)
                log.info("Volume oid=\(volOid): \(candidates.count) file candidates")
            } catch {
                log.warning("Volume oid=\(volOid) scan failed: \(error.localizedDescription)")
            }
        }

        log.info("APFS quick scan total: \(allCandidates.count) candidates")
        return allCandidates
    }

    // MARK: - Container Superblock

    private struct NXInfo {
        var blockSize:  UInt32
        var omapOid:    UInt64
        var volumeOids: [UInt64]
    }

    private static func readContainerSuperblock(device: DiskDevice) throws -> NXInfo {
        guard let data = device.readSector(0) else {
            throw APFSError.cannotReadSuperblock
        }
        guard data.count >= 512 else { throw APFSError.cannotReadSuperblock }

        // Magic at offset 32 (after checksum+oid+xid+type+subtype = 32 bytes)
        let magic = data.readLE32(at: 32)
        guard magic == APFS.nxMagic else {
            throw APFSError.notAPFS(magic: magic)
        }

        let blockSize = data.readLE32(at: 36)
        guard blockSize >= 512, blockSize <= 65536,
              (blockSize & (blockSize - 1)) == 0 else {
            throw APFSError.invalidBlockSize(blockSize)
        }

        // Re-read full block if blockSize > sectorSize
        let fullBlock: Data
        if blockSize > device.sectorSize {
            let sectorsNeeded = UInt32(blockSize / device.sectorSize)
            guard let d = device.readSectors(startingSector: 0,
                                             count: sectorsNeeded, into: nil) else {
                throw APFSError.cannotReadSuperblock
            }
            fullBlock = d
        } else {
            fullBlock = data
        }

        guard fullBlock.count >= Int(blockSize) else {
            throw APFSError.cannotReadSuperblock
        }

        let omapOid = fullBlock.readLE64(at: APFS.nxOmapOidOffset)

        // Read volume OID array (up to 100 entries at nx_fs_oid)
        var volumeOids: [UInt64] = []
        let arrayBase = APFS.nxFSArrayOffset
        for i in 0..<APFS.nxMaxFileSystems {
            let off = arrayBase + i * 8
            guard off + 8 <= fullBlock.count else { break }
            let oid = fullBlock.readLE64(at: off)
            if oid == 0 { break }
            volumeOids.append(oid)
        }

        return NXInfo(blockSize: blockSize, omapOid: omapOid, volumeOids: volumeOids)
    }

    // MARK: - Object Map

    /// Lightweight in-memory OID→paddr lookup built from an omap B-tree.
    private typealias OmapCache = [UInt64: UInt64]  // oid → physical block

    private static func readOmapTree(device: DiskDevice,
                                     omapOid: UInt64,
                                     blockSize: UInt32) throws -> OmapCache {
        // Omap root is at physical block == omapOid (virtual==physical for container omap)
        let omapBlock = try readPhysicalBlock(device: device,
                                              block: omapOid,
                                              blockSize: blockSize)

        // omap header: after obj header, om_tree_oid at +40
        let treeOid = omapBlock.readLE64(at: APFS.omTreeOidOffset)
        let treeBlock = try readPhysicalBlock(device: device,
                                              block: treeOid,
                                              blockSize: blockSize)

        var cache = OmapCache()
        try walkOmapBTree(device: device,
                          nodeData: treeBlock,
                          blockSize: blockSize,
                          cache: &cache,
                          depth: 0)
        return cache
    }

    private static func walkOmapBTree(device: DiskDevice,
                                      nodeData: Data,
                                      blockSize: UInt32,
                                      cache: inout OmapCache,
                                      depth: Int) throws {
        guard depth < 10 else { return }  // cycle guard

        let btnFlags = nodeData.readLE16(at: APFS.btnFlagsOffset)
        let isLeaf   = (btnFlags & APFS.btnFlagLeaf) != 0
        let nKeys    = nodeData.readLE32(at: APFS.btnNKeysOffset)

        if isLeaf {
            // Fixed-size key+val omap leaf: entries packed after the node header
            // Each entry: omap_key(16 bytes) + omap_val(16 bytes)
            let entryBase = APFSObjectHeader.size + 24  // after btn header (24 bytes of toc/key/val offsets)
            for i in 0..<Int(nKeys) {
                let keyOff = entryBase + i * (APFS.omapKeySize + APFS.omapValSize)
                let valOff = keyOff + APFS.omapKeySize
                guard valOff + APFS.omapValSize <= nodeData.count else { break }
                let oid   = nodeData.readLE64(at: keyOff)
                let paddr = nodeData.readLE64(at: valOff + 8)  // skip flags(4)+size(4)
                if oid != 0 { cache[oid] = paddr }
            }
        } else {
            // Internal node: entries are oid(8)+xid(8) key + child_oid(8) val
            let entryBase = APFSObjectHeader.size + 24
            let entrySize = APFS.omapKeySize + 8  // key + pointer
            for i in 0..<Int(nKeys) {
                let keyOff   = entryBase + i * entrySize
                let childOff = keyOff + APFS.omapKeySize
                guard childOff + 8 <= nodeData.count else { break }
                let childOid = nodeData.readLE64(at: childOff)
                if childOid == 0 { continue }
                if let childData = try? readPhysicalBlock(device: device,
                                                          block: childOid,
                                                          blockSize: blockSize) {
                    try walkOmapBTree(device: device, nodeData: childData,
                                      blockSize: blockSize, cache: &cache, depth: depth + 1)
                }
            }
        }
    }

    // MARK: - Volume scan

    private static func scanVolume(device: DiskDevice,
                                   sectorMap: SectorMap,
                                   volumeOid: UInt64,
                                   containerOmap: OmapCache,
                                   blockSize: UInt32,
                                   onPath: ((String) -> Void)? = nil) throws -> [FileCandidate] {
        // Resolve volume OID → physical block via container omap
        guard let volBlock = containerOmap[volumeOid] else {
            log.warning("Volume oid=\(volumeOid) not in container omap")
            return []
        }

        let volData = try readPhysicalBlock(device: device, block: volBlock, blockSize: blockSize)

        // Verify APSB magic at offset 32
        let magic = volData.readLE32(at: 32)
        guard magic == APFS.apMagic else {
            log.warning("Volume block \(volBlock) has unexpected magic 0x\(String(magic, radix: 16))")
            return []
        }

        let volOmapOid   = volData.readLE64(at: APFS.apOmapOidOffset)
        let fsTreeOid    = volData.readLE64(at: APFS.apRootTreeOidOffset)

        // Build volume omap
        let volOmap = try readOmapTree(device: device, omapOid: volOmapOid, blockSize: blockSize)

        // Resolve fs-tree OID
        guard let fsTreeBlock = volOmap[fsTreeOid] else {
            log.warning("FS tree oid=\(fsTreeOid) not found in volume omap")
            return []
        }

        let fsTreeData = try readPhysicalBlock(device: device,
                                               block: fsTreeBlock,
                                               blockSize: blockSize)

        // Walk the file-system B-tree
        var inodes: [UInt64: APFSInodeRecord] = [:]
        var dirEntries: [APFSDirEntry] = []
        var visited = Set<UInt64>()

        try walkFSBTree(device: device,
                        nodeData: fsTreeData,
                        volOmap: volOmap,
                        blockSize: blockSize,
                        inodes: &inodes,
                        dirEntries: &dirEntries,
                        visited: &visited,
                        depth: 0)

        return buildCandidates(inodes: inodes,
                               dirEntries: dirEntries,
                               blockSize: blockSize,
                               sectorSize: device.sectorSize,
                               sectorMap: sectorMap,
                               onPath: onPath)
    }

    // MARK: - FS B-tree walk

    private struct APFSInodeRecord {
        var inodeId:  UInt64
        var size:     UInt64
        var modTime:  UInt64   // nanoseconds since epoch
        var isDir:    Bool
        var blockAddr: UInt64  // first physical block (0 if unknown)
    }

    private struct APFSDirEntry {
        var parentId: UInt64
        var inodeId:  UInt64
        var name:     String
    }

    private static func walkFSBTree(device: DiskDevice,
                                    nodeData: Data,
                                    volOmap: OmapCache,
                                    blockSize: UInt32,
                                    inodes: inout [UInt64: APFSInodeRecord],
                                    dirEntries: inout [APFSDirEntry],
                                    visited: inout Set<UInt64>,
                                    depth: Int) throws {
        guard depth < 16, nodeData.count >= APFSObjectHeader.size + 24 else { return }

        let nodeOid = nodeData.readLE64(at: 8)
        guard !visited.contains(nodeOid) else { return }
        visited.insert(nodeOid)

        let btnFlags = nodeData.readLE16(at: APFS.btnFlagsOffset)
        let isLeaf   = (btnFlags & APFS.btnFlagLeaf) != 0
        let nKeys    = Int(nodeData.readLE32(at: APFS.btnNKeysOffset))

        // Table-of-contents: starts at tableSpaceOff (relative to keys area start)
        // Key area starts right after the btn header (obj header 32 + btn header 24 = 56)
        let tocOff    = Int(nodeData.readLE16(at: APFSObjectHeader.size + 0))
        let keyOff    = Int(nodeData.readLE16(at: APFSObjectHeader.size + 4))
        let _ /* freeOff */ = Int(nodeData.readLE16(at: APFSObjectHeader.size + 8))
        let valOff    = Int(nodeData.readLE16(at: APFSObjectHeader.size + 12))

        // The areas are relative to the end of the fixed btn header (offset 56)
        let headerEnd  = APFSObjectHeader.size + 24  // 56
        let tocBase    = headerEnd + tocOff
        let keyBase    = headerEnd + keyOff
        let valBase    = Int(blockSize) - valOff  // vals grow from end of block

        guard tocBase >= 0, keyBase >= 0, valBase >= 0,
              tocBase <= nodeData.count, keyBase <= nodeData.count,
              valBase <= nodeData.count else { return }

        // Each TOC entry for a variable-size node: key_off(2)+key_len(2)+val_off(2)+val_len(2) = 8 bytes
        let tocEntrySize = 8

        for i in 0..<nKeys {
            let toc = tocBase + i * tocEntrySize
            guard toc + tocEntrySize <= nodeData.count else { break }

            let kOff = Int(nodeData.readLE16(at: toc + 0))
            let kLen = Int(nodeData.readLE16(at: toc + 2))
            let vOff = Int(nodeData.readLE16(at: toc + 4))
            let vLen = Int(nodeData.readLE16(at: toc + 6))

            let kStart = keyBase + kOff
            let vStart = valBase - vOff   // vals are indexed from end of block

            guard kStart + kLen <= nodeData.count,
                  kStart >= 0, vStart >= 0,
                  vStart + vLen <= nodeData.count,
                  kLen >= APFS.jKeySize else { continue }

            // J-key: obj_id_and_type (UInt64 LE)
            // high 4 bits = type, low 60 bits = object id
            let jKey    = nodeData.readLE64(at: kStart)
            let objType = UInt8((jKey >> 60) & 0x0F)
            let objId   = jKey & 0x0FFFFFFFFFFFFFFF

            if isLeaf {
                switch objType {
                case APFS.jObjTypeInode:
                    if let inode = parseInode(data: nodeData, at: vStart, len: vLen, inodeId: objId) {
                        inodes[objId] = inode
                    }
                case APFS.jObjTypeDirRec:
                    if let dentry = parseDirEntry(data: nodeData,
                                                  kStart: kStart, kLen: kLen,
                                                  vStart: vStart, vLen: vLen,
                                                  parentId: objId) {
                        dirEntries.append(dentry)
                    }
                default:
                    break
                }
            } else {
                // Internal node: value is child virtual OID (8 bytes)
                guard vLen >= 8 else { continue }
                let childVOid = nodeData.readLE64(at: vStart)
                guard let childPBlock = volOmap[childVOid] else { continue }
                if let childData = try? readPhysicalBlock(device: device,
                                                          block: childPBlock,
                                                          blockSize: blockSize) {
                    try walkFSBTree(device: device,
                                    nodeData: childData,
                                    volOmap: volOmap,
                                    blockSize: blockSize,
                                    inodes: &inodes,
                                    dirEntries: &dirEntries,
                                    visited: &visited,
                                    depth: depth + 1)
                }
            }
        }
    }

    // MARK: - Record parsing

    private static func parseInode(data: Data, at offset: Int, len: Int,
                                   inodeId: UInt64) -> APFSInodeRecord? {
        guard len >= APFS.inodeValMinSize, offset + len <= data.count else { return nil }

        // inode_val layout (little-endian):
        //  0: parent_id (8)
        //  8: private_id (8)
        // 16: create_time (8) — nanoseconds
        // 24: mod_time (8)
        // 32: change_time (8)
        // 40: access_time (8)
        // 48: internal_flags (8)
        // 56: nchildren/nlink (4)
        // 60: default_protection_class (4)
        // 64: write_gen_counter (4)
        // 68: bsd_flags (4)
        // 72: uid (4)
        // 76: gid (4)
        // 80: mode (2)
        // 82: pad1 (2)
        // 84: uncompressed_size (8)  [only if has_uncompressed_size xfield]

        let internalFlags = data.readLE64(at: offset + 48)
        let isDir         = (data.readLE16(at: offset + 80) & 0xF000) == 0x4000  // S_IFDIR
        let modTimeNs     = data.readLE64(at: offset + 24)

        // uncompressed_size field: present if xfields follow (we read it tentatively)
        var fileSize: UInt64 = 0
        if len >= 92 {
            fileSize = data.readLE64(at: offset + 84)
        }
        _ = internalFlags  // used for future extended attributes check

        return APFSInodeRecord(inodeId:   inodeId,
                               size:      fileSize,
                               modTime:   modTimeNs,
                               isDir:     isDir,
                               blockAddr: 0)
    }

    private static func parseDirEntry(data: Data,
                                      kStart: Int, kLen: Int,
                                      vStart: Int, vLen: Int,
                                      parentId: UInt64) -> APFSDirEntry? {
        // dir_rec key: j_key(8) + name_len_and_hash(4) + name(variable, null-terminated UTF-8)
        guard kLen > APFS.jKeySize + 4, vLen >= 8 else { return nil }

        let nameStart = kStart + APFS.jKeySize + 4
        let maxNameEnd = kStart + kLen
        guard nameStart < maxNameEnd, maxNameEnd <= data.count else { return nil }

        // Find null terminator
        var nameEnd = nameStart
        while nameEnd < maxNameEnd && data[nameEnd] != 0 { nameEnd += 1 }
        let nameBytes = data[nameStart..<nameEnd]
        let name = String(bytes: nameBytes, encoding: .utf8) ?? ""

        // dir_rec val: file_id(8) + date_added(8)
        let fileId = data.readLE64(at: vStart)

        return APFSDirEntry(parentId: parentId, inodeId: fileId, name: name)
    }

    // MARK: - Build candidates

    private static func buildCandidates(inodes: [UInt64: APFSInodeRecord],
                                        dirEntries: [APFSDirEntry],
                                        blockSize: UInt32,
                                        sectorSize: UInt32,
                                        sectorMap: SectorMap,
                                        onPath: ((String) -> Void)? = nil) -> [FileCandidate] {
        // Build name map: inodeId → filename from dir entries
        var nameMap: [UInt64: String] = [:]
        for entry in dirEntries {
            if !entry.name.isEmpty {
                nameMap[entry.inodeId] = entry.name
            }
        }

        var candidates: [FileCandidate] = []
        let sectorsPerBlock = UInt64(blockSize / sectorSize)

        for (_, inode) in inodes {
            guard !inode.isDir, inode.size > 0 else { continue }

            let name    = nameMap[inode.inodeId] ?? "recovered_\(inode.inodeId).bin"
            let ext     = (name as NSString).pathExtension.lowercased()
            let type    = RecoveredFileType.from(extension: ext)

            // Only set sector location when we actually know the physical block address.
            // blockAddr==0 means the parser couldn't determine the location (APFS extent
            // trees are not yet walked). Using startSector=0/sectorCount=0 means extents=[]
            // so the extractor will not attempt to read garbage from the start of the disk.
            let knownLocation = inode.blockAddr > 0
            let startSector = knownLocation ? inode.blockAddr * sectorsPerBlock : 0
            let sectorCount = knownLocation ?
                UInt64((inode.size + UInt64(blockSize) - 1) / UInt64(blockSize)) * sectorsPerBlock : 0

            // Convert nanoseconds to Date
            let modDate: Date? = inode.modTime > 0 ?
                Date(timeIntervalSince1970: TimeInterval(inode.modTime) / 1_000_000_000) : nil

            let candidate = FileCandidate.fromInode(
                fileType:         type,
                startSector:      startSector,
                sectorCount:      sectorCount,
                estimatedSize:    inode.size,
                originalName:     name,
                originalPath:     "/\(name)",
                modificationDate: modDate
            )
            onPath?("/\(name)")
            candidates.append(candidate)

            if startSector > 0 && sectorCount > 0 {
                sectorMap.mark(sector: startSector, as: .candidate)
            }
        }

        return candidates
    }

    // MARK: - Physical block I/O

    static func readPhysicalBlock(device: DiskDevice,
                                  block: UInt64,
                                  blockSize: UInt32) throws -> Data {
        let sectorsPerBlock = UInt32(blockSize / device.sectorSize)
        let startSector     = block * UInt64(sectorsPerBlock)
        guard let data = device.readSectors(startingSector: startSector,
                                            count: sectorsPerBlock,
                                            into: nil) else {
            throw APFSError.cannotReadBlock(block: block)
        }
        return data
    }
}

// MARK: - Data LE extensions

extension Data {
    func readLE16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func readLE32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset])           |
               UInt32(self[offset + 1]) << 8  |
               UInt32(self[offset + 2]) << 16 |
               UInt32(self[offset + 3]) << 24
    }

    func readLE64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return UInt64(readLE32(at: offset)) |
               UInt64(readLE32(at: offset + 4)) << 32
    }
}

// MARK: - Errors

public enum APFSError: Error, LocalizedError {
    case cannotReadSuperblock
    case notAPFS(magic: UInt32)
    case invalidBlockSize(UInt32)
    case cannotReadBlock(block: UInt64)
    case omapNotFound(oid: UInt64)
    case volumeNotFound(oid: UInt64)

    public var errorDescription: String? {
        switch self {
        case .cannotReadSuperblock:
            return "Cannot read APFS container superblock"
        case .notAPFS(let m):
            return "Not an APFS container (magic: 0x\(String(m, radix: 16)))"
        case .invalidBlockSize(let s):
            return "Invalid APFS block size: \(s)"
        case .cannotReadBlock(let b):
            return "Cannot read APFS block \(b)"
        case .omapNotFound(let o):
            return "Object map OID \(o) not found"
        case .volumeNotFound(let o):
            return "Volume OID \(o) not found"
        }
    }
}
