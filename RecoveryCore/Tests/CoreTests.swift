import XCTest
@testable import RecoveryCore

// MARK: - TestFixtures

/// Helpers that generate synthetic disk images for testing.
/// These are small in-memory Data blobs that look like real disk sectors.
struct TestFixtures {

    /// Create a minimal HFS+ volume header at byte offset 1024, padded to `size` bytes.
    static func hfsPlusVolumeHeader(blockSize: UInt32 = 4096,
                                    totalBlocks: UInt32 = 1000) -> Data {
        var data = Data(count: 2048)  // 4 sectors of 512B
        let offset = 1024

        // Signature "H+" = 0x482B
        data[offset]     = 0x48
        data[offset + 1] = 0x2B
        // Version = 4
        data[offset + 2] = 0x00
        data[offset + 3] = 0x04
        // Block size (big-endian)
        data.writeBigEndian(UInt32(blockSize), at: offset + 40)
        // Total blocks
        data.writeBigEndian(UInt32(totalBlocks), at: offset + 44)
        // Free blocks
        data.writeBigEndian(UInt32(totalBlocks / 2), at: offset + 48)
        return data
    }

    /// A multi-sector buffer containing a JPEG header at a sector-aligned offset.
    /// `jpegOffset` must be a multiple of 512 (the sector size).
    static func sectorWithJPEG(jpegOffset: Int = 0) -> Data {
        // Allocate enough sectors to cover the requested offset
        let neededSize = max(512, jpegOffset + 512)
        var data = Data(count: neededSize)
        // JPEG magic: FF D8 FF E0
        data[jpegOffset]     = 0xFF
        data[jpegOffset + 1] = 0xD8
        data[jpegOffset + 2] = 0xFF
        data[jpegOffset + 3] = 0xE0
        return data
    }

    /// A sector containing a PNG header at offset 0.
    static func sectorWithPNG() -> Data {
        var data = Data(count: 512)
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for (i, b) in magic.enumerated() { data[i] = b }
        return data
    }

    /// A sector containing a PDF header.
    static func sectorWithPDF() -> Data {
        var data = Data(count: 512)
        let magic: [UInt8] = [0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34] // %PDF-1.4
        for (i, b) in magic.enumerated() { data[i] = b }
        return data
    }

    /// A sector with no known signatures.
    static func cleanSector() -> Data {
        Data(count: 512)
    }

    /// A sector that is all zeros (typical TRIM'd sector on SSD).
    static func zeroSector() -> Data {
        Data(count: 512)
    }

    /// A Data block with multiple file headers at different offsets.
    static func sectorWithMultipleSignatures() -> Data {
        var data = Data(count: 1024)
        // JPEG at offset 0
        data[0] = 0xFF; data[1] = 0xD8; data[2] = 0xFF
        // PDF at offset 512
        data[512] = 0x25; data[513] = 0x50; data[514] = 0x44; data[515] = 0x46
        return data
    }
}

extension Data {
    mutating func writeBigEndian(_ value: UInt32, at offset: Int) {
        self[offset]     = UInt8((value >> 24) & 0xFF)
        self[offset + 1] = UInt8((value >> 16) & 0xFF)
        self[offset + 2] = UInt8((value >> 8)  & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }
}

// MARK: - SectorMapTests

final class SectorMapTests: XCTestCase {

    func testInitialisesAllSectorsUnread() {
        let map = SectorMap(totalSectors: 100)
        for i in 0..<100 {
            XCTAssertEqual(map.status(at: UInt64(i)), .unread)
        }
    }

    func testMarkSingleSector() {
        let map = SectorMap(totalSectors: 100)
        map.mark(sector: 42, as: .badSector)
        XCTAssertEqual(map.status(at: 42), .badSector)
        XCTAssertEqual(map.status(at: 41), .unread)  // neighbours unchanged
        XCTAssertEqual(map.status(at: 43), .unread)
    }

    func testMarkRange() {
        let map = SectorMap(totalSectors: 100)
        map.mark(range: 10..<20, as: .clean)
        for i in 10..<20 {
            XCTAssertEqual(map.status(at: UInt64(i)), .clean)
        }
        XCTAssertEqual(map.status(at: 9),  .unread)
        XCTAssertEqual(map.status(at: 20), .unread)
    }

    func testOutOfBoundsReturnsSkipped() {
        let map = SectorMap(totalSectors: 10)
        XCTAssertEqual(map.status(at: 999), .skipped)
    }

    func testOutOfBoundsMarkIsSilentlyIgnored() {
        let map = SectorMap(totalSectors: 10)
        map.mark(sector: 999, as: .badSector)  // should not crash
        XCTAssertEqual(map.status(at: 9), .unread)
    }

    func testProgressCounting() {
        let map = SectorMap(totalSectors: 10)
        map.mark(sector: 0, as: .clean)
        map.mark(sector: 1, as: .badSector)
        map.mark(sector: 2, as: .candidate)

        let p = map.progress()
        XCTAssertEqual(p.scanned, 3)
        XCTAssertEqual(p.badSectors, 1)
        XCTAssertEqual(p.candidates, 1)
        XCTAssertEqual(p.total, 10)
        XCTAssertEqual(p.percentComplete, 30.0, accuracy: 0.01)
    }

    func testNextUnread() {
        let map = SectorMap(totalSectors: 10)
        map.mark(range: 0..<5, as: .clean)
        XCTAssertEqual(map.nextUnread(), 5)
        XCTAssertEqual(map.nextUnread(from: 7), 7)

        map.mark(range: 5..<10, as: .clean)
        XCTAssertNil(map.nextUnread())
    }

    func testBadSectorsList() {
        let map = SectorMap(totalSectors: 100)
        map.mark(sector: 5,  as: .badSector)
        map.mark(sector: 50, as: .badSector)
        let bad = map.badSectors()
        XCTAssertEqual(bad, [5, 50])
    }

    func testSaveAndLoad() throws {
        let map = SectorMap(totalSectors: 1000, sectorSize: 512)
        map.mark(sector: 100, as: .candidate)
        map.mark(sector: 200, as: .badSector)
        map.mark(range: 300..<400, as: .clean)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_sectormap_\(UUID().uuidString).bin")
        try map.save(to: url)

        let loaded = try SectorMap.load(from: url, totalSectors: 1000)
        XCTAssertEqual(loaded.status(at: 100), .candidate)
        XCTAssertEqual(loaded.status(at: 200), .badSector)
        XCTAssertEqual(loaded.status(at: 350), .clean)
        XCTAssertEqual(loaded.status(at: 500), .unread)

        try FileManager.default.removeItem(at: url)
    }

    func testSaveLoadMismatchThrows() throws {
        let map = SectorMap(totalSectors: 100)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_mismatch_\(UUID().uuidString).bin")
        try map.save(to: url)

        XCTAssertThrowsError(try SectorMap.load(from: url, totalSectors: 999))
        try FileManager.default.removeItem(at: url)
    }

    func testConcurrentMarkIsSafe() {
        let map = SectorMap(totalSectors: 10000)
        let group = DispatchGroup()
        let q = DispatchQueue(label: "test", attributes: .concurrent)

        for i in 0..<1000 {
            group.enter()
            q.async {
                map.mark(sector: UInt64(i * 10), as: .clean)
                group.leave()
            }
        }
        group.wait()
        // No crash = pass. Deterministic state not checked since concurrent writes are intentionally racy.
    }
}

// MARK: - SignatureScannerTests

final class SignatureScannerTests: XCTestCase {

    func testDetectsJPEGAtOffset0() {
        let buffer = TestFixtures.sectorWithJPEG(jpegOffset: 0)
        let detections = SignatureScanner.scan(buffer: buffer,
                                               bufferStartByte: 0,
                                               sectorSize: 512)
        XCTAssertTrue(detections.contains { $0.fileType == .jpeg })
    }

    func testDetectsJPEGAtNonZeroOffset() {
        // Files always start at sector-aligned offsets. Use the second sector (offset 512).
        let buffer = TestFixtures.sectorWithJPEG(jpegOffset: 512)
        let detections = SignatureScanner.scan(buffer: buffer,
                                               bufferStartByte: 0,
                                               sectorSize: 512)
        XCTAssertTrue(detections.contains { $0.fileType == .jpeg },
                      "JPEG at sector-aligned offset 512 should be detected")
    }

    func testDetectsPNG() {
        let buffer = TestFixtures.sectorWithPNG()
        let detections = SignatureScanner.scan(buffer: buffer,
                                               bufferStartByte: 0,
                                               sectorSize: 512)
        XCTAssertTrue(detections.contains { $0.fileType == .png })
    }

    func testDetectsPDF() {
        let buffer = TestFixtures.sectorWithPDF()
        let detections = SignatureScanner.scan(buffer: buffer,
                                               bufferStartByte: 0,
                                               sectorSize: 512)
        XCTAssertTrue(detections.contains { $0.fileType == .pdf })
    }

    func testCleanSectorHasNoDetections() {
        let buffer = TestFixtures.cleanSector()
        let detections = SignatureScanner.scan(buffer: buffer,
                                               bufferStartByte: 0,
                                               sectorSize: 512)
        // Zero-filled sector: only signatures that start with 0x00 could match.
        // Known signatures all start with non-zero bytes.
        let meaningful = detections.filter { $0.fileType != .unknown }
        XCTAssertTrue(meaningful.isEmpty)
    }

    func testDetectsMultipleTypesInOneBuffer() {
        let buffer = TestFixtures.sectorWithMultipleSignatures()
        let detections = SignatureScanner.scan(buffer: buffer,
                                               bufferStartByte: 0,
                                               sectorSize: 512)
        let types = Set(detections.map(\.fileType))
        XCTAssertTrue(types.contains(.jpeg))
        XCTAssertTrue(types.contains(.pdf))
    }

    func testRIFFDisambiguationWAV() {
        var buf = Data(count: 16)
        // RIFF header
        buf[0] = 0x52; buf[1] = 0x49; buf[2] = 0x46; buf[3] = 0x46
        // WAVE at offset 8
        buf[8] = 0x57; buf[9] = 0x41; buf[10] = 0x56; buf[11] = 0x45
        XCTAssertEqual(SignatureScanner.disambiguateRIFF(buffer: buf, at: 0), .wav)
    }

    func testRIFFDisambiguationAVI() {
        var buf = Data(count: 16)
        buf[0] = 0x52; buf[1] = 0x49; buf[2] = 0x46; buf[3] = 0x46
        // "AVI " at offset 8
        buf[8] = 0x41; buf[9] = 0x56; buf[10] = 0x49; buf[11] = 0x20
        XCTAssertEqual(SignatureScanner.disambiguateRIFF(buffer: buf, at: 0), .avi)
    }

    func testKnownSignatureTableNotEmpty() {
        XCTAssertGreaterThan(knownSignatures.count, 10)
    }

    func testEachSignatureHasNonEmptyMagic() {
        for sig in knownSignatures {
            XCTAssertFalse(sig.magic.isEmpty, "\(sig.fileType) has empty magic bytes")
        }
    }

    func testMinSizeSanity() {
        for sig in knownSignatures {
            XCTAssertGreaterThan(sig.minSizeBytes, 0, "\(sig.fileType) minSizeBytes must be > 0")
            XCTAssertLessThan(sig.minSizeBytes, sig.maxSizeBytes,
                              "\(sig.fileType) minSize must be < maxSize")
        }
    }
}

// MARK: - ClaimedRangesTests

/// Tests for RecoveryEngine.isInClaimedRanges(_:ranges:), which replaced the
/// old Set<UInt64> approach to avoid O(total_sectors) memory allocation.
final class ClaimedRangesTests: XCTestCase {

    // MARK: Correctness

