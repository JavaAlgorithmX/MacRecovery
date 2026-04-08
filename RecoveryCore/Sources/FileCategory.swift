import Foundation

// MARK: - FileCategory

/// Top-level grouping for the Type View sidebar in the UI.
public enum FileCategory: String, CaseIterable, Codable, Equatable {
    case pictures  = "Pictures"
    case videos    = "Videos"
    case audio     = "Audio"
    case documents = "Documents"
    case archives  = "Archives"
    case databases = "Databases"
    case others    = "Others"

    /// SF Symbol name for use in SwiftUI `Image(systemName:)`.
    public var symbolName: String {
        switch self {
        case .pictures:  return "photo.on.rectangle.angled"
        case .videos:    return "film.stack"
        case .audio:     return "waveform"
        case .documents: return "doc.text"
        case .archives:  return "archivebox"
        case .databases: return "cylinder.split.1x2"
        case .others:    return "questionmark.folder"
        }
    }
}

// MARK: - RecoveredFileType → FileCategory mapping

public extension RecoveredFileType {
    var category: FileCategory {
        switch self {
        case .jpeg, .png, .gif, .tiff, .bmp, .heic, .webp, .raw:
            return .pictures
        case .mp4, .mov, .avi, .mkv:
            return .videos
        case .mp3, .aac, .flac, .wav, .aiff:
            return .audio
        case .pdf, .docx, .xlsx, .pptx:
            return .documents
        case .zip:
            return .archives
        case .sqlite, .plist:
            return .databases
        case .unknown:
            return .others
        }
    }

    /// Human-readable kind label, e.g. "MPEG-4 movie", "PNG image".
    var kindLabel: String {
        switch self {
        case .jpeg:   return "JPEG image"
        case .png:    return "PNG image"
        case .gif:    return "GIF image"
        case .tiff:   return "TIFF image"
        case .bmp:    return "BMP image"
        case .heic:   return "HEIC image"
        case .webp:   return "WebP image"
        case .raw:    return "Camera RAW image"
        case .mp4:    return "MPEG-4 movie"
        case .mov:    return "QuickTime movie"
        case .avi:    return "AVI movie"
        case .mkv:    return "Matroska video"
        case .mp3:    return "MP3 audio"
        case .aac:    return "AAC audio"
        case .flac:   return "FLAC audio"
        case .wav:    return "WAV audio"
        case .aiff:   return "AIFF audio"
        case .pdf:    return "PDF document"
        case .docx:   return "Word document"
        case .xlsx:   return "Excel spreadsheet"
        case .pptx:   return "PowerPoint presentation"
        case .zip:    return "ZIP archive"
        case .sqlite: return "SQLite database"
        case .plist:  return "Property list"
        case .unknown: return "Unknown file"
        }
    }
}

// MARK: - FileSubGroup

/// A cluster of candidates that share both a category and a file type.
/// Shown as sub-rows under each category in the Type View sidebar.
public struct FileSubGroup: Codable {
    public let fileType:   RecoveredFileType
    public let kindLabel:  String        // e.g. "JPEG image"
    public let candidates: [FileCandidate]

    public var count: Int { candidates.count }

    /// Total estimated bytes across all candidates in this sub-group.
    public var totalSize: UInt64 {
        candidates.reduce(0) { $0 + $1.estimatedSize }
    }
}

// MARK: - FileCategoryGroup

/// All candidates belonging to one top-level category, broken into sub-groups
/// by file type.
public struct FileCategoryGroup: Codable {
    public let category:   FileCategory
    public let subGroups:  [FileSubGroup]

    public var count: Int { subGroups.reduce(0) { $0 + $1.count } }

    public var totalSize: UInt64 {
        subGroups.reduce(0) { $0 + $1.totalSize }
    }

    /// Convenience: all candidates in this category flattened.
    public var candidates: [FileCandidate] {
        subGroups.flatMap(\.candidates)
    }
}

// MARK: - CategorySummary

/// The complete Type View data source built from a `[FileCandidate]` list.
///
/// Usage:
/// ```swift
/// let summary = CategorySummary(candidates: scanResult.candidates)
/// let pictureCount = summary.group(for: .pictures)?.count
/// let trashedItems = summary.trashed
/// ```
public struct CategorySummary: Codable {

    // MARK: Stored

    /// One group per category that has at least one candidate, sorted by
    /// descending candidate count.
    public let groups:  [FileCategoryGroup]

    /// Files sourced from a Trash or Recycle Bin path — quick-access bucket.
    /// Only populated when candidates carry `originalPath` info (quick scan).
    public let trashed: [FileCandidate]

    /// Total candidate count across all groups.
    public let totalCount: Int

    /// Total estimated size across all groups.
    public let totalSize: UInt64

    // MARK: Build

    public init(candidates: [FileCandidate], trashed: [FileCandidate] = []) {
        // Group by category, then by file type within each category
        var byCategory: [FileCategory: [RecoveredFileType: [FileCandidate]]] = [:]

        for candidate in candidates {
            let cat  = candidate.fileType.category
            let type = candidate.fileType
            byCategory[cat, default: [:]][type, default: []].append(candidate)
        }

        // Build FileCategoryGroup list, sorted by count descending
        self.groups = FileCategory.allCases.compactMap { category in
            guard let typeMap = byCategory[category] else { return nil }
            let subGroups = typeMap
                .map { type, list in
                    FileSubGroup(fileType: type, kindLabel: type.kindLabel, candidates: list)
                }
                .sorted { $0.count > $1.count }
            return FileCategoryGroup(category: category, subGroups: subGroups)
        }
        .sorted { $0.count > $1.count }

        self.trashed    = trashed
        self.totalCount = groups.reduce(0) { $0 + $1.count }
        self.totalSize  = groups.reduce(0) { $0 + $1.totalSize }
    }

    // MARK: Lookup

    /// Returns the group for a given category, or nil if no candidates exist for it.
    public func group(for category: FileCategory) -> FileCategoryGroup? {
        groups.first { $0.category == category }
    }
}
