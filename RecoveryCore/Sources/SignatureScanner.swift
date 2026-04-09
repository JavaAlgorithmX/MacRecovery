import Foundation
import os.log

private let log = Logger(subsystem: "com.macrecovery", category: "SignatureScanner")

// MARK: - FileSignature

/// A file type's magic bytes, offset, and size-estimation strategy.
public struct FileSignature {
    let fileType:     RecoveredFileType
    let magic:        [UInt8]       // bytes that must match at `offset`
    let offset:       Int           // byte offset within the file header
    let footerMagic:  [UInt8]?      // optional: end-of-file marker
    let maxSizeBytes: UInt64        // cap for size estimation
    let minSizeBytes: UInt64        // below this = false positive

    func matches(buffer: Data, at bufferOffset: Int) -> Bool {
        guard bufferOffset + magic.count + offset <= buffer.count else { return false }
        let start = bufferOffset + offset
        for (i, byte) in magic.enumerated() {
            guard buffer[start + i] == byte else { return false }
        }
        return true
    }
}

// MARK: - Signature table
// Magic bytes sourced from https://en.wikipedia.org/wiki/List_of_file_signatures
// and Gary Kessler's File Signatures Table.

let knownSignatures: [FileSignature] = [
    // Images
    FileSignature(fileType: .jpeg,
                  magic:        [0xFF, 0xD8, 0xFF],
                  offset:       0,
                  footerMagic:  [0xFF, 0xD9],
                  maxSizeBytes: 50 * 1024 * 1024,   // 50 MB
                  minSizeBytes: 1024),

    FileSignature(fileType: .png,
                  magic:        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                  offset:       0,
                  footerMagic:  [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82],
                  maxSizeBytes: 200 * 1024 * 1024,
                  minSizeBytes: 67),

    FileSignature(fileType: .gif,
                  magic:        [0x47, 0x49, 0x46, 0x38],   // "GIF8"
                  offset:       0,
                  footerMagic:  [0x00, 0x3B],
                  maxSizeBytes: 50 * 1024 * 1024,
                  minSizeBytes: 35),

    FileSignature(fileType: .bmp,
                  magic:        [0x42, 0x4D],               // "BM"
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 100 * 1024 * 1024,          // 100 MB hard cap
                  minSizeBytes: 54),                         // smallest valid BMP

    FileSignature(fileType: .tiff,
                  magic:        [0x49, 0x49, 0x2A, 0x00],   // little-endian
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 2 * 1024 * 1024 * 1024,
                  minSizeBytes: 8),

    FileSignature(fileType: .webp,
                  magic:        [0x57, 0x45, 0x42, 0x50],   // "WEBP" at offset 8
                  offset:       8,
                  footerMagic:  nil,
                  maxSizeBytes: 100 * 1024 * 1024,
                  minSizeBytes: 30),

    FileSignature(fileType: .heic,
                  magic:        [0x68, 0x65, 0x69, 0x63],   // "heic" ftyp at offset 8
                  offset:       8,
                  footerMagic:  nil,
                  maxSizeBytes: 100 * 1024 * 1024,
                  minSizeBytes: 1024),

    // Video
    FileSignature(fileType: .mp4,
                  magic:        [0x66, 0x74, 0x79, 0x70],   // "ftyp" at offset 4
                  offset:       4,
                  footerMagic:  nil,
                  maxSizeBytes: 50 * 1024 * 1024 * 1024,
                  minSizeBytes: 8),

    FileSignature(fileType: .avi,
                  magic:        [0x52, 0x49, 0x46, 0x46],   // "RIFF"
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 10 * 1024 * 1024 * 1024,
                  minSizeBytes: 12),

    FileSignature(fileType: .mkv,
                  magic:        [0x1A, 0x45, 0xDF, 0xA3],   // EBML header
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 50 * 1024 * 1024 * 1024,
                  minSizeBytes: 4),

    // Audio
    // MP3: ID3v2 tag header is a much more reliable anchor than raw MPEG sync bytes.
    // "ID3" at offset 0 identifies files that begin with an ID3v2 tag (nearly all modern MP3s).
    // Raw sync bytes (0xFF 0xFx) appear constantly in binary data — too many false positives.
    FileSignature(fileType: .mp3,
                  magic:        [0x49, 0x44, 0x33],         // "ID3" (ID3v2 header)
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 500 * 1024 * 1024,
                  minSizeBytes: 128),

    FileSignature(fileType: .flac,
                  magic:        [0x66, 0x4C, 0x61, 0x43],   // "fLaC"
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 2 * 1024 * 1024 * 1024,
                  minSizeBytes: 42),

    FileSignature(fileType: .wav,
                  magic:        [0x52, 0x49, 0x46, 0x46],   // "RIFF" (also AVI — disambiguate via offset 8)
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 4 * 1024 * 1024 * 1024,
                  minSizeBytes: 44),

    FileSignature(fileType: .aiff,
                  magic:        [0x46, 0x4F, 0x52, 0x4D],   // "FORM"
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 4 * 1024 * 1024 * 1024,
                  minSizeBytes: 54),

    // Documents
    FileSignature(fileType: .pdf,
                  magic:        [0x25, 0x50, 0x44, 0x46],   // "%PDF"
                  offset:       0,
                  footerMagic:  [0x25, 0x25, 0x45, 0x4F, 0x46],  // "%%EOF"
                  maxSizeBytes: 500 * 1024 * 1024,
                  minSizeBytes: 67),

    FileSignature(fileType: .zip,
                  magic:        [0x50, 0x4B, 0x03, 0x04],   // "PK\x03\x04"
                  offset:       0,
                  footerMagic:  [0x50, 0x4B, 0x05, 0x06],   // end-of-central-directory
                  maxSizeBytes: 4 * 1024 * 1024 * 1024,
                  minSizeBytes: 22),

    // SQLite
    FileSignature(fileType: .sqlite,
                  magic:        [0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
                                 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00],
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 10 * 1024 * 1024 * 1024,
                  minSizeBytes: 100),

    // plist (binary): "bplist00" — require the version bytes too so random "bplist" substrings
    // in HFS+ metadata don't trigger false positives. Also raise the minimum size.
    FileSignature(fileType: .plist,
                  magic:        [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30], // "bplist00"
                  offset:       0,
                  footerMagic:  nil,
                  maxSizeBytes: 100 * 1024 * 1024,
                  minSizeBytes: 512),
]