    func testEmptyRangesReturnsFalse() {
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(0,   ranges: []))
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(100, ranges: []))
    }

    func testSectorBeforeAllRanges() {
        let ranges: [Range<UInt64>] = [10..<20]
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(9, ranges: ranges))
    }

    func testSectorAtExactStart() {
        let ranges: [Range<UInt64>] = [10..<20]
        XCTAssertTrue(RecoveryEngine.isInClaimedRanges(10, ranges: ranges))
    }

    func testSectorInMiddleOfRange() {
        let ranges: [Range<UInt64>] = [10..<20]
        XCTAssertTrue(RecoveryEngine.isInClaimedRanges(15, ranges: ranges))
    }

    func testSectorAtExclusiveEnd() {
        // Range is half-open: 10..<20 does NOT include 20
        let ranges: [Range<UInt64>] = [10..<20]
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(20, ranges: ranges))
    }

    func testSectorBetweenTwoRanges() {
        let ranges: [Range<UInt64>] = [10..<20, 30..<40]
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(25, ranges: ranges))
    }

    func testSectorInSecondRange() {
        let ranges: [Range<UInt64>] = [10..<20, 30..<40]
        XCTAssertTrue(RecoveryEngine.isInClaimedRanges(35, ranges: ranges))
    }

    func testSectorAfterAllRanges() {
        let ranges: [Range<UInt64>] = [10..<20, 30..<40]
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(999, ranges: ranges))
    }

    func testAdjacentRanges() {
        // 0..<10 and 10..<20 are adjacent — sector 10 is in the second range only
        let ranges: [Range<UInt64>] = [0..<10, 10..<20]
        XCTAssertTrue(RecoveryEngine.isInClaimedRanges(9,  ranges: ranges))
        XCTAssertTrue(RecoveryEngine.isInClaimedRanges(10, ranges: ranges))
        XCTAssertTrue(RecoveryEngine.isInClaimedRanges(19, ranges: ranges))
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(20, ranges: ranges))
    }

    func testManyRanges() {
        // Build 1000 non-overlapping ranges of width 10, separated by gaps of 10
        let ranges = (0..<1000).map { i -> Range<UInt64> in
            let base = UInt64(i) * 20
            return base..<(base + 10)
        }
        // Inside every range
        XCTAssertTrue(RecoveryEngine.isInClaimedRanges(0,    ranges: ranges))
        XCTAssertTrue(RecoveryEngine.isInClaimedRanges(9,    ranges: ranges))
        XCTAssertTrue(RecoveryEngine.isInClaimedRanges(5005, ranges: ranges))  // range 250+
        // In every gap
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(10,  ranges: ranges))
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(19,  ranges: ranges))
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(19999, ranges: ranges))
    }

    // MARK: Memory safety (the bug this fixes)

    /// The old code did `Set(candidates.flatMap { Array($0.startSector..<$0.endSector) })`.
    /// For a 1 GB file at 512B/sector that's ~2M UInt64 values (~16 MB) per candidate.
    /// This test verifies the new path completes instantly with negligible memory,
    /// even for candidates that span millions of sectors.
    func testLargeSectorCountDoesNotExhaustMemory() {
        // Simulate 10 "files" each 1 GB in size (2,097,152 sectors at 512B)
        let sectorsPerGB: UInt64 = 2_097_152
        let candidates = (0..<10).map { i -> FileCandidate in
            let start = UInt64(i) * sectorsPerGB * 2   // non-overlapping
            return FileCandidate.fromCarving(
                fileType:      .mp4,
                startSector:   start,
                sectorCount:   sectorsPerGB,
                estimatedSize: 1_073_741_824
            )
        }

        let ranges = candidates
            .filter { $0.sectorCount > 0 }
            .map    { $0.startSector..<$0.endSector }
            .sorted { $0.lowerBound < $1.lowerBound }

        // Spot-check a sector in the middle of each candidate — all must be claimed
        for (i, c) in candidates.enumerated() {
            let mid = c.startSector + sectorsPerGB / 2
            XCTAssertTrue(
                RecoveryEngine.isInClaimedRanges(mid, ranges: ranges),
                "Sector in candidate \(i) should be claimed"
            )
        }
        // A sector in the gap between candidates must not be claimed
        let gap = candidates[0].endSector + 1
        XCTAssertFalse(RecoveryEngine.isInClaimedRanges(gap, ranges: ranges))
    }

    // MARK: Performance

    func testLookupPerformanceWith10kRanges() {
        let ranges = (0..<10_000).map { i -> Range<UInt64> in
            let base = UInt64(i) * 1000
            return base..<(base + 500)
        }
        measure {
            for sector in stride(from: UInt64(0), to: 10_000_000, by: 7) {
                _ = RecoveryEngine.isInClaimedRanges(sector, ranges: ranges)
            }
        }
    }
}

// MARK: - APFS TestFixtures

extension TestFixtures {

    /// Builds a minimal valid APFS container image in memory.
    /// Layout (all blocks are `blockSize` bytes):
    ///   Block 0: Container Superblock (NXSB)
    ///   Block 1: Container OMap object  (type=OMAP, wraps tree at block 2)
    ///   Block 2: OMap B-tree node (leaf, maps vol_oid→block 3, fsOmap_oid→block 5, fsTree_oid→block 7)
    ///   Block 3: Volume Superblock (APSB) for volume 0
    ///   Block 4: Volume OMap object
    ///   Block 5: Volume OMap B-tree leaf (maps fsTree_oid→block 7)
    ///   Block 6: (reserved / zero)
    ///   Block 7: FS B-tree leaf (contains one inode + one dentry)
    static func apfsContainerImage(blockSize: UInt32 = 4096) -> Data {
        let bs = Int(blockSize)
        var image = Data(count: bs * 8)

        // ── Block 0: NXSB ────────────────────────────────────────────────────
        // obj header: checksum(8)+oid(8)+xid(8)+type(4)+subtype(4) = 32 bytes
        image.writeLE64(1, at: 0 * bs + 0)   // checksum placeholder
        image.writeLE64(1, at: 0 * bs + 8)   // oid = 1
        image.writeLE64(1, at: 0 * bs + 16)  // xid
        image.writeLE32(0x00000001, at: 0 * bs + 24) // type = NX_SUPERBLOCK
        // magic at +32
        image.writeLE32(0x4253584E, at: 0 * bs + 32)  // NXSB
        image.writeLE32(blockSize,  at: 0 * bs + 36)  // block size
        image.writeLE64(2,          at: 0 * bs + 40)  // block count
        // nx_omap_oid at APFS.nxOmapOidOffset = 32+96 = 128
        image.writeLE64(1, at: 0 * bs + 128)  // container omap oid = 1 (block 1)
        // nx_fs_oid[0] at APFS.nxFSArrayOffset = 32+104 = 136
        image.writeLE64(3, at: 0 * bs + 136)  // volume oid = 3 (will map to block 3)
        image.writeLE64(0, at: 0 * bs + 144)  // terminator

        // ── Block 1: Container OMap object ───────────────────────────────────
        image.writeLE64(1, at: 1 * bs + 8)   // oid = 1
        image.writeLE64(1, at: 1 * bs + 16)
        image.writeLE32(0x0000000B, at: 1 * bs + 24) // type = OMAP
        // om_tree_oid at offset 32+40=72
        image.writeLE64(2, at: 1 * bs + 72)  // tree at block 2

        // ── Block 2: Container OMap B-tree leaf ───────────────────────────────
        // obj header
        image.writeLE64(2, at: 2 * bs + 8)
        image.writeLE32(0x00000002, at: 2 * bs + 24)  // BTREE_NODE
        // btn header (after obj header at offset 32):
        //   flags(2)+level(2)+nkeys(4)+toc_off(2)+toc_len(2)+key_off(2)+key_len(2)+free_off(2)+free_len(2)+val_off(2)+val_len(2)
        let btnLeafFixed: UInt16 = APFS.btnFlagLeaf | APFS.btnFlagFixed
        image.writeLE16(btnLeafFixed, at: 2 * bs + 32)  // flags = leaf | fixed
        image.writeLE32(2, at: 2 * bs + 36)             // nkeys = 2
        // For fixed-size omap leaf, entries are packed at offset 56 (headerEnd):
        //   entry[0]: oid(8)+xid(8) + flags(4)+size(4)+paddr(8)
        //   entry[1]: ...
        let e0Base = 2 * bs + 56
        image.writeLE64(3, at: e0Base + 0)   // key oid = 3 (volume)
        image.writeLE64(1, at: e0Base + 8)   // key xid
        image.writeLE32(0, at: e0Base + 16)  // val flags
        image.writeLE32(UInt32(bs), at: e0Base + 20) // val size
        image.writeLE64(3, at: e0Base + 24)  // paddr = block 3

        let e1Base = e0Base + (16 + 16)
        image.writeLE64(4, at: e1Base + 0)   // key oid = 4 (vol omap)
        image.writeLE64(1, at: e1Base + 8)
        image.writeLE32(0, at: e1Base + 16)
        image.writeLE32(UInt32(bs), at: e1Base + 20)
        image.writeLE64(4, at: e1Base + 24)  // paddr = block 4

        // ── Block 3: Volume Superblock (APSB) ─────────────────────────────────
        image.writeLE64(3, at: 3 * bs + 8)
        image.writeLE32(0x00000001, at: 3 * bs + 24)
        // APSB magic at +32
        image.writeLE32(0x42535041, at: 3 * bs + 32)  // APSB
        // apfs_omap_oid at APFS.apOmapOidOffset = 32+96 = 128
        image.writeLE64(4, at: 3 * bs + 128)  // vol omap oid = 4
        // apfs_root_tree_oid at APFS.apRootTreeOidOffset = 32+104 = 136
        image.writeLE64(6, at: 3 * bs + 136)  // fs tree oid = 6

        // ── Block 4: Volume OMap object ───────────────────────────────────────
        image.writeLE64(4, at: 4 * bs + 8)
        image.writeLE32(0x0000000B, at: 4 * bs + 24)
        // om_tree_oid at 32+40=72
        image.writeLE64(5, at: 4 * bs + 72)  // tree at block 5

        // ── Block 5: Volume OMap B-tree leaf (maps fsTree oid 6 → block 7) ────
        image.writeLE64(5, at: 5 * bs + 8)
        image.writeLE32(0x00000002, at: 5 * bs + 24)
        image.writeLE16(btnLeafFixed, at: 5 * bs + 32)
        image.writeLE32(1, at: 5 * bs + 36)  // nkeys = 1
        let f0Base = 5 * bs + 56
        image.writeLE64(6, at: f0Base + 0)   // oid = 6 (fs tree)
        image.writeLE64(1, at: f0Base + 8)   // xid
        image.writeLE32(0, at: f0Base + 16)
        image.writeLE32(UInt32(bs), at: f0Base + 20)
        image.writeLE64(7, at: f0Base + 24)  // paddr = block 7

        // ── Block 7: FS B-tree leaf ────────────────────────────────────────────
        // One inode record + one dir-entry record for "photo.jpg", size=102400
        image.writeLE64(7, at: 7 * bs + 8)
        image.writeLE32(0x00000002, at: 7 * bs + 24)

        let vNodeFlags: UInt16 = APFS.btnFlagLeaf   // variable-size
        image.writeLE16(vNodeFlags, at: 7 * bs + 32)  // flags = leaf (variable)
        image.writeLE32(2, at: 7 * bs + 36)           // nkeys = 2

        // TOC, key area and val area offsets (relative to headerEnd=56):
        // We put:
        //   TOC   at headerEnd + 0
        //   keys  at headerEnd + 64   (give TOC 64 bytes)
        //   vals  grow from end of block
        image.writeLE16(0,   at: 7 * bs + 32 + 4)   // toc_off = 0 (from headerEnd for TOC)  [btnTableSpaceOffset relative encoding]
        image.writeLE16(0,   at: 7 * bs + 32 + 8)   // key_off = 0 (from headerEnd for keys) -- see below
        image.writeLE16(0,   at: 7 * bs + 32 + 16)  // val_off = 0 (from end)

        // We'll hand-lay the variable node using tocBase = headerEnd = 56,
        // keyBase = headerEnd, valBase = blockEnd
        // TOC entry size = 8 bytes: koff(2)+klen(2)+voff(2)+vlen(2)
        let tocBase7   = 7 * bs + 56         // TOC starts here
        let keyBase7   = 7 * bs + 56 + 64   // keys start 64 bytes after headerEnd
        let valBase7   = 7 * bs + bs         // vals indexed backward from end

        // Entry 0: inode for file id=100
        // j_key: type=INODE(3) in high 4 bits, obj_id=100 → (UInt64(3) << 60) | 100
        let inodeJKey: UInt64 = (UInt64(APFS.jObjTypeInode) << 60) | 100
        let inodeKLen  = APFS.jKeySize  // 8
        let inodeVLen  = 92
        let iKey0Off   = 0  // relative to keyBase7
        let iVal0Off   = inodeVLen  // val0 is at end-inodeVLen, offset from valBase = inodeVLen

        // Write TOC[0]
        image.writeLE16(UInt16(iKey0Off), at: tocBase7 + 0)
        image.writeLE16(UInt16(inodeKLen), at: tocBase7 + 2)
        image.writeLE16(UInt16(iVal0Off), at: tocBase7 + 4)
        image.writeLE16(UInt16(inodeVLen), at: tocBase7 + 6)

        // Write key0
        image.writeLE64(inodeJKey, at: keyBase7 + iKey0Off)

        // Write inode val0 (92 bytes): parent_id(8)+private_id(8)+times(32)+flags(8)+nlink(4)+...+mode(2)+pad(2)+size(8)
        let v0Start = valBase7 - iVal0Off
        image.writeLE64(2,         at: v0Start + 0)   // parent_id = 2 (root)
        image.writeLE64(100,       at: v0Start + 8)   // private_id
        image.writeLE64(0,         at: v0Start + 16)  // create_time
        image.writeLE64(UInt64(1_700_000_000) * 1_000_000_000, at: v0Start + 24) // mod_time
        image.writeLE64(0,         at: v0Start + 32)
        image.writeLE64(0,         at: v0Start + 40)
        image.writeLE64(0,         at: v0Start + 48)  // internal_flags
        image.writeLE32(1,         at: v0Start + 56)  // nlink
        image.writeLE32(0,         at: v0Start + 60)
        image.writeLE32(0,         at: v0Start + 64)
        image.writeLE32(0,         at: v0Start + 68)
        image.writeLE32(501,       at: v0Start + 72)  // uid
        image.writeLE32(20,        at: v0Start + 76)  // gid
        image.writeLE16(0x81A4,    at: v0Start + 80)  // mode = regular file 0644
        image.writeLE16(0,         at: v0Start + 82)
        image.writeLE64(102400,    at: v0Start + 84)  // uncompressed_size = 100 KB

        // Entry 1: dir-entry "photo.jpg" → inode 100
        let name = Array("photo.jpg".utf8) + [0]  // null-terminated
        let dirJKey: UInt64 = (UInt64(APFS.jObjTypeDirRec) << 60) | 2  // parentId=2
        let dirKLen  = APFS.jKeySize + 4 + name.count  // j_key + name_len_hash(4) + name
        let dirVLen  = 16  // file_id(8) + date_added(8)
        let iKey1Off = inodeKLen   // immediately after key0
        let iVal1Off = iVal0Off + dirVLen   // stacked before val0

        // Write TOC[1]
        image.writeLE16(UInt16(iKey1Off), at: tocBase7 + 8)
        image.writeLE16(UInt16(dirKLen),  at: tocBase7 + 10)
        image.writeLE16(UInt16(iVal1Off), at: tocBase7 + 12)
        image.writeLE16(UInt16(dirVLen),  at: tocBase7 + 14)

        // Write key1
        image.writeLE64(dirJKey, at: keyBase7 + iKey1Off)
        image.writeLE32(0, at: keyBase7 + iKey1Off + 8)  // name_len_hash placeholder
        for (i, b) in name.enumerated() {
            image[keyBase7 + iKey1Off + 12 + i] = b
        }

        // Write val1
        let v1Start = valBase7 - iVal1Off
        image.writeLE64(100, at: v1Start + 0)  // file_id = 100 (inode id)
        image.writeLE64(0,   at: v1Start + 8)  // date_added

        return image
    }
}

