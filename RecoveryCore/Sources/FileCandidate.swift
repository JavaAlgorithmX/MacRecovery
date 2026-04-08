import Foundation
import CryptoKit

// MARK: - FileExtent

/// A contiguous run of sectors belonging to a single file.
/// Most files occupy one extent; fragmented files have multiple.
public struct FileExtent: Codable, Equatable {
    public let startSector: UInt64
    public let sectorCount: UInt64

    public init(startSector: UInt64, sectorCount: UInt64) {
        self.startSector = startSector
        self.sectorCount = sectorCount
    }
}

// MARK: - ExtractionResult

public enum ExtractionStatus: String, Codable {
    case success = "success"   // all sectors read cleanly
    case partial = "partial"   // some bad sectors — zeros substituted
    case failed  = "failed"    // no data could be written
}

public struct ExtractionResult: Codable {
    public let candidate:    FileCandidate
    public let outputURL:    URL?          // nil if creation failed before write
    public let status:       ExtractionStatus
    public let bytesWritten: UInt64
    public let badSectors:   [UInt64]

    public var isUsable: Bool   { status != .failed }
    public var outputPath: String? { outputURL?.path }
}

// MARK: - RecoveredFileType

public enum RecoveredFileType: String, CaseIterable, Codable {
    // Images
    case jpeg = "JPEG"
    case png  = "PNG"
    case gif  = "GIF"
    case tiff = "TIFF"
    case bmp  = "BMP"
    case heic = "HEIC"
    case webp = "WebP"
    case raw  = "RAW"   // camera raw (various)

    // Video
    case mp4  = "MP4"
    case mov  = "MOV"
    case avi  = "AVI"
    case mkv  = "MKV"

    // Audio
    case mp3  = "MP3"
    case aac  = "AAC"
    case flac = "FLAC"
    case wav  = "WAV"
    case aiff = "AIFF"

    // Documents
    case pdf  = "PDF"
    case zip  = "ZIP"   // also covers docx, xlsx, pptx, epub (ZIP containers)
    case docx = "DOCX"
    case xlsx = "XLSX"
    case pptx = "PPTX"

    // Data
    case sqlite = "SQLite"
    case plist  = "plist"

    case unknown = "Unknown"

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .gif:  return "gif"
        case .tiff: return "tiff"
        case .bmp:  return "bmp"
        case .heic: return "heic"
        case .webp: return "webp"
        case .raw:  return "raw"
        case .mp4:  return "mp4"
        case .mov:  return "mov"
        case .avi:  return "avi"
        case .mkv:  return "mkv"
        case .mp3:  return "mp3"
        case .aac:  return "m4a"
        case .flac: return "flac"
        case .wav:  return "wav"
        case .aiff: return "aiff"
        case .pdf:  return "pdf"
        case .zip:  return "zip"
        case .docx: return "docx"
        case .xlsx: return "xlsx"
        case .pptx: return "pptx"
        case .sqlite: return "sqlite"
        case .plist:  return "plist"
        case .unknown: return "bin"
        }
    }
}

// MARK: - RecoverabilityScore

/// Confidence that this file can be fully recovered.
/// Displayed to the user so they can prioritise which files to save.
public enum RecoverabilityScore: Int, Codable, Comparable {
    case low      = 1  // Signature found, file likely fragmented / partially overwritten
    case medium   = 2  // Intact header + some body, may be truncated
    case high     = 3  // Intact header + body + footer, contiguous sectors
    case certain  = 4  // Recovered via inode — original file system entry intact

    public var label: String {
        switch self {
        case .low:     return "Low"
        case .medium:  return "Medium"
        case .high:    return "High"
        case .certain: return "Certain"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - FileCandidate

/// A file the engine believes it can recover.
/// Produced by both the quick scanner (from inode data) and the deep
/// scanner (from signature matching). The UI will display these in a list.
public struct FileCandidate: Identifiable, Codable {

    public let id:            UUID
    public let fileType:      RecoveredFileType
    public let startSector:   UInt64
    public let sectorCount:   UInt64     // estimated, may be 0 if unknown
    public let estimatedSize: UInt64     // bytes

    /// Original file name if recovered from inode, nil for carving results
    public let originalName: String?

    /// Original path if recovered from inode
    public let originalPath: String?

    /// Modification date if available from inode
    public let modificationDate: Date?

    /// How confident we are this file is fully intact
    public let recoverability: RecoverabilityScore

    /// Which scan mode produced this candidate
    public let source: ScanSource

    // MARK: Computed

    public var suggestedFileName: String {
        if let name = originalName { return name }
        let base = "recovered_\(startSector)"
        return "\(base).\(fileType.fileExtension)"
    }

    public var endSector: UInt64 { startSector + sectorCount }

    /// The file's sector runs in order.
    /// Currently always a single extent; multi-extent support is added when
    /// FS parsers expose HFS+/APFS fork extents.
    public var extents: [FileExtent] {
        guard sectorCount > 0 else { return [] }
        return [FileExtent(startSector: startSector, sectorCount: sectorCount)]
    }

    // MARK: Init — quick scan (from inode)

    public static func fromInode(
        fileType:         RecoveredFileType,
        startSector:      UInt64,
        sectorCount:      UInt64,
        estimatedSize:    UInt64,
        originalName:     String,
        originalPath:     String,
        modificationDate: Date?
    ) -> FileCandidate {
        FileCandidate(
            id:               UUID(),
            fileType:         fileType,
            startSector:      startSector,
            sectorCount:      sectorCount,
            estimatedSize:    estimatedSize,
            originalName:     originalName,
            originalPath:     originalPath,
            modificationDate: modificationDate,
            recoverability:   .certain,
            source:           .quickScan
        )
    }

    // MARK: Init — deep scan (from file carving)

    public static func fromCarving(
        fileType:      RecoveredFileType,
        startSector:   UInt64,
        sectorCount:   UInt64,
        estimatedSize: UInt64,
        recoverability: RecoverabilityScore = .medium
    ) -> FileCandidate {
        FileCandidate(
            id:               UUID(),
            fileType:         fileType,
            startSector:      startSector,
            sectorCount:      sectorCount,
            estimatedSize:    estimatedSize,
            originalName:     nil,
            originalPath:     nil,
            modificationDate: nil,
            recoverability:   recoverability,
            source:           .deepScan
        )
    }
}

public enum ScanSource: String, Codable {
    case quickScan = "Quick Scan"
    case deepScan  = "Deep Scan"
}

// ScanResult and ScanMode are defined in RecoveryEngine.swift