// MARK: - SignatureScanner

/// Reads a buffer (typically one or more sectors) and returns any file
/// signatures detected. This is the inner loop of the deep scan — called
/// millions of times per scan, so it must be fast.
public struct SignatureScanner {

    public struct Detection {
        public let fileType:    RecoveredFileType
        public let byteOffset:  Int        // offset within the supplied buffer
        public let signature:   FileSignature
    }

    /// Scan a buffer for all known file signatures.
    /// `bufferStartByte` is the absolute byte offset on the device,
    /// used to compute the sector number for each detection.
    ///
    /// **Important**: Files always begin on a sector boundary on every supported
    /// file system (HFS+, APFS, FAT32, exFAT). Searching byte-by-byte would find
    /// signatures in the middle of unrelated data, producing huge numbers of false
    /// positives. We therefore only check at `sectorSize`-aligned offsets within
    /// the buffer.
    public static func scan(buffer: Data,
                            bufferStartByte: UInt64,
                            sectorSize: UInt32) -> [Detection] {
        var detections: [Detection] = []
        let stride = Int(sectorSize)           // only check sector-aligned positions

        for sig in knownSignatures {
            let minRequired = sig.magic.count + sig.offset
            guard buffer.count >= minRequired else { continue }
            let searchEnd = buffer.count - minRequired

            var offset = 0
            while offset <= searchEnd {
                if sig.matches(buffer: buffer, at: offset) {
                    // Disambiguate RIFF: could be WAV or AVI — check bytes 8-11
                    let fileType = sig.fileType == .avi
                        ? disambiguateRIFF(buffer: buffer, at: offset)
                        : sig.fileType

                    // For BMP, validate reserved bytes (6–9) must be 0x00, and
                    // the size in bytes 2–5 must be within min/max bounds.
                    if fileType == .bmp {
                        let base = offset
                        // Reserved bytes at offsets 6-9 must be 0
                        let res6  = base + 6  < buffer.count ? buffer[base + 6]  : 0xFF
                        let res7  = base + 7  < buffer.count ? buffer[base + 7]  : 0xFF
                        let res8  = base + 8  < buffer.count ? buffer[base + 8]  : 0xFF
                        let res9  = base + 9  < buffer.count ? buffer[base + 9]  : 0xFF
                        guard res6 == 0, res7 == 0, res8 == 0, res9 == 0 else {
                            offset += stride; continue
                        }
                        // File size (bytes 2–5, little-endian) must be ≥ minSize and ≤ maxSize
                        if base + 6 <= buffer.count {
                            let rawSize = buffer.withUnsafeBytes { ptr in
                                ptr.loadUnaligned(fromByteOffset: base + 2, as: UInt32.self)
                            }
                            guard rawSize >= UInt32(sig.minSizeBytes),
                                  UInt64(rawSize) <= sig.maxSizeBytes else {
                                offset += stride; continue
                            }
                        }
                    }

                    let detection = Detection(fileType: fileType,
                                              byteOffset: offset,
                                              signature: sig)
                    detections.append(detection)
                    log.debug("Signature match: \(fileType.rawValue) at buffer+\(offset)")
                }
                offset += stride
            }
        }

        return detections
    }