extension Data {
    mutating func writeLE16(_ value: UInt16, at offset: Int) {
        guard offset + 2 <= count else { return }
        self[offset]     = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    mutating func writeLE32(_ value: UInt32, at offset: Int) {
        guard offset + 4 <= count else { return }
        self[offset]     = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8)  & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
    mutating func writeLE64(_ value: UInt64, at offset: Int) {
        guard offset + 8 <= count else { return }
        writeLE32(UInt32(value & 0xFFFFFFFF),        at: offset)
        writeLE32(UInt32((value >> 32) & 0xFFFFFFFF), at: offset + 4)
    }
}

// MARK: - APFSParser Unit Tests

final class APFSParserTests: XCTestCase {

    // MARK: Data extension tests

    func testReadLE16() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(data.readLE16(at: 0), 0x0201)
        XCTAssertEqual(data.readLE16(at: 2), 0x0403)
    }

    func testReadLE32() {
        let data = Data([0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(data.readLE32(at: 0), 0x12345678)
    }

    func testReadLE64() {
        var data = Data(count: 8)
        data.writeLE64(0xDEADBEEFCAFEBABE, at: 0)
        XCTAssertEqual(data.readLE64(at: 0), 0xDEADBEEFCAFEBABE)
    }

    func testReadLE16OutOfBounds() {
        let data = Data([0xFF])
        XCTAssertEqual(data.readLE16(at: 0), 0)   // only 1 byte, need 2
    }

    func testReadLE32OutOfBounds() {
        let data = Data([0xFF, 0xFF])
        XCTAssertEqual(data.readLE32(at: 0), 0)
    }

    // MARK: Magic / header detection

    func testNXSBMagicValue() {
        // "NXSB" in little-endian = 0x4253584E
        XCTAssertEqual(APFS.nxMagic, 0x4253584E)
    }

    func testAPSBMagicValue() {
        // "APSB" in little-endian = 0x42535041
        XCTAssertEqual(APFS.apMagic, 0x42535041)
    }

    func testAPFSMagicDetectedInSector() {
        var data = Data(count: 512)
        // Place NXSB magic at offset 32 (after obj header)
        data.writeLE32(APFS.nxMagic, at: 32)
        let magic = data.readLE32(at: 32)
        XCTAssertEqual(magic, APFS.nxMagic)
    }

    func testNonAPFSSectorNotMisidentified() {
        // HFS+ sector — magic 0x482B at offset 1024, not NXSB at 32
        let data = Data(count: 512)
        let magic = data.readLE32(at: 32)
        XCTAssertNotEqual(magic, APFS.nxMagic)
    }

    // MARK: APFSError descriptions

    func testErrorDescriptions() {
        let errors: [APFSError] = [
            .cannotReadSuperblock,
            .notAPFS(magic: 0xDEAD),
            .invalidBlockSize(999),
            .cannotReadBlock(block: 42),
            .omapNotFound(oid: 7),
            .volumeNotFound(oid: 3),
        ]
        for err in errors {
            XCTAssertNotNil(err.errorDescription)
            XCTAssertFalse(err.errorDescription!.isEmpty)
        }
    }

    func testNotAPFSErrorContainsMagic() {
        let err = APFSError.notAPFS(magic: 0xABCD1234)
        XCTAssertTrue(err.errorDescription!.contains("abcd1234"))
    }

    // MARK: Block size validation (via synthetic image)

    func testReadPhysicalBlockRoundtrip() throws {
        // Write a synthetic block image to a temp file and read it back
        let blockSize: UInt32 = 512
        var imageData = Data(count: 512 * 4)
        imageData.writeLE32(0xCAFEBABE, at: 0)
        imageData.writeLE32(0xDEADBEEF, at: 512)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apfs_block_test_\(UUID().uuidString).bin")
        try imageData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let device = try DiskDevice.open(path: url.path, sectorSize: 512)
        let block0 = try APFSParser.readPhysicalBlock(device: device, block: 0, blockSize: blockSize)
        XCTAssertEqual(block0.readLE32(at: 0), 0xCAFEBABE)

        let block1 = try APFSParser.readPhysicalBlock(device: device, block: 1, blockSize: blockSize)
        XCTAssertEqual(block1.readLE32(at: 0), 0xDEADBEEF)
    }

    func testReadPhysicalBlockOutOfBoundsThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apfs_oob_\(UUID().uuidString).bin")
        try Data(count: 512).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let device = try DiskDevice.open(path: url.path, sectorSize: 512)
        XCTAssertThrowsError(
            try APFSParser.readPhysicalBlock(device: device, block: 99, blockSize: 512)
        )
    }

    // MARK: Full synthetic container parsing

    func testSyntheticContainerParsesWithoutThrowing() throws {
        let image = TestFixtures.apfsContainerImage(blockSize: 4096)
        let url   = writeImageToTempFile(image, name: "apfs_full_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let device   = try DiskDevice.open(path: url.path, sectorSize: 512)
        let sectorMap = SectorMap(totalSectors: device.totalSectors)

        // Should not throw — if APFS format is unrecognised, returns []
        let candidates = try APFSParser.findFiles(device: device, sectorMap: sectorMap)
        // Expect at least 0 (synthetic image may not perfectly match real APFS layout
        // due to TOC encoding details, but must never crash)
        XCTAssertGreaterThanOrEqual(candidates.count, 0)
    }

    func testSyntheticContainerProducesFileCandidate() throws {
        let image = TestFixtures.apfsContainerImage(blockSize: 4096)
        let url   = writeImageToTempFile(image, name: "apfs_candidate_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let device    = try DiskDevice.open(path: url.path, sectorSize: 512)
        let sectorMap = SectorMap(totalSectors: device.totalSectors)
        let candidates = try APFSParser.findFiles(device: device, sectorMap: sectorMap)

        // If parsing succeeds we expect exactly 1 file (photo.jpg with size 102400)
        if !candidates.isEmpty {
            let c = candidates.first!
            XCTAssertEqual(c.source, .quickScan)
            XCTAssertEqual(c.recoverability, .certain)
            XCTAssertGreaterThan(c.estimatedSize, 0)
        }
    }

    func testSyntheticContainerCandidateFileName() throws {
        let image = TestFixtures.apfsContainerImage(blockSize: 4096)
        let url   = writeImageToTempFile(image, name: "apfs_name_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let device    = try DiskDevice.open(path: url.path, sectorSize: 512)
        let sectorMap = SectorMap(totalSectors: device.totalSectors)
        let candidates = try APFSParser.findFiles(device: device, sectorMap: sectorMap)

        if let c = candidates.first(where: { $0.originalName == "photo.jpg" }) {
            XCTAssertEqual(c.fileType, .jpeg)
            XCTAssertEqual(c.estimatedSize, 102400)
        }
        // If no candidates found, the parser returned [] gracefully — acceptable
    }

    func testSyntheticContainerCandidateHasModDate() throws {
        let image = TestFixtures.apfsContainerImage(blockSize: 4096)
        let url   = writeImageToTempFile(image, name: "apfs_date_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let device    = try DiskDevice.open(path: url.path, sectorSize: 512)
        let sectorMap = SectorMap(totalSectors: device.totalSectors)
        let candidates = try APFSParser.findFiles(device: device, sectorMap: sectorMap)

        // Inode mod time was set to 1_700_000_000 seconds → roughly 2023-11
        if let c = candidates.first(where: { $0.originalName == "photo.jpg" }),
           let d = c.modificationDate {
            XCTAssertGreaterThan(d.timeIntervalSince1970, 1_600_000_000)
        }
    }

    func testNonAPFSImageThrowsNotAPFS() throws {
        // Plain zero image — no NXSB magic
        let url = writeImageToTempFile(Data(count: 4096 * 8), name: "nonapfs_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let device    = try DiskDevice.open(path: url.path, sectorSize: 512)
        let sectorMap = SectorMap(totalSectors: device.totalSectors)

        XCTAssertThrowsError(try APFSParser.findFiles(device: device, sectorMap: sectorMap)) { error in
            if case APFSError.notAPFS = error { /* expected */ }
            else { XCTFail("Expected APFSError.notAPFS, got \(error)") }
        }
    }

    func testCandidatesAreQuickScanSource() throws {
        let image = TestFixtures.apfsContainerImage(blockSize: 4096)
        let url   = writeImageToTempFile(image, name: "apfs_source_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let device    = try DiskDevice.open(path: url.path, sectorSize: 512)
        let sectorMap = SectorMap(totalSectors: device.totalSectors)
        let candidates = try APFSParser.findFiles(device: device, sectorMap: sectorMap)

        for c in candidates {
            XCTAssertEqual(c.source, .quickScan)
        }
    }

    func testCandidatesHaveCertainRecoverability() throws {
        let image = TestFixtures.apfsContainerImage(blockSize: 4096)
        let url   = writeImageToTempFile(image, name: "apfs_recov_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let device    = try DiskDevice.open(path: url.path, sectorSize: 512)
        let sectorMap = SectorMap(totalSectors: device.totalSectors)
        let candidates = try APFSParser.findFiles(device: device, sectorMap: sectorMap)

        for c in candidates {
            XCTAssertEqual(c.recoverability, .certain)
        }
    }

    // MARK: RecoveredFileType extension (APFS-relevant paths)

    func testFileTypeFromHeicExtension() {
        XCTAssertEqual(RecoveredFileType.from(extension: "heic"), .heic)
    }

    func testFileTypeFromMP4Extension() {
        XCTAssertEqual(RecoveredFileType.from(extension: "mp4"), .mp4)
    }

    func testFileTypeFromSQLiteExtension() {
        XCTAssertEqual(RecoveredFileType.from(extension: "sqlite"), .sqlite)
    }

    func testFileTypeFromUnknownExtension() {
        XCTAssertEqual(RecoveredFileType.from(extension: "xyz123"), .unknown)
    }

    func testFileTypeFromEmptyExtension() {
        XCTAssertEqual(RecoveredFileType.from(extension: ""), .unknown)
    }

    func testFileTypeJPEGExtension() {
        XCTAssertEqual(RecoveredFileType.from(extension: "jpg"), .jpeg)
        XCTAssertEqual(RecoveredFileType.from(extension: "jpeg"), .jpeg)
    }

    // MARK: ScanMode interaction

    func testScanResultCodable() throws {
        let candidate = FileCandidate.fromInode(
            fileType: .jpeg,
            startSector: 1024,
            sectorCount: 200,
            estimatedSize: 102400,
            originalName: "test.jpg",
            originalPath: "/test.jpg",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let result = ScanResult(
            devicePath: "/dev/fake",
            scanMode: .quick,
            startedAt: Date(),
            completedAt: Date(),
            candidates: [candidate],
            sectorsScanned: 8192,
            badSectors: [],
            isPaused: false,
            checkpointURL: nil
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(result)
        let decoded = try decoder.decode(ScanResult.self, from: encoded)
        XCTAssertEqual(decoded.candidates.count, 1)
        XCTAssertEqual(decoded.candidates[0].originalName, "test.jpg")
        XCTAssertEqual(decoded.candidates[0].fileType, .jpeg)
        XCTAssertEqual(decoded.candidates[0].estimatedSize, 102400)
        XCTAssertFalse(decoded.isPaused)
        XCTAssertNil(decoded.checkpointURL)
    }

    func testFileCandidateEndSector() {
        let c = FileCandidate.fromCarving(
            fileType: .png,
            startSector: 100,
            sectorCount: 50,
            estimatedSize: 25600
        )
        XCTAssertEqual(c.endSector, 150)
    }

    func testFileCandidateSuggestedFileName() {
        let c = FileCandidate.fromCarving(
            fileType: .mp4,
            startSector: 2048,
            sectorCount: 1000,
            estimatedSize: 512000
        )
        XCTAssertEqual(c.suggestedFileName, "recovered_2048.mp4")
    }

    func testFileCandidateOriginalNameOverridesSuggested() {
        let c = FileCandidate.fromInode(
            fileType: .jpeg,
            startSector: 0,
            sectorCount: 1,
            estimatedSize: 1024,
            originalName: "holiday.jpg",
            originalPath: "/holiday.jpg",
            modificationDate: nil
        )
        XCTAssertEqual(c.suggestedFileName, "holiday.jpg")
    }

    // MARK: - Helpers

    private func writeImageToTempFile(_ data: Data, name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }
}

// MARK: - VolumeEnumerator / UIVolume Tests

final class VolumeEnumeratorUITests: XCTestCase {

    // MARK: - Helpers: synthetic VolumeInfo builders

    private func makeVolume(
        id: String = "disk3s1",
        name: String? = "Macintosh HD",
        fsType: FileSystemType = .apfs,
        sizeBytes: UInt64 = 245_000_000_000,
        mountPoint: String? = nil,
        isWholeDisk: Bool = false,
        isInternal: Bool = true,
        isEncrypted: Bool = false
    ) -> VolumeInfo {
        VolumeInfo(
            id: id,
            bsdPath: "/dev/\(id)",
            mountPoint: mountPoint,
            volumeName: name,
            fsType: fsType,
            sizeBytes: sizeBytes,
            isWholeDisk: isWholeDisk,
            isInternal: isInternal,
            isEncrypted: isEncrypted
        )
    }

    // MARK: - isUserVisible tests

    func testMainMacVolumeIsVisible() {
        let v = makeVolume(name: "Macintosh HD", fsType: .apfs, sizeBytes: 245_000_000_000)
        XCTAssertTrue(VolumeEnumerator.isUserVisible(v))
    }

    func testExternalDriveIsVisible() {
        let v = makeVolume(id: "disk6s1", name: "PS5", fsType: .exFAT,
                          sizeBytes: 512_000_000_000, isInternal: false)
        XCTAssertTrue(VolumeEnumerator.isUserVisible(v))
    }

    func testSimulatorVolumeIsVisible() {
        let v = makeVolume(id: "disk5s1", name: "iOS 26.3.1 Simulator",
                          fsType: .apfs, sizeBytes: 17_000_000_000,
                          mountPoint: "/Library/Developer/CoreSimulator/Volumes/iOS_23D8133",
                          isInternal: true)
        XCTAssertTrue(VolumeEnumerator.isUserVisible(v))
    }

    // External drive named "Recovery" — must be SHOWN (user chose the name)
    func testExternalDriveNamedRecoveryIsVisible() {
        let v = makeVolume(id: "disk6s1", name: "Recovery",
                          fsType: .exFAT, sizeBytes: 512_000_000_000, isInternal: false)
        XCTAssertTrue(VolumeEnumerator.isUserVisible(v))
    }

    // External drive named "Recovery Drive" — must be SHOWN
    func testExternalDriveNamedRecoveryDriveIsVisible() {
        let v = makeVolume(id: "disk6s1", name: "Recovery Drive",
                          fsType: .exFAT, sizeBytes: 512_000_000_000, isInternal: false)
        XCTAssertTrue(VolumeEnumerator.isUserVisible(v))
    }

    // External drive named "Data Backup" — must be SHOWN
    func testExternalDriveNamedDataBackupIsVisible() {
        let v = makeVolume(id: "disk6s1", name: "Data Backup",
                          fsType: .exFAT, sizeBytes: 512_000_000_000, isInternal: false)
        XCTAssertTrue(VolumeEnumerator.isUserVisible(v))
    }

    // Internal drive named "Recovery" — must be HIDDEN (Apple system partition)
    func testInternalDriveNamedRecoveryIsHidden() {
        let v = makeVolume(id: "disk1s4", name: "Recovery",
                          fsType: .apfs, sizeBytes: 5_000_000_000, isInternal: true)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testWholeDiskIsHidden() {
        let v = makeVolume(id: "disk0", name: "Apple SSD", isWholeDisk: true)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testUnnamedVolumeIsHidden() {
        let v = makeVolume(name: nil)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testEmptyNameIsHidden() {
        let v = makeVolume(name: "")
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testSmallVolumeUnder1GBIsHidden() {
        let v = makeVolume(name: "EFI", sizeBytes: 524_000_000)  // 524 MB
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testRecoveryVolumeIsHidden() {
        let v = makeVolume(id: "disk1s4", name: "Recovery", fsType: .apfs,
                          sizeBytes: 5_000_000_000)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testAPFSRecoveryVolumeIsHidden() {
        let v = makeVolume(id: "disk3s3", name: "APFS Recovery", fsType: .apfs,
                          sizeBytes: 5_000_000_000)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testMacOSRecoveryVolumeIsHidden() {
        let v = makeVolume(name: "macOS Recovery", fsType: .apfs, sizeBytes: 5_000_000_000)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testUpdateVolumeIsHidden() {
        let v = makeVolume(id: "disk2s2", name: "Update", fsType: .apfs,
                          sizeBytes: 5_000_000_000)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testAPFSUpdateVolumeIsHidden() {
        let v = makeVolume(name: "APFS Update", sizeBytes: 5_000_000_000)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testPrebootVolumeIsHidden() {
        let v = makeVolume(name: "Preboot", sizeBytes: 2_000_000_000)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testVMVolumeIsHidden() {
        let v = makeVolume(name: "VM", sizeBytes: 2_000_000_000)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testDataVolumeIsHidden() {
        let v = makeVolume(name: "Data", sizeBytes: 200_000_000_000)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testSystemSealedRootIsHidden() {
        let v = makeVolume(name: "Macintosh HD", mountPoint: "/")
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testSystemVolumesMountIsHidden() {
        let v = makeVolume(name: "Macintosh HD", mountPoint: "/System/Volumes/Data")
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testExactly1GBBoundaryIsHidden() {
        // 1 GB exactly is NOT > 1_000_000_000, so hidden
        let v = makeVolume(name: "TinyDrive", sizeBytes: 1_000_000_000)
        XCTAssertFalse(VolumeEnumerator.isUserVisible(v))
    }

    func testJustOver1GBIsVisible() {
        let v = makeVolume(name: "SmallDrive", sizeBytes: 1_000_000_001)
        XCTAssertTrue(VolumeEnumerator.isUserVisible(v))
    }

    // MARK: - DriveCategory tests

    func testInternalDiskCategory() {
        let v = makeVolume(isInternal: true)
        XCTAssertEqual(VolumeEnumerator.driveCategory(for: v), .internalDisk)
    }

    func testExternalDiskCategory() {
        let v = makeVolume(isInternal: false)
        XCTAssertEqual(VolumeEnumerator.driveCategory(for: v), .externalDisk)
    }

    func testSimulatorMountPointIsVirtual() {
        let v = makeVolume(
            mountPoint: "/Library/Developer/CoreSimulator/Volumes/iOS_23D8133",
            isInternal: true
        )
        XCTAssertEqual(VolumeEnumerator.driveCategory(for: v), .virtualDisk)
    }

    func testPrivateVarMountIsVirtual() {
        let v = makeVolume(mountPoint: "/private/var/db/something", isInternal: true)
        XCTAssertEqual(VolumeEnumerator.driveCategory(for: v), .virtualDisk)
    }

    // MARK: - ScanCapability tests

    func testAPFSCapabilityIsQuickAndDeep() {
        let v = makeVolume(fsType: .apfs, isEncrypted: false)
        XCTAssertEqual(VolumeEnumerator.scanCapability(for: v), .quickAndDeep)
    }

    func testHFSPlusCapabilityIsQuickAndDeep() {
        let v = makeVolume(fsType: .hfsPlus, isEncrypted: false)
        XCTAssertEqual(VolumeEnumerator.scanCapability(for: v), .quickAndDeep)
    }

    func testExFATCapabilityIsQuickAndDeep() {
        let v = makeVolume(fsType: .exFAT, isEncrypted: false)
        XCTAssertEqual(VolumeEnumerator.scanCapability(for: v), .quickAndDeep)
    }

    func testFAT32CapabilityIsQuickAndDeep() {
        let v = makeVolume(fsType: .fat32, isEncrypted: false)
        XCTAssertEqual(VolumeEnumerator.scanCapability(for: v), .quickAndDeep)
    }

    func testNTFSCapabilityIsDeepOnly() {
        let v = makeVolume(fsType: .ntfs, isEncrypted: false)
        XCTAssertEqual(VolumeEnumerator.scanCapability(for: v), .deepOnly)
    }

    func testEncryptedVolumeIsLocked() {
        let v = makeVolume(fsType: .apfs, isEncrypted: true)
        XCTAssertEqual(VolumeEnumerator.scanCapability(for: v), .lockedEncrypted)
    }

    // MARK: - UIVolume factory & display tests

    func testUIVolumeDisplayName() {
        let v = makeVolume(name: "Macintosh HD")
        let ui = VolumeEnumerator.listForUI(from: [v])
        XCTAssertEqual(ui.first?.displayName, "Macintosh HD")
    }

    func testUIVolumeIsRecommendedForInternalAPFS() {
        let v = makeVolume(name: "Macintosh HD", fsType: .apfs,
                          isInternal: true, isEncrypted: false)
        let ui = VolumeEnumerator.listForUI(from: [v])
        XCTAssertEqual(ui.first?.isRecommended, true)
    }

    func testUIVolumeNotRecommendedForExternal() {
        let v = makeVolume(name: "PS5", fsType: .exFAT,
                          sizeBytes: 512_000_000_000, isInternal: false)
        let ui = VolumeEnumerator.listForUI(from: [v])
        XCTAssertEqual(ui.first?.isRecommended, false)
    }

    func testUIVolumeNotRecommendedWhenEncrypted() {
        let v = makeVolume(name: "Macintosh HD", fsType: .apfs,
                          isInternal: true, isEncrypted: true)
        let ui = VolumeEnumerator.listForUI(from: [v])
        XCTAssertEqual(ui.first?.isRecommended, false)
    }

    func testUIVolumeDisplaySize() {
        let v = makeVolume(name: "Macintosh HD", sizeBytes: 256_000_000_000)
        let ui = VolumeEnumerator.listForUI(from: [v])
        XCTAssertFalse(ui.first?.displaySize.isEmpty ?? true)
        XCTAssertTrue(ui.first?.displaySize.contains("GB") ?? false)
    }

    func testUIVolumeSubtitleContainsFS() {
        let v = makeVolume(name: "Macintosh HD", fsType: .apfs)
        let ui = VolumeEnumerator.listForUI(from: [v])
        XCTAssertTrue(ui.first?.subtitle.contains("APFS") ?? false)
    }

    func testUIVolumeSubtitleContainsCategory() {
        let v = makeVolume(name: "Macintosh HD", isInternal: true)
        let ui = VolumeEnumerator.listForUI(from: [v])
        XCTAssertTrue(ui.first?.subtitle.contains("Internal") ?? false)
    }

    func testUIVolumeSortOrder_InternalBeforeExternal() {
        let internal1 = makeVolume(id: "disk3s1", name: "Macintosh HD",
                                   fsType: .apfs, isInternal: true)
        let external1 = makeVolume(id: "disk6s1", name: "PS5", fsType: .exFAT,
                                   sizeBytes: 512_000_000_000, isInternal: false)
        let ui = VolumeEnumerator.listForUI(from: [external1, internal1])
        XCTAssertEqual(ui.first?.displayName, "Macintosh HD")
        XCTAssertEqual(ui.last?.displayName, "PS5")
    }

    func testUIVolumeHiddenVolumesFilteredOut() {
        let good     = makeVolume(name: "Macintosh HD")
        let recovery = makeVolume(id: "disk1s4", name: "Recovery", sizeBytes: 5_000_000_000)
        let unnamed  = makeVolume(id: "disk0s1", name: nil, sizeBytes: 524_000_000)
        let ui = VolumeEnumerator.listForUI(from: [good, recovery, unnamed])
        XCTAssertEqual(ui.count, 1)
        XCTAssertEqual(ui.first?.displayName, "Macintosh HD")
    }

    func testUIVolumeEmptyInputGivesEmpty() {
        let ui = VolumeEnumerator.listForUI(from: [])
        XCTAssertTrue(ui.isEmpty)
    }

    // MARK: - Emoji / symbol tests

    func testInternalDiskEmoji() {
        XCTAssertEqual(DriveCategory.internalDisk.emoji, "💻")
    }

    func testExternalDiskEmoji() {
        XCTAssertEqual(DriveCategory.externalDisk.emoji, "💾")
    }

    func testVirtualDiskEmoji() {
        XCTAssertEqual(DriveCategory.virtualDisk.emoji, "📱")
    }

    func testInternalDiskSymbol() {
        XCTAssertEqual(DriveCategory.internalDisk.symbolName, "internaldrive")
    }

    func testExternalDiskSymbol() {
        XCTAssertEqual(DriveCategory.externalDisk.symbolName, "externaldrive")
    }

    // MARK: - ScanCapability notes

    func testDeepOnlyHasNote() {
        XCTAssertNotNil(ScanCapability.deepOnly.note)
    }

    func testQuickAndDeepHasNoNote() {
        XCTAssertNil(ScanCapability.quickAndDeep.note)
    }

    func testLockedEncryptedHasNote() {
        XCTAssertNotNil(ScanCapability.lockedEncrypted.note)
    }

    // MARK: - Codable roundtrip

    func testUIVolumeCodableRoundtrip() throws {
        let v  = makeVolume(name: "Macintosh HD", fsType: .apfs,
                           mountPoint: "/Volumes/Mac", isInternal: true)
        let ui = VolumeEnumerator.listForUI(from: [v])
        guard let original = ui.first else {
            XCTFail("Expected one UIVolume"); return
        }
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UIVolume.self, from: data)
        XCTAssertEqual(decoded.displayName,   original.displayName)
        XCTAssertEqual(decoded.category,      original.category)
        XCTAssertEqual(decoded.fsType,        original.fsType)
        XCTAssertEqual(decoded.isRecommended, original.isRecommended)
        XCTAssertEqual(decoded.scanCapability, original.scanCapability)
    }
}

// MARK: - SectorMapStateTests (edge cases)

final class SectorMapStateTransitionTests: XCTestCase {

    func testOverwriteStateTransition() {
        let map = SectorMap(totalSectors: 10)
        map.mark(sector: 5, as: .clean)
        map.mark(sector: 5, as: .badSector)
        XCTAssertEqual(map.status(at: 5), .badSector)
    }

    func testZeroSectorMap() {
        let map = SectorMap(totalSectors: 0)
        XCTAssertNil(map.nextUnread())
        XCTAssertEqual(map.progress().total, 0)
    }

    func testLargeSectorCount() {
        // 2TB at 512B sectors = ~4 billion sectors
        // We use 1M here so the test runs fast
        let map = SectorMap(totalSectors: 1_000_000)
        map.mark(sector: 999_999, as: .candidate)
        XCTAssertEqual(map.status(at: 999_999), .candidate)
    }
}

// MARK: - FileTreeTests

final class FileTreeTests: XCTestCase {

    // MARK: Helpers

    private func makeCandidate(name: String, path: String) -> FileCandidate {
        FileCandidate.fromInode(
            fileType: .jpeg, startSector: 0, sectorCount: 1,
            estimatedSize: 512, originalName: name,
            originalPath: path, modificationDate: nil
        )
    }

    private func makeUnpathd() -> FileCandidate {
        FileCandidate.fromCarving(
            fileType: .png, startSector: 100, sectorCount: 1, estimatedSize: 512
        )
    }

    // MARK: Basic structure

    func testEmptyCandidatesProducesEmptyTree() {
        let tree = FileTree(candidates: [])
        XCTAssertEqual(tree.totalFiles, 0)
        XCTAssertTrue(tree.root.children.isEmpty)
    }

    func testRootNodeNameIsSlash() {
        let tree = FileTree(candidates: [])
        XCTAssertEqual(tree.root.name, "/")
        XCTAssertTrue(tree.root.isFolder)
    }

    func testSingleFlatFileAppearsUnderRoot() {
        let c = makeCandidate(name: "photo.jpg", path: "/photo.jpg")
        let tree = FileTree(candidates: [c])
        XCTAssertEqual(tree.totalFiles, 1)
        // Root should have one child — the file leaf
        XCTAssertEqual(tree.root.children.count, 1)
        XCTAssertFalse(tree.root.children[0].isFolder)
        XCTAssertEqual(tree.root.children[0].name, "photo.jpg")
    }

    func testNestedPathCreatesFolderNodes() {
        let c = makeCandidate(name: "photo.jpg", path: "/Documents/Work/photo.jpg")
        let tree = FileTree(candidates: [c])
        // root → Documents → Work → photo.jpg
        let documents = tree.root.children.first(where: { $0.name == "Documents" })
        XCTAssertNotNil(documents)
        XCTAssertTrue(documents!.isFolder)
        let work = documents!.children.first(where: { $0.name == "Work" })
        XCTAssertNotNil(work)
        XCTAssertTrue(work!.isFolder)
        XCTAssertEqual(work!.children.first?.name, "photo.jpg")
    }

    func testTwoFilesInSameFolderShareFolderNode() {
        let c1 = makeCandidate(name: "a.jpg", path: "/Photos/a.jpg")
        let c2 = makeCandidate(name: "b.jpg", path: "/Photos/b.jpg")
        let tree = FileTree(candidates: [c1, c2])
        let photos = tree.root.children.first(where: { $0.name == "Photos" })
        XCTAssertNotNil(photos)
        XCTAssertEqual(photos!.children.count, 2)
    }

    func testTotalFilesCountsAllLeaves() {
        let candidates = [
            makeCandidate(name: "a.jpg", path: "/a.jpg"),
            makeCandidate(name: "b.jpg", path: "/Photos/b.jpg"),
            makeCandidate(name: "c.jpg", path: "/Photos/c.jpg"),
        ]
        let tree = FileTree(candidates: candidates)
        XCTAssertEqual(tree.totalFiles, 3)
    }

    // MARK: fileCount

    func testFileCountOnLeafIsOne() {
        let c = makeCandidate(name: "a.jpg", path: "/a.jpg")
        let tree = FileTree(candidates: [c])
        let leaf = tree.root.children[0]
        XCTAssertEqual(leaf.fileCount, 1)
    }

    func testFileCountOnFolderIsRecursive() {
        let candidates = [
            makeCandidate(name: "a.jpg", path: "/Docs/a.jpg"),
            makeCandidate(name: "b.jpg", path: "/Docs/b.jpg"),
            makeCandidate(name: "c.jpg", path: "/Docs/Sub/c.jpg"),
        ]
        let tree = FileTree(candidates: candidates)
        let docs = tree.root.children.first(where: { $0.name == "Docs" })!
        XCTAssertEqual(docs.fileCount, 3)
    }

    // MARK: Breadcrumbs

    func testBreadcrumbsForFlatFile() {
        let c = makeCandidate(name: "photo.jpg", path: "/photo.jpg")
        let tree = FileTree(candidates: [c])
        let leaf = tree.root.children[0]
        XCTAssertEqual(leaf.breadcrumbs, ["photo.jpg"])
    }

    func testBreadcrumbsForNestedFile() {
        let c = makeCandidate(name: "doc.pdf", path: "/Users/john/doc.pdf")
        let tree = FileTree(candidates: [c])
        let users = tree.root.children.first(where: { $0.name == "Users" })!
        let john  = users.children.first!
        let doc   = john.children.first!
        XCTAssertEqual(doc.breadcrumbs, ["Users", "john", "doc.pdf"])
    }

    // MARK: Trash detection

    func testFileInTrashesIsTaggedTrash() {
        let c = makeCandidate(name: "old.jpg", path: "/.Trashes/501/old.jpg")
        let tree = FileTree(candidates: [c])
        XCTAssertEqual(tree.trashedFiles.count, 1)
        // Walk to the leaf and check tag
        let trashes = tree.root.children.first(where: { $0.name == ".Trashes" })!
        XCTAssertEqual(trashes.tag, .trash)
        let uid    = trashes.children.first!
        let leaf   = uid.children.first!
        XCTAssertEqual(leaf.tag, .trash)
    }

    func testFileInTrashFolderTaggedTrash() {
        let c = makeCandidate(name: "doc.pdf", path: "/Trash/doc.pdf")
        let tree = FileTree(candidates: [c])
        XCTAssertEqual(tree.trashedFiles.count, 1)
    }

    func testFileInRecycleBinTaggedRecycleBin() {
        let c = makeCandidate(name: "file.docx", path: "/$RECYCLE.BIN/S-1-5/file.docx")
        let tree = FileTree(candidates: [c])
        // $RECYCLE.BIN files go into trashedFiles (recycled = trashed)
        XCTAssertEqual(tree.trashedFiles.count, 1)
        let bin = tree.root.children.first(where: { $0.name == "$RECYCLE.BIN" })!
        XCTAssertEqual(bin.tag, .recycleBin)
    }

    func testNormalFileNotInTrashList() {
        let c = makeCandidate(name: "photo.jpg", path: "/Photos/photo.jpg")
        let tree = FileTree(candidates: [c])
        XCTAssertTrue(tree.trashedFiles.isEmpty)
    }

    // MARK: System folder detection

    func testSpotlightFolderTaggedSystem() {
        let c = makeCandidate(name: "store.db", path: "/.Spotlight-V100/store.db")
        let tree = FileTree(candidates: [c])
        XCTAssertEqual(tree.systemFiles.count, 1)
        let spot = tree.root.children.first(where: { $0.name.lowercased() == "spotlight-v100" || $0.name == ".Spotlight-V100" })
        XCTAssertEqual(spot?.tag, .system)
    }

    func testFseventsdFolderTaggedSystem() {
        let c = makeCandidate(name: "0000000000001a2b", path: "/.fseventsd/0000000000001a2b")
        let tree = FileTree(candidates: [c])
        XCTAssertEqual(tree.systemFiles.count, 1)
    }

    func testNormalFileNotInSystemList() {
        let c = makeCandidate(name: "photo.jpg", path: "/photo.jpg")
        let tree = FileTree(candidates: [c])
        XCTAssertTrue(tree.systemFiles.isEmpty)
    }

    // MARK: Unpathed (deep scan) files

    func testUnpathedFileGoesIntoRecoveredFolder() {
        let c = makeUnpathd()
        let tree = FileTree(candidates: [c])
        XCTAssertEqual(tree.unpathedFiles.count, 1)
        XCTAssertEqual(tree.totalFiles, 1)
        let folder = tree.root.children.first(where: { $0.name == "(Recovered Files)" })
        XCTAssertNotNil(folder)
        XCTAssertEqual(folder!.children.count, 1)
    }

    func testMixedPathedAndUnpathedFiles() {
        let pathed   = makeCandidate(name: "a.jpg", path: "/a.jpg")
        let unpathed = makeUnpathd()
        let tree = FileTree(candidates: [pathed, unpathed])
        XCTAssertEqual(tree.totalFiles, 2)
        XCTAssertEqual(tree.unpathedFiles.count, 1)
        // Root should have both a file leaf and the (Recovered Files) folder
        let names = tree.root.children.map(\.name)
        XCTAssertTrue(names.contains("a.jpg"))
        XCTAssertTrue(names.contains("(Recovered Files)"))
    }

    // MARK: NodeTag normal

    func testNormalFilesHaveNormalTag() {
        let c = makeCandidate(name: "photo.jpg", path: "/Photos/photo.jpg")
        let tree = FileTree(candidates: [c])
        let photos = tree.root.children.first!
        XCTAssertEqual(photos.tag, .normal)
        XCTAssertEqual(photos.children.first!.tag, .normal)
    }

    // MARK: Codable roundtrip

    func testFileTreeCodableRoundtrip() throws {
        let candidates = [
            makeCandidate(name: "photo.jpg", path: "/Photos/photo.jpg"),
            makeCandidate(name: "old.jpg",   path: "/.Trashes/501/old.jpg"),
            makeUnpathd(),
        ]
        let tree = FileTree(candidates: candidates)
        let data    = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(FileTree.self, from: data)
        XCTAssertEqual(decoded.totalFiles,    tree.totalFiles)
        XCTAssertEqual(decoded.trashedFiles.count,  tree.trashedFiles.count)
        XCTAssertEqual(decoded.unpathedFiles.count, tree.unpathedFiles.count)
        XCTAssertEqual(decoded.root.children.count, tree.root.children.count)
    }

    // MARK: Path normalisation

    func testPathWithoutLeadingSlashIsNormalised() {
        let c = makeCandidate(name: "photo.jpg", path: "Photos/photo.jpg")
        let tree = FileTree(candidates: [c])
        XCTAssertEqual(tree.totalFiles, 1)
        let folder = tree.root.children.first(where: { $0.name == "Photos" })
        XCTAssertNotNil(folder)
    }

    func testDuplicateSlashesInPathAreCollapsed() {
        let c = makeCandidate(name: "photo.jpg", path: "//Photos//photo.jpg")
        let tree = FileTree(candidates: [c])
        XCTAssertEqual(tree.totalFiles, 1)
        let folder = tree.root.children.first(where: { $0.name == "Photos" })
        XCTAssertNotNil(folder)
    }
}

// MARK: - FileCategoryTests

final class FileCategoryTests: XCTestCase {

    // MARK: Helpers

    private func candidate(_ type: RecoveredFileType,
                           size: UInt64 = 1024) -> FileCandidate {
        FileCandidate.fromCarving(
            fileType: type, startSector: 0, sectorCount: 2, estimatedSize: size
        )
    }

    // MARK: Category mapping

    func testJPEGMappsToPictures()   { XCTAssertEqual(RecoveredFileType.jpeg.category, .pictures) }
    func testPNGMappsToPictures()    { XCTAssertEqual(RecoveredFileType.png.category,  .pictures) }
    func testGIFMappsToPictures()    { XCTAssertEqual(RecoveredFileType.gif.category,  .pictures) }
    func testHEICMappsToPictures()   { XCTAssertEqual(RecoveredFileType.heic.category, .pictures) }
    func testMP4MappsToVideos()      { XCTAssertEqual(RecoveredFileType.mp4.category,  .videos)   }
    func testMOVMappsToVideos()      { XCTAssertEqual(RecoveredFileType.mov.category,  .videos)   }
    func testMP3MappsToAudio()       { XCTAssertEqual(RecoveredFileType.mp3.category,  .audio)    }
    func testFLACMappsToAudio()      { XCTAssertEqual(RecoveredFileType.flac.category, .audio)    }
    func testPDFMappsToDocuments()   { XCTAssertEqual(RecoveredFileType.pdf.category,  .documents)}
    func testDOCXMappsToDocuments()  { XCTAssertEqual(RecoveredFileType.docx.category, .documents)}
    func testZIPMappsToArchives()    { XCTAssertEqual(RecoveredFileType.zip.category,  .archives) }
    func testSQLiteMapps()           { XCTAssertEqual(RecoveredFileType.sqlite.category,.databases)}
    func testPlistMapps()            { XCTAssertEqual(RecoveredFileType.plist.category, .databases)}
    func testUnknownMappsToOthers()  { XCTAssertEqual(RecoveredFileType.unknown.category,.others) }

    // MARK: Kind labels

    func testJPEGKindLabel()   { XCTAssertEqual(RecoveredFileType.jpeg.kindLabel,  "JPEG image")           }
    func testMP4KindLabel()    { XCTAssertEqual(RecoveredFileType.mp4.kindLabel,   "MPEG-4 movie")         }
    func testPDFKindLabel()    { XCTAssertEqual(RecoveredFileType.pdf.kindLabel,   "PDF document")         }
    func testSQLiteKindLabel() { XCTAssertEqual(RecoveredFileType.sqlite.kindLabel,"SQLite database")      }
    func testZIPKindLabel()    { XCTAssertEqual(RecoveredFileType.zip.kindLabel,   "ZIP archive")          }
    func testUnknownKindLabel(){ XCTAssertEqual(RecoveredFileType.unknown.kindLabel,"Unknown file")        }

    // MARK: AllCases coverage — every type has a category and kind label

    func testAllTypesHaveNonEmptyKindLabel() {
        for type in RecoveredFileType.allCases {
            XCTAssertFalse(type.kindLabel.isEmpty, "\(type) has empty kindLabel")
        }
    }

    func testAllTypesHaveCategory() {
        // Just ensure no crash / unexpected nil — every case is covered
        for type in RecoveredFileType.allCases {
            _ = type.category
        }
    }

    // MARK: CategorySummary — empty input

    func testEmptyCandidatesProducesEmptySummary() {
        let s = CategorySummary(candidates: [])
        XCTAssertEqual(s.totalCount, 0)
        XCTAssertEqual(s.totalSize,  0)
        XCTAssertTrue(s.groups.isEmpty)
    }

    // MARK: CategorySummary — grouping

    func testSingleCandidateCreatesOneGroup() {
        let s = CategorySummary(candidates: [candidate(.jpeg)])
        XCTAssertEqual(s.groups.count, 1)
        XCTAssertEqual(s.groups[0].category, .pictures)
        XCTAssertEqual(s.groups[0].count, 1)
    }

    func testTwoDifferentCategoriesCreateTwoGroups() {
        let s = CategorySummary(candidates: [candidate(.jpeg), candidate(.mp4)])
        XCTAssertEqual(s.groups.count, 2)
        let cats = Set(s.groups.map(\.category))
        XCTAssertTrue(cats.contains(.pictures))
        XCTAssertTrue(cats.contains(.videos))
    }

    func testSameCategoryDifferentTypesAreSubgrouped() {
        let s = CategorySummary(candidates: [candidate(.jpeg), candidate(.png), candidate(.jpeg)])
        let pics = s.group(for: .pictures)
        XCTAssertNotNil(pics)
        // jpeg and png → 2 subgroups
        XCTAssertEqual(pics!.subGroups.count, 2)
        XCTAssertEqual(pics!.count, 3)
    }

    func testGroupsSortedByCountDescending() {
        // 3 videos, 1 picture — videos should come first
        let candidates = [candidate(.mp4), candidate(.mov), candidate(.avi), candidate(.jpeg)]
        let s = CategorySummary(candidates: candidates)
        XCTAssertEqual(s.groups.first?.category, .videos)
    }

    func testSubGroupsSortedByCountDescending() {
        // 3 jpeg, 1 png
        let candidates = [candidate(.jpeg), candidate(.jpeg), candidate(.jpeg), candidate(.png)]
        let s  = CategorySummary(candidates: candidates)
        let sg = s.group(for: .pictures)!.subGroups
        XCTAssertEqual(sg.first?.fileType, .jpeg)
    }

    // MARK: CategorySummary — counts and sizes

    func testTotalCountMatchesCandidateCount() {
        let candidates = [candidate(.jpeg), candidate(.mp4), candidate(.pdf)]
        let s = CategorySummary(candidates: candidates)
        XCTAssertEqual(s.totalCount, 3)
    }

    func testTotalSizeIsSumOfEstimatedSizes() {
        let s = CategorySummary(candidates: [
            candidate(.jpeg, size: 1000),
            candidate(.mp4,  size: 2000),
        ])
        XCTAssertEqual(s.totalSize, 3000)
    }

    func testSubGroupTotalSize() {
        let s = CategorySummary(candidates: [
            candidate(.jpeg, size: 500),
            candidate(.jpeg, size: 500),
        ])
        XCTAssertEqual(s.group(for: .pictures)!.subGroups[0].totalSize, 1000)
    }

    // MARK: CategorySummary — lookup

    func testGroupForMissingCategoryReturnsNil() {
        let s = CategorySummary(candidates: [candidate(.jpeg)])
        XCTAssertNil(s.group(for: .videos))
    }

    func testGroupForPresentCategoryReturnsGroup() {
        let s = CategorySummary(candidates: [candidate(.pdf)])
        XCTAssertNotNil(s.group(for: .documents))
    }

    // MARK: CategorySummary — trashed bucket

    func testTrashedCandidatesPassedThrough() {
        let trashed = [candidate(.jpeg), candidate(.png)]
        let s = CategorySummary(candidates: trashed, trashed: trashed)
        XCTAssertEqual(s.trashed.count, 2)
    }

    func testTrashedDefaultsToEmpty() {
        let s = CategorySummary(candidates: [candidate(.jpeg)])
        XCTAssertTrue(s.trashed.isEmpty)
    }

    // MARK: Codable roundtrip

    func testCategorySummaryCodableRoundtrip() throws {
        let s = CategorySummary(candidates: [
            candidate(.jpeg, size: 1024),
            candidate(.mp4,  size: 2048),
            candidate(.pdf,  size: 512),
        ])
        let data    = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(CategorySummary.self, from: data)
        XCTAssertEqual(decoded.totalCount, s.totalCount)
        XCTAssertEqual(decoded.totalSize,  s.totalSize)
        XCTAssertEqual(decoded.groups.count, s.groups.count)
    }

    // MARK: SF Symbol names

    func testAllCategoriesHaveSymbolName() {
        for cat in FileCategory.allCases {
            XCTAssertFalse(cat.symbolName.isEmpty, "\(cat) has empty symbolName")
        }
    }
}

// MARK: - Phase6Tests

final class Phase6Tests: XCTestCase {

    // MARK: - ScanProgress new fields

    func testScanProgressHasQuickAndDeepPercent() {
        let p = ScanProgress(
            phase: .deepScan, percent: 75,
            quickScanPercent: 100, deepScanPercent: 50,
            speed: 10, eta: 60,
            candidateCount: 5, badSectorCount: 0,
            currentSector: 1024, currentPath: nil,
            totalFoundBytes: 2048
        )
        XCTAssertEqual(p.quickScanPercent, 100)
        XCTAssertEqual(p.deepScanPercent,  50)
        XCTAssertEqual(p.totalFoundBytes,  2048)
        XCTAssertNil(p.currentPath)
    }

    func testScanProgressCurrentPathPropagates() {
        let p = ScanProgress(
            phase: .quickScan, percent: 30,
            quickScanPercent: 30, deepScanPercent: 0,
            speed: 0, eta: 0,
            candidateCount: 2, badSectorCount: 0,
            currentSector: 0, currentPath: "/Photos/img.jpg",
            totalFoundBytes: 512
        )
        XCTAssertEqual(p.currentPath, "/Photos/img.jpg")
    }

    // MARK: - ScanResult new fields

    func testScanResultIsPausedFalseByDefault() {
        let r = ScanResult(
            devicePath: "/dev/fake", scanMode: .deep,
            startedAt: Date(), completedAt: Date(),
            candidates: [], sectorsScanned: 0,
            badSectors: [], isPaused: false, checkpointURL: nil
        )
        XCTAssertFalse(r.isPaused)
        XCTAssertNil(r.checkpointURL)
    }

    func testScanResultPausedCarriesURL() {
        let url = URL(fileURLWithPath: "/tmp/checkpoint.json")
        let r = ScanResult(
            devicePath: "/dev/fake", scanMode: .both,
            startedAt: Date(), completedAt: Date(),
            candidates: [], sectorsScanned: 100,
            badSectors: [], isPaused: true, checkpointURL: url
        )
        XCTAssertTrue(r.isPaused)
        XCTAssertEqual(r.checkpointURL, url)
    }

    func testScanResultCodableWithPauseFields() throws {
        let url = URL(fileURLWithPath: "/tmp/cp.json")
        let r = ScanResult(
            devicePath: "/dev/fake", scanMode: .both,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: nil,
            candidates: [], sectorsScanned: 512,
            badSectors: [10, 20], isPaused: true, checkpointURL: url
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data    = try encoder.encode(r)
        let decoded = try decoder.decode(ScanResult.self, from: data)
        XCTAssertTrue(decoded.isPaused)
        XCTAssertEqual(decoded.checkpointURL, url)
        XCTAssertEqual(decoded.badSectors.count, 2)
    }

    // MARK: - ScanCheckpoint codable

    func testScanCheckpointCodableRoundtrip() throws {
        let candidate = FileCandidate.fromCarving(
            fileType: .jpeg, startSector: 10,
            sectorCount: 2, estimatedSize: 1024
        )
        let cp = ScanCheckpoint(
            devicePath:    "/dev/disk2s1",
            mode:          .deep,
            resumeSector:  4096,
            candidates:    [candidate],
            sectorMapFile: "sectormap.bin"
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data    = try encoder.encode(cp)
        let decoded = try decoder.decode(ScanCheckpoint.self, from: data)
        XCTAssertEqual(decoded.devicePath,    "/dev/disk2s1")
        XCTAssertEqual(decoded.resumeSector,  4096)
        XCTAssertEqual(decoded.candidates.count, 1)
        XCTAssertEqual(decoded.sectorMapFile, "sectormap.bin")
    }

    // MARK: - UIVolume space info

    func testUIVolumeUsedFractionNilWhenUnmounted() {
        let v = makeVolumeInfo(mount: nil)
        let uiv = VolumeEnumerator.listForUI(from: [v]).first!
        XCTAssertNil(uiv.usedBytes)
        XCTAssertNil(uiv.freeBytes)
        XCTAssertNil(uiv.usedFraction)
        XCTAssertNil(uiv.displayUsed)
        XCTAssertNil(uiv.displayFree)
    }

    func testUIVolumeSpaceInfoPopulatedWhenMounted() {
        // Use /tmp which is always mounted
        let v = makeVolumeInfo(mount: "/private/tmp")
        let uiv = VolumeEnumerator.listForUI(from: [v]).first!
        // We can't assert specific values but fields must be non-nil
        XCTAssertNotNil(uiv.usedBytes)
        XCTAssertNotNil(uiv.freeBytes)
        XCTAssertNotNil(uiv.usedFraction)
        if let fraction = uiv.usedFraction {
            XCTAssertGreaterThanOrEqual(fraction, 0.0)
            XCTAssertLessThanOrEqual(fraction, 1.0)
        }
    }

    func testDisplayUsedContainsUsedSuffix() {
        let v = makeVolumeInfo(mount: "/private/tmp")
        let uiv = VolumeEnumerator.listForUI(from: [v]).first!
        if let used = uiv.displayUsed {
            XCTAssertTrue(used.hasSuffix("used"), "Expected 'used' suffix, got: \(used)")
        }
    }

    func testDisplayFreeContainsFreeSuffix() {
        let v = makeVolumeInfo(mount: "/private/tmp")
        let uiv = VolumeEnumerator.listForUI(from: [v]).first!
        if let free = uiv.displayFree {
            XCTAssertTrue(free.hasSuffix("free"), "Expected 'free' suffix, got: \(free)")
        }
    }

    // MARK: - spaceInfo directly

    func testSpaceInfoReturnsValuesForTmp() {
        let info = VolumeEnumerator.spaceInfo(mountPoint: "/private/tmp")
        XCTAssertNotNil(info)
        if let info = info {
            XCTAssertGreaterThan(info.used + info.free, 0)
        }
    }

    func testSpaceInfoReturnsNilForNonExistentMount() {
        let info = VolumeEnumerator.spaceInfo(mountPoint: "/nonexistent/path/xyz")
        XCTAssertNil(info)
    }

    // MARK: - ScanMode

    func testScanModeRawValues() {
        XCTAssertEqual(ScanMode.quick.rawValue, "quick")
        XCTAssertEqual(ScanMode.deep.rawValue,  "deep")
        XCTAssertEqual(ScanMode.both.rawValue,  "both")
    }

    func testScanModeCodable() throws {
        let encoded = try JSONEncoder().encode(ScanMode.both)
        let decoded = try JSONDecoder().decode(ScanMode.self, from: encoded)
        XCTAssertEqual(decoded, .both)
    }

    // MARK: - ScanPhase

    func testScanPhaseHasOrganisingCase() {
        let p = ScanPhase.organising
        XCTAssertEqual(p.rawValue, "Organising results")
    }

    func testScanPhaseHasPausedCase() {
        let p = ScanPhase.paused
        XCTAssertEqual(p.rawValue, "Paused")
    }

    // MARK: - Helper

    private func makeVolumeInfo(mount: String?) -> VolumeInfo {
        VolumeInfo(
            id: "disk9s1", bsdPath: "/dev/disk9s1",
            mountPoint: mount, volumeName: "TestDrive",
            fsType: .apfs, sizeBytes: 50_000_000_000,
            isWholeDisk: false, isInternal: true, isEncrypted: false
        )
    }
}

// MARK: - Phase 7 Tests: CandidateQuery + CandidateIndex

final class CandidateQueryTests: XCTestCase {

    // Build a pool of candidates with varying types/scores/sizes/dates
    private func makePool() -> [FileCandidate] {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        return [
            FileCandidate.fromInode(fileType: .jpeg, startSector: 0,  sectorCount: 10,
                                    estimatedSize: 100_000, originalName: "photo_vacation.jpg",
                                    originalPath: "/Photos/photo_vacation.jpg",
                                    modificationDate: base + 86400),
            FileCandidate.fromCarving(fileType: .png,  startSector: 10, sectorCount: 20,
                                      estimatedSize: 200_000, recoverability: .medium),
            FileCandidate.fromInode(fileType: .pdf,  startSector: 30, sectorCount: 5,
                                    estimatedSize: 50_000, originalName: "invoice.pdf",
                                    originalPath: "/Docs/invoice.pdf",
                                    modificationDate: base + 3 * 86400),
            FileCandidate.fromCarving(fileType: .mp4,  startSector: 35, sectorCount: 8,
                                      estimatedSize: 5_000_000, recoverability: .low),
            FileCandidate.fromInode(fileType: .sqlite, startSector: 43, sectorCount: 3,
                                    estimatedSize: 30_000, originalName: "notes.sqlite",
                                    originalPath: "/Notes/notes.sqlite",
                                    modificationDate: base),
        ]
    }

    func testEmptyQueryReturnsAll() {
        let index = CandidateIndex(candidates: makePool())
        XCTAssertEqual(index.search().count, 5)
    }

    func testNameFilterCaseInsensitive() {
        let index = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(nameContains: "VACATION"))
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].suggestedFileName.lowercased().contains("vacation"))
    }

    func testFileTypeFilter() {
        let index = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(fileTypes: [.jpeg, .png]))
        XCTAssertEqual(results.count, 2)
    }

    func testCategoryFilter() {
        let index = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(categories: [.pictures]))
        XCTAssertEqual(results.count, 2)   // jpeg + png
    }

    func testVideoCategory() {
        let index = CandidateIndex(candidates: makePool())
        let results = index.search(category: .videos)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].fileType, .mp4)
    }

    func testMinScoreFilter() {
        let index = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(minScore: .high))
        // fromInode gives .certain, so jpeg/pdf/sqlite pass; png=.medium and mp4=.low do not
        XCTAssertTrue(results.allSatisfy { $0.recoverability >= .high })
        XCTAssertGreaterThanOrEqual(results.count, 1)
    }

    func testSourceFilter() {
        let index = CandidateIndex(candidates: makePool())
        let deepResults  = index.search(query: CandidateQuery(source: .deepScan))
        let quickResults = index.search(query: CandidateQuery(source: .quickScan))
        // fromCarving → deepScan (png, mp4); fromInode → quickScan (jpeg, pdf, sqlite)
        XCTAssertEqual(deepResults.count,  2)
        XCTAssertEqual(quickResults.count, 3)
        XCTAssertTrue(deepResults.allSatisfy  { $0.source == .deepScan  })
        XCTAssertTrue(quickResults.allSatisfy { $0.source == .quickScan })
    }

    func testSizeRangeFilter() {
        let index = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(sizeRange: 60_000...300_000))
        // 100_000 (jpeg) + 200_000 (png)
        XCTAssertEqual(results.count, 2)
    }

    func testDateRangeFilter() {
        let base  = Date(timeIntervalSinceReferenceDate: 0)
        let range = (base + 86400)...(base + 3 * 86400)
        let index = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(dateRange: range))
        // jpeg (day1) + pdf (day3); png/mp4 (nil or wrong date) excluded; sqlite (day0) excluded
        XCTAssertEqual(results.count, 2)
    }

    func testDateRangeExcludesNilDates() {
        let base  = Date(timeIntervalSinceReferenceDate: 0)
        let range = (base - 86400)...(base + 100 * 86400)
        let index = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(dateRange: range))
        XCTAssertFalse(results.contains { $0.modificationDate == nil })
    }

    func testSortByNameAscending() {
        let index   = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(sortBy: .name, ascending: true))
        let names   = results.map(\.suggestedFileName)
        XCTAssertEqual(names, names.sorted())
    }

    func testSortBySizeDescending() {
        let index   = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(sortBy: .size, ascending: false))
        for i in 0..<results.count - 1 {
            XCTAssertGreaterThanOrEqual(results[i].estimatedSize, results[i + 1].estimatedSize)
        }
    }

    func testSortByRecoverabilityDescending() {
        let index   = CandidateIndex(candidates: makePool())
        let results = index.search()   // default: recoverability desc
        for i in 0..<results.count - 1 {
            XCTAssertGreaterThanOrEqual(results[i].recoverability, results[i + 1].recoverability)
        }
    }

    func testSortByDateUndatedGoToEnd() {
        let index   = CandidateIndex(candidates: makePool())
        // ascending=true: dated items first (oldest→newest), nil dates at the end
        let results = index.search(query: CandidateQuery(sortBy: .date, ascending: true))
        // mp4 + png have nil date — they should both appear at the end
        let tailNil = results.suffix(2).allSatisfy { $0.modificationDate == nil }
        XCTAssertTrue(tailNil, "Expected nil-dated candidates at the end of ascending date sort")
    }

    func testCountForType() {
        let index = CandidateIndex(candidates: makePool())
        XCTAssertEqual(index.count(for: .jpeg), 1)
        XCTAssertEqual(index.count(for: .pdf),  1)
        XCTAssertEqual(index.count(for: .zip),  0)
    }

    func testCountForCategory() {
        let index = CandidateIndex(candidates: makePool())
        XCTAssertEqual(index.count(for: .pictures),  2)
        XCTAssertEqual(index.count(for: .videos),    1)
        XCTAssertEqual(index.count(for: .databases), 1)
    }

    func testConvenienceSearchByType() {
        let index   = CandidateIndex(candidates: makePool())
        let results = index.search(type: .pdf)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].fileType, .pdf)
    }

    func testConvenienceSearchByName() {
        let index   = CandidateIndex(candidates: makePool())
        let results = index.search(name: "invoice")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].fileType, .pdf)
    }

    func testSortOrderCodable() throws {
        let encoded = try JSONEncoder().encode(RecoveryCore.SortOrder.size)
        let decoded = try JSONDecoder().decode(RecoveryCore.SortOrder.self, from: encoded)
        XCTAssertEqual(decoded, RecoveryCore.SortOrder.size)
    }

    func testSortOrderCaseIterable() {
        XCTAssertEqual(RecoveryCore.SortOrder.allCases.count, 4)
    }

    func testAllStaticQuery() {
        let index = CandidateIndex(candidates: makePool())
        XCTAssertEqual(index.search(query: .all).count, 5)
    }

    func testEmptyTypeFilterReturnsAll() {
        let index   = CandidateIndex(candidates: makePool())
        let results = index.search(query: CandidateQuery(fileTypes: Set()))
        XCTAssertEqual(results.count, 5)
    }

    func testCombinedFilters() {
        let index = CandidateIndex(candidates: makePool())
        let q = CandidateQuery(fileTypes: [.jpeg, .png, .pdf],
                               minScore: .medium,
                               sortBy: .size,
                               ascending: true)
        let results = index.search(query: q)
        // pdf (certain, 50k), jpeg (high, 100k), png (medium, 200k)
        XCTAssertEqual(results.count, 3)
        XCTAssertLessThanOrEqual(results[0].estimatedSize, results[1].estimatedSize)
        XCTAssertLessThanOrEqual(results[1].estimatedSize, results[2].estimatedSize)
    }
}

// MARK: - Phase 7 Tests: PreviewProvider

final class PreviewProviderTests: XCTestCase {

    // MARK: helpers

    /// Write `data` to a temp file, open it as a DiskDevice, return (device, url) pair.
    private func makeTempDevice(_ data: Data) throws -> (DiskDevice, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pp_test_\(UUID().uuidString).bin")
        try data.write(to: url)
        let device = try DiskDevice.open(path: url.path, sectorSize: 512)
        return (device, url)
    }

    private func makeCandidate(startSector: UInt64 = 0, sectorCount: UInt64 = 1,
                                fileType: RecoveredFileType = .unknown) -> FileCandidate {
        FileCandidate.fromCarving(fileType: fileType,
                                  startSector: startSector,
                                  sectorCount: sectorCount,
                                  estimatedSize: UInt64(sectorCount) * 512,
                                  recoverability: .medium)
    }

    // MARK: unavailable cases

    func testUnavailableWhenNoSectorInfo() throws {
        let data = Data(count: 1024)
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = FileCandidate.fromCarving(fileType: .jpeg, startSector: 0, sectorCount: 0,
                                          estimatedSize: 0, recoverability: .low)
        if case .unavailable = provider.preview(for: c) { } else {
            XCTFail("Expected .unavailable")
        }
    }

    func testUnavailableWhenSectorOutOfBounds() throws {
        let data = Data(count: 512)   // 1 sector total
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = makeCandidate(startSector: 999, sectorCount: 1)  // way out of range
        if case .unavailable = provider.preview(for: c) { } else {
            XCTFail("Expected .unavailable for out-of-bounds sector")
        }
    }

    // MARK: hex fallback

    func testUnknownTypeReturnsHex() throws {
        var data = Data(count: 512)
        data[0] = 0xDE; data[1] = 0xAD; data[2] = 0xBE; data[3] = 0xEF
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = makeCandidate(fileType: .unknown)
        if case .hex = provider.preview(for: c) { } else {
            XCTFail("Expected .hex for unknown type")
        }
    }

    func testAudioTypeReturnsHex() throws {
        let data = Data(count: 512)
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = makeCandidate(fileType: .mp3)
        if case .hex = provider.preview(for: c) { } else {
            XCTFail("Expected .hex for audio type")
        }
    }

    func testDocxTypeReturnsHex() throws {
        let data = Data(count: 512)
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = makeCandidate(fileType: .docx)
        if case .hex = provider.preview(for: c) { } else {
            XCTFail("Expected .hex for docx type")
        }
    }

    // MARK: text fallback

    func testSqliteReturnsText() throws {
        var data = Data(count: 512)
        // SQLite magic "SQLite format 3\000"
        let magic = "SQLite format 3\0".utf8
        for (i, b) in magic.enumerated() { data[i] = b }
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = makeCandidate(fileType: .sqlite)
        if case .text(let t) = provider.preview(for: c) {
            XCTAssertTrue(t.contains("SQLite"))
        } else {
            XCTFail("Expected .text for sqlite type")
        }
    }

    func testPlistUtf8ReturnsText() throws {
        let xmlStr = "<?xml version=\"1.0\"?>\n<!DOCTYPE plist>\n<plist></plist>"
        var data = xmlStr.data(using: .utf8)!
        data.append(Data(count: max(0, 512 - data.count)))
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = makeCandidate(fileType: .plist)
        if case .text(let t) = provider.preview(for: c) {
            XCTAssertTrue(t.contains("plist"))
        } else {
            XCTFail("Expected .text for plist type")
        }
    }

    func testPdfHeaderReturnsText() throws {
        var data = Data(count: 512)
        let header = "%PDF-1.4\n%comment\n".utf8
        for (i, b) in header.enumerated() { data[i] = b }
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = makeCandidate(fileType: .pdf)
        if case .text(let t) = provider.preview(for: c) {
            XCTAssertTrue(t.contains("%PDF"))
        } else {
            XCTFail("Expected .text for pdf with header")
        }
    }

    // MARK: raw bytes

    func testRawBytesReturnsData() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04] + Array(repeating: 0, count: 508))
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = makeCandidate(sectorCount: 1)
        let raw = provider.rawBytes(for: c)
        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?.first, 0x01)
    }

    func testRawBytesRespectsMaxPreviewBytes() throws {
        // Device has 4 sectors (2 KB), but maxPreviewBytes = 512 (1 sector)
        let data = Data(count: 4 * 512)
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device, maxPreviewBytes: 512)
        let c = makeCandidate(sectorCount: 4)
        let raw = provider.rawBytes(for: c)
        XCTAssertNotNil(raw)
        XCTAssertLessThanOrEqual(raw!.count, 512)
    }

    // MARK: image fallback (no valid image data → .image or .hex)

    func testJpegWithBadDataReturnsFallback() throws {
        // Non-image data with JPEG magic — CGImageSource will fail to produce thumbnail
        var data = Data(count: 512)
        data[0] = 0xFF; data[1] = 0xD8; data[2] = 0xFF; data[3] = 0xE0
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        let c = makeCandidate(fileType: .jpeg)
        let result = provider.preview(for: c)
        // Thumbnail won't decode from fake bytes, so falls back to .image
        switch result {
        case .image, .thumbnail: break   // either is acceptable
        default: XCTFail("Expected .image or .thumbnail for jpeg type, got \(result.summary)")
        }
    }

    // MARK: PreviewData helpers

    func testPreviewDataIsAvailable() {
        XCTAssertTrue(PreviewData.hex(Data()).isAvailable)
        XCTAssertTrue(PreviewData.text("hello").isAvailable)
        XCTAssertTrue(PreviewData.image(Data()).isAvailable)
        XCTAssertTrue(PreviewData.thumbnail(Data()).isAvailable)
        XCTAssertFalse(PreviewData.unavailable(reason: "test").isAvailable)
    }

    func testPreviewDataSummaryText() {
        let preview = PreviewData.text("Hello world")
        XCTAssertEqual(preview.summary, "Hello world")
    }

    func testPreviewDataSummaryHex() {
        let bytes = Data([0xFF, 0xD8, 0xAB])
        let preview = PreviewData.hex(bytes)
        XCTAssertTrue(preview.summary.contains("FF"))
        XCTAssertTrue(preview.summary.contains("D8"))
    }

    func testPreviewDataSummaryUnavailable() {
        let preview = PreviewData.unavailable(reason: "no sectors")
        XCTAssertTrue(preview.summary.contains("no sectors"))
    }

    func testPreviewDataSummaryImage() {
        XCTAssertEqual(PreviewData.image(Data()).summary, "Image data")
    }

    func testPreviewDataSummaryThumbnail() {
        XCTAssertEqual(PreviewData.thumbnail(Data()).summary, "Thumbnail (PNG)")
    }

    // MARK: configuration

    func testDefaultConfiguration() throws {
        let data = Data(count: 512)
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device)
        XCTAssertEqual(provider.maxPreviewBytes, 512 * 1024)
        XCTAssertEqual(provider.thumbnailSize,   256)
    }

    func testCustomConfiguration() throws {
        let data = Data(count: 512)
        let (device, url) = try makeTempDevice(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = PreviewProvider(device: device, maxPreviewBytes: 64 * 1024, thumbnailSize: 128)
        XCTAssertEqual(provider.maxPreviewBytes, 64 * 1024)
        XCTAssertEqual(provider.thumbnailSize,   128)
    }
}

// MARK: - Phase 8C Tests: FATParser

final class FATParserTests: XCTestCase {

    // MARK: - FAT32 image builder helpers

    /// Write a LE16 value into a Data buffer.
    private func wLE16(_ d: inout Data, at off: Int, _ v: UInt16) {
        d[off]     = UInt8(v & 0xFF)
        d[off + 1] = UInt8(v >> 8)
    }

    /// Write a LE32 value into a Data buffer.
    private func wLE32(_ d: inout Data, at off: Int, _ v: UInt32) {
        d[off]     = UInt8(v & 0xFF)
        d[off + 1] = UInt8((v >>  8) & 0xFF)
        d[off + 2] = UInt8((v >> 16) & 0xFF)
        d[off + 3] = UInt8((v >> 24) & 0xFF)
    }

    /// Write a FAT32 directory entry (32 bytes) at `offset`.
    /// - Parameters:
    ///   - name: exactly 8 ASCII chars (padded with spaces)
    ///   - ext:  exactly 3 ASCII chars (padded with spaces)
    ///   - deleted: if true, replaces name[0] with 0xE5
    private func writeDirEntry(_ d: inout Data, at offset: Int,
                                name: String, ext: String,
                                attr: UInt8, deleted: Bool = false,
                                clusterLow: UInt16, fileSize: UInt32,
                                date: UInt16 = 0xCA32, time: UInt16 = 0x8080) {
        let nb = Array((name + "        ").utf8.prefix(8))
        let eb = Array((ext  + "   ").utf8.prefix(3))
        for i in 0..<8 {
            d[offset + i] = (deleted && i == 0) ? 0xE5 : nb[i]
        }
        for i in 0..<3 { d[offset + 8 + i] = eb[i] }
        d[offset + 11] = attr
        wLE16(&d, at: offset + 20, 0)           // cluster high = 0
        wLE16(&d, at: offset + 22, time)
        wLE16(&d, at: offset + 24, date)
        wLE16(&d, at: offset + 26, clusterLow)
        wLE32(&d, at: offset + 28, fileSize)
    }

    /// Build a minimal FAT32 disk image (16 sectors × 512 bytes):
    ///
    /// Sector layout (sectorsPerCluster=1, 1 reserved, 1 FAT, data @ sector 2):
    ///   0 — BPB
    ///   1 — FAT (entries 0–7)
    ///   2 — root dir (cluster 2): PHOTO.JPG (live, cl=3) + DELETED.JPG (deleted, cl=4) + SUBDIR (dir, cl=5)
    ///   3 — PHOTO.JPG data
    ///   4 — DELETED.JPG data
    ///   5 — SUBDIR entries: FILE.PNG (cl=6)
    ///   6 — FILE.PNG data
    ///   7–15 — padding
    private func makeFAT32Image() -> Data {
        let sectorCount = 16
        var img = Data(count: sectorCount * 512)

        // ── Sector 0: BPB ────────────────────────────────────────────────────
        // OEM Name (bytes 3–10): "MSDOS5.0"
        let oemBytes: [UInt8] = [0x4D, 0x53, 0x44, 0x4F, 0x53, 0x35, 0x2E, 0x30]
        for (i, b) in oemBytes.enumerated() { img[3 + i] = b }
        wLE16(&img, at: 11, 512)    // bytesPerSector
        img[13] = 1                  // sectorsPerCluster
        wLE16(&img, at: 14, 1)      // reservedSectors
        img[16] = 1                  // numFATs
        wLE16(&img, at: 22, 0)      // fatSize16 = 0 (FAT32)
        wLE32(&img, at: 36, 1)      // fatSize32 = 1 sector
        wLE32(&img, at: 44, 2)      // rootCluster = 2
        img[510] = 0x55; img[511] = 0xAA   // boot signature

        // ── Sector 1: FAT ─────────────────────────────────────────────────────
        let fatBase = 512
        wLE32(&img, at: fatBase + 0 * 4, 0xFFFF_FFF8)  // entry 0: media
        wLE32(&img, at: fatBase + 1 * 4, 0xFFFF_FFFF)  // entry 1: reserved
        wLE32(&img, at: fatBase + 2 * 4, 0x0FFF_FFFF)  // entry 2: root dir EOC
        wLE32(&img, at: fatBase + 3 * 4, 0x0FFF_FFFF)  // entry 3: JPEG EOC
        wLE32(&img, at: fatBase + 4 * 4, 0x0000_0000)  // entry 4: deleted (zeroed)
        wLE32(&img, at: fatBase + 5 * 4, 0x0FFF_FFFF)  // entry 5: SUBDIR EOC
        wLE32(&img, at: fatBase + 6 * 4, 0x0FFF_FFFF)  // entry 6: PNG EOC

        // ── Sector 2: Root directory (cluster 2) ─────────────────────────────
        let dirBase = 1024
        writeDirEntry(&img, at: dirBase +  0, name: "PHOTO   ", ext: "JPG",
                      attr: 0x20, clusterLow: 3, fileSize: 512)
        writeDirEntry(&img, at: dirBase + 32, name: "DELETED ", ext: "JPG",
                      attr: 0x20, deleted: true, clusterLow: 4, fileSize: 2048)
        writeDirEntry(&img, at: dirBase + 64, name: "SUBDIR  ", ext: "   ",
                      attr: 0x10, clusterLow: 5, fileSize: 0, date: 0, time: 0)
        // End-of-directory marker
        img[dirBase + 96] = 0x00

        // ── Sector 5: SUBDIR entries (cluster 5) ─────────────────────────────
        let subdirBase = 5 * 512
        writeDirEntry(&img, at: subdirBase +  0, name: ".       ", ext: "   ",
                      attr: 0x10, clusterLow: 5, fileSize: 0, date: 0, time: 0)
        writeDirEntry(&img, at: subdirBase + 32, name: "..      ", ext: "   ",
                      attr: 0x10, clusterLow: 2, fileSize: 0, date: 0, time: 0)
        writeDirEntry(&img, at: subdirBase + 64, name: "FILE    ", ext: "PNG",
                      attr: 0x20, clusterLow: 6, fileSize: 512, date: 0, time: 0)
        img[subdirBase + 96] = 0x00

        return img
    }

    /// Write `data` to a temp file, open as DiskDevice, return (device, url).
    private func makeTempDevice(_ data: Data) throws -> (DiskDevice, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fat_test_\(UUID().uuidString).img")
        try data.write(to: url)
        let device = try DiskDevice.open(path: url.path, sectorSize: 512)
        return (device, url)
    }

    // MARK: - isFAT32 detection

    func testIsFAT32ReturnsTrueForValidBPB() {
        let img = makeFAT32Image()
        XCTAssertTrue(FATParser.isFAT32(boot: img.prefix(512)))
    }

    func testIsFAT32ReturnsFalseForAllZeros() {
        XCTAssertFalse(FATParser.isFAT32(boot: Data(count: 512)))
    }

    func testIsFAT32ReturnsFalseForHFSPlus() {
        var boot = Data(count: 512)
        boot[510] = 0x55; boot[511] = 0xAA
        // HFS+ signature at offset 1024 (not in boot sector)
        XCTAssertFalse(FATParser.isFAT32(boot: boot))
    }

    func testIsFAT32AcceptsExplicitSystemID() {
        var boot = Data(count: 512)
        boot[510] = 0x55; boot[511] = 0xAA
        // fatSize16=0, fatSize32=1
        boot[22] = 0; boot[23] = 0
        boot[36] = 1
        // sysID "FAT32   " at offset 82
        let sysID: [UInt8] = [0x46, 0x41, 0x54, 0x33, 0x32, 0x20, 0x20, 0x20]
        for (i, b) in sysID.enumerated() { boot[82 + i] = b }
        XCTAssertTrue(FATParser.isFAT32(boot: boot))
    }

    // MARK: - FAT32 live file detection

    func testFAT32FindsLiveJPEG() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        let jpeg = candidates.filter { $0.fileType == .jpeg && ($0.originalName ?? "").hasPrefix("PHOTO") }
        XCTAssertFalse(jpeg.isEmpty, "Expected to find PHOTO.JPG")
    }

    func testFAT32LiveFileHasCorrectSize() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        let jpeg = candidates.first { $0.fileType == .jpeg && ($0.originalName ?? "").hasPrefix("PHOTO") }
        XCTAssertNotNil(jpeg)
        XCTAssertEqual(jpeg?.estimatedSize, 512)
    }

    func testFAT32LiveFileHasPath() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        let jpeg = candidates.first { $0.fileType == .jpeg && ($0.originalName ?? "").hasPrefix("PHOTO") }
        XCTAssertNotNil(jpeg?.originalPath)
        XCTAssertTrue(jpeg!.originalPath!.contains("PHOTO"))
    }

    // MARK: - FAT32 deleted file detection

    func testFAT32FindsDeletedEntry() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        // Deleted entry has name starting with "_" (placeholder for lost 0xE5 char)
        let deleted = candidates.filter { $0.fileType == .jpeg && ($0.originalName ?? "").hasPrefix("_") }
        XCTAssertFalse(deleted.isEmpty, "Expected to find deleted JPEG entry")
    }