    /// Given a detection, estimate how many sectors the file spans.
    /// For formats with footers (JPEG, PNG, PDF), scan forward for the footer.
    /// Otherwise use a heuristic based on max size.
    public static func estimateSize(
        detection: Detection,
        buffer: Data,
        device: DiskDevice,
        detectionAbsoluteByte: UInt64,
        sectorMap: SectorMap
    ) -> (sectorCount: UInt64, recoverability: RecoverabilityScore) {

        let sig = detection.signature

        // If we have a footer, scan forward (up to maxSize) for it
        if let footer = sig.footerMagic {
            let maxSectors = sig.maxSizeBytes / UInt64(device.sectorSize)
            let startSector = detectionAbsoluteByte / UInt64(device.sectorSize)

            for i in 0..<maxSectors {
                let sector = startSector + i
                guard let sectorData = device.readSector(sector, into: sectorMap) else {
                    // Bad sector interrupts the file — the footer can't be past a gap.
                    // Report what we have so far as a truncated/partial file.
                    return (sectorCount: max(i, 1), recoverability: .low)
                }
                if sectorData.range(of: Data(footer)) != nil {
                    let recoverability: RecoverabilityScore = i < 10 ? .high : .medium
                    return (sectorCount: i + 1, recoverability: recoverability)
                }
            }
            // Footer not found within maxSize — truncated file
            return (sectorCount: maxSectors / 4, recoverability: .low)
        }

        // For BMP: size is encoded at bytes 2-5 (little-endian UInt32).
        // Clamp to maxSizeBytes — random data here can produce absurd values.
        if sig.fileType == .bmp && buffer.count > detection.byteOffset + 6 {
            let sizeOffset = detection.byteOffset + 2
            let rawSize = buffer.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: sizeOffset, as: UInt32.self)
            }
            let clampedSize = min(UInt64(rawSize), sig.maxSizeBytes)
            guard clampedSize >= sig.minSizeBytes else {
                // Implausibly small — not a real BMP
                let fallback = (sig.maxSizeBytes / 4 + UInt64(device.sectorSize) - 1)
                             / UInt64(device.sectorSize)
                return (sectorCount: fallback, recoverability: .low)
            }
            let sectors = (clampedSize + UInt64(device.sectorSize) - 1) / UInt64(device.sectorSize)
            return (sectorCount: sectors, recoverability: .high)
        }

        // Fallback: assume 1/4 of max typical size for the format
        let typicalBytes = sig.maxSizeBytes / 4
        let sectors = (typicalBytes + UInt64(device.sectorSize) - 1) / UInt64(device.sectorSize)
        return (sectorCount: sectors, recoverability: .low)
    }

    /// Disambiguate WAV vs AVI — both start with "RIFF".
    /// WAV has "WAVE" at bytes 8-11, AVI has "AVI " at bytes 8-11.
    public static func disambiguateRIFF(buffer: Data, at offset: Int) -> RecoveredFileType {
        guard buffer.count >= offset + 12 else { return .avi }
        let subtype = Array(buffer[(offset + 8)..<(offset + 12)])
        if subtype == [0x57, 0x41, 0x56, 0x45] { return .wav }
        return .avi
    }
}