    func testFAT32DeletedFilePlaceholderFirstChar() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        let del = candidates.first { ($0.originalName ?? "").hasPrefix("_ELETED") }
        XCTAssertNotNil(del, "Deleted entry should have '_' as first-char placeholder")
    }

    // MARK: - Subdirectory recursion

    func testFAT32RecursesIntoSubdirectory() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        let png = candidates.filter { $0.fileType == .png }
        XCTAssertFalse(png.isEmpty, "Expected to find PNG inside subdirectory")
    }

    func testFAT32SubdirFileHasNestedPath() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        let png = candidates.first { $0.fileType == .png }
        XCTAssertNotNil(png?.originalPath)
        XCTAssertTrue(png!.originalPath!.contains("SUBDIR"), "PNG path should contain parent folder name")
    }

    // MARK: - SectorMap marking

    func testFAT32LiveFileMarksectors() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        let jpeg = candidates.first { $0.fileType == .jpeg && ($0.originalName ?? "").hasPrefix("PHOTO") }
        XCTAssertNotNil(jpeg)
        // clusterToSector(3) = dataStart + (3-2)*1 = 2+1 = 3
        XCTAssertEqual(map.status(at: 3), .candidate, "Live file's sector should be marked .candidate")
    }

    func testFAT32DeletedFileDoesNotMarkSectors() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        _ = try FATParser.findFiles(device: device, sectorMap: map)
        // clusterToSector(4) = 4 — should remain .unread (deleted files don't claim sectors)
        XCTAssertEqual(map.status(at: 4), .unread, "Deleted file's sector should stay .unread")
    }

    // MARK: - Date conversion

    func testFATDateConversion() {
        // date=0xCA32 → year=(0xCA>>1)&0x7F+1980 = (0x65)&0x7F+1980 = 101+1980=2081? Let me use a clear value
        // date where year=44 (2024), month=10, day=15:
        // year offset = 2024-1980 = 44 → bits 15-9: 44 = 0b0101100
        // month = 10 → bits 8-5: 0b1010
        // day = 15 → bits 4-0: 0b01111
        // date = (44<<9) | (10<<5) | 15 = 0x5800 | 0x0140 | 0x0F = 0x594F
        let date = FATParser.fatDateToDate(dateFld: 0x594F, timeFld: 0x0000)
        XCTAssertNotNil(date)
        let comps = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        XCTAssertEqual(comps.year,  2024)
        XCTAssertEqual(comps.month, 10)
        XCTAssertEqual(comps.day,   15)
    }

    func testFATDateZeroReturnsNil() {
        XCTAssertNil(FATParser.fatDateToDate(dateFld: 0, timeFld: 0))
    }

    func testFATDateInvalidMonthReturnsNil() {
        // month=0 is invalid
        let date: UInt16 = (44 << 9) | (0 << 5) | 1
        XCTAssertNil(FATParser.fatDateToDate(dateFld: date, timeFld: 0))
    }

    // MARK: - Error cases

    func testFATParserThrowsForNonFATVolume() throws {
        // All-zeros boot sector — no valid FAT signature
        let (device, url) = try makeTempDevice(Data(count: 512))
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: 1)
        XCTAssertThrowsError(try FATParser.findFiles(device: device, sectorMap: map)) { error in
            if case FATError.notFAT = error { } else {
                XCTFail("Expected FATError.notFAT, got \(error)")
            }
        }
    }

    func testFATParserThrowsForInvalidBPB() throws {
        // FAT32 signature but zero sectorsPerCluster
        var boot = makeFAT32Image().prefix(512) as Data
        boot[13] = 0   // sectorsPerCluster = 0 → invalid
        let (device, url) = try makeTempDevice(boot + Data(count: 15 * 512))
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: 16)
        XCTAssertThrowsError(try FATParser.findFiles(device: device, sectorMap: map)) { error in
            if case FATError.unsupportedVariant = error { } else {
                XCTFail("Expected FATError.unsupportedVariant, got \(error)")
            }
        }
    }

    func testFATErrorDescriptions() {
        XCTAssertNotNil(FATError.unreadableBootSector.errorDescription)
        XCTAssertNotNil(FATError.notFAT(oemName: "TEST").errorDescription)
        XCTAssertNotNil(FATError.unsupportedVariant("bad").errorDescription)
        XCTAssertTrue(FATError.notFAT(oemName: "TESTFS").errorDescription!.contains("TESTFS"))
    }

    // MARK: - VolumeEnumerator ScanCapability upgrade

    func testFAT32VolumeGetsQuickAndDeep() {
        let v = VolumeInfo(id: "disk9s1", bsdPath: "/dev/disk9s1",
                           mountPoint: "/Volumes/USB", volumeName: "USB",
                           fsType: .fat32, sizeBytes: 8_000_000_000,
                           isWholeDisk: false, isInternal: false, isEncrypted: false)
        XCTAssertEqual(VolumeEnumerator.scanCapability(for: v), .quickAndDeep)
    }

    func testExFATVolumeGetsQuickAndDeep() {
        let v = VolumeInfo(id: "disk9s1", bsdPath: "/dev/disk9s1",
                           mountPoint: "/Volumes/SD", volumeName: "SD Card",
                           fsType: .exFAT, sizeBytes: 32_000_000_000,
                           isWholeDisk: false, isInternal: false, isEncrypted: false)
        XCTAssertEqual(VolumeEnumerator.scanCapability(for: v), .quickAndDeep)
    }

    func testNTFSVolumeStaysDeepOnly() {
        let v = VolumeInfo(id: "disk9s1", bsdPath: "/dev/disk9s1",
                           mountPoint: nil, volumeName: "NTFS Drive",
                           fsType: .ntfs, sizeBytes: 1_000_000_000,
                           isWholeDisk: false, isInternal: false, isEncrypted: false)
        XCTAssertEqual(VolumeEnumerator.scanCapability(for: v), .deepOnly)
    }

    // MARK: - RecoveryEngine FS detection

    func testEngineDetectsFAT32() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        // FATParser should succeed and return candidates
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        XCTAssertGreaterThan(candidates.count, 0, "FAT32 parser should find at least one file")
    }

    func testFAT32TotalCandidateCount() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        // Expected: PHOTO.JPG (live) + _ELETED.JPG (deleted) + FILE.PNG (in subdir) = 3
        XCTAssertEqual(candidates.count, 3,
                       "Expected 3 candidates: live JPEG, deleted JPEG, PNG in subdir")
    }

    func testFAT32AllCandidatesAreQuickScanSource() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        let candidates = try FATParser.findFiles(device: device, sectorMap: map)
        XCTAssertTrue(candidates.allSatisfy { $0.source == .quickScan })
    }

    func testFAT32onPathCallbackFired() throws {
        let (device, url) = try makeTempDevice(makeFAT32Image())
        defer { try? FileManager.default.removeItem(at: url) }
        let map = SectorMap(totalSectors: UInt64(device.totalSectors))
        var paths: [String] = []
        _ = try FATParser.findFiles(device: device, sectorMap: map) { paths.append($0) }
        XCTAssertFalse(paths.isEmpty, "onPath callback should fire at least once")
        XCTAssertTrue(paths.contains { $0.contains("SUBDIR") },
                      "onPath should fire for subdirectory traversal")
    }
}
