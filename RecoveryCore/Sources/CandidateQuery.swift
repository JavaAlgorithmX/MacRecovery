import Foundation

// MARK: - SortOrder

/// Dimension to sort `[FileCandidate]` results by.
public enum SortOrder: String, Codable, CaseIterable, Equatable {
    case name           = "name"
    case date           = "date"
    case size           = "size"
    case recoverability = "recoverability"
}

// MARK: - CandidateQuery

/// A composable filter + sort specification applied by `CandidateIndex.search(...)`.
///
/// All non-nil fields are ANDed together — a candidate must satisfy every
/// active constraint to appear in results.
///
/// Usage:
/// ```swift
/// let query = CandidateQuery(
///     nameContains:  "vacation",
///     fileTypes:     [.jpeg, .png],
///     minScore:      .medium,
///     sortBy:        .date
/// )
/// let results = index.search(query: query)
/// ```
public struct CandidateQuery {

    // MARK: Filter dimensions

    /// Case-insensitive substring match against `suggestedFileName`.
    /// nil = no name filter.
    public var nameContains: String?

    /// Only return candidates whose `fileType` is in this set.
    /// nil = all types.
    public var fileTypes: Set<RecoveredFileType>?

    /// Only return candidates whose `fileType.category` is in this set.
    /// nil = all categories.
    public var categories: Set<FileCategory>?

    /// Only return candidates with `modificationDate` inside this range.
    /// nil = no date filter. Candidates without a date are excluded when this
    /// filter is active.
    public var dateRange: ClosedRange<Date>?

    /// Only return candidates whose `estimatedSize` is inside this range (bytes).
    /// nil = no size filter.
    public var sizeRange: ClosedRange<UInt64>?

    /// Only return candidates with `recoverability >= minScore`.
    /// nil = no score filter.
    public var minScore: RecoverabilityScore?

    /// Only return candidates from this scan source.
    /// nil = both quick and deep scan.
    public var source: ScanSource?

    // MARK: Sort

    /// Primary sort dimension. Defaults to `.recoverability` (highest first).
    public var sortBy: SortOrder

    /// When true, results are returned in ascending order; descending otherwise.
    /// Default: false (descending).
    public var ascending: Bool

    // MARK: Init

    public init(
        nameContains: String?                    = nil,
        fileTypes:    Set<RecoveredFileType>?    = nil,
        categories:   Set<FileCategory>?         = nil,
        dateRange:    ClosedRange<Date>?          = nil,
        sizeRange:    ClosedRange<UInt64>?        = nil,
        minScore:     RecoverabilityScore?        = nil,
        source:       ScanSource?                = nil,
        sortBy:       SortOrder                  = .recoverability,
        ascending:    Bool                       = false
    ) {
        self.nameContains = nameContains
        self.fileTypes    = fileTypes
        self.categories   = categories
        self.dateRange    = dateRange
        self.sizeRange    = sizeRange
        self.minScore     = minScore
        self.source       = source
        self.sortBy       = sortBy
        self.ascending    = ascending
    }

    /// Convenience: empty query that returns everything sorted by recoverability.
    public static var all: CandidateQuery { CandidateQuery() }
}

// MARK: - CandidateIndex

/// Wraps a flat `[FileCandidate]` list and exposes filtered + sorted queries.
///
/// Construct once from a `ScanResult.candidates` array, then call `search()`
/// as many times as needed (e.g. as the user types in the search box).
public struct CandidateIndex {

    public let candidates: [FileCandidate]

    public init(candidates: [FileCandidate]) {
        self.candidates = candidates
    }

    public init(result: ScanResult) {
        self.candidates = result.candidates
    }

    // MARK: - Search

    /// Apply `query` and return a filtered, sorted slice of candidates.
    public func search(query: CandidateQuery = .all) -> [FileCandidate] {
        var results = candidates

        // ── Name filter ──────────────────────────────────────────────────────
        if let name = query.nameContains, !name.isEmpty {
            let lower = name.lowercased()
            results = results.filter {
                $0.suggestedFileName.lowercased().contains(lower)
            }
        }

        // ── File type filter ─────────────────────────────────────────────────
        if let types = query.fileTypes, !types.isEmpty {
            results = results.filter { types.contains($0.fileType) }
        }

        // ── Category filter ──────────────────────────────────────────────────
        if let cats = query.categories, !cats.isEmpty {
            results = results.filter { cats.contains($0.fileType.category) }
        }

        // ── Date range filter ────────────────────────────────────────────────
        if let range = query.dateRange {
            results = results.filter { c in
                guard let date = c.modificationDate else { return false }
                return range.contains(date)
            }
        }

        // ── Size range filter ────────────────────────────────────────────────
        if let range = query.sizeRange {
            results = results.filter { range.contains($0.estimatedSize) }
        }

        // ── Minimum score filter ─────────────────────────────────────────────
        if let min = query.minScore {
            results = results.filter { $0.recoverability >= min }
        }

        // ── Source filter ────────────────────────────────────────────────────
        if let src = query.source {
            results = results.filter { $0.source == src }
        }

        // ── Sort ─────────────────────────────────────────────────────────────
        results.sort { a, b in
            let less: Bool
            switch query.sortBy {
            case .name:
                less = a.suggestedFileName.localizedCompare(b.suggestedFileName) == .orderedAscending
            case .date:
                switch (a.modificationDate, b.modificationDate) {
                case (nil, nil):   less = false
                case (nil, _):     less = false   // undated goes to end
                case (_, nil):     less = true
                case (let d1?, let d2?): less = d1 < d2
                }
            case .size:
                less = a.estimatedSize < b.estimatedSize
            case .recoverability:
                less = a.recoverability < b.recoverability
            }
            return query.ascending ? less : !less
        }

        return results
    }

    // MARK: - Convenience queries

    /// All candidates matching a name substring, sorted by recoverability.
    public func search(name: String) -> [FileCandidate] {
        search(query: CandidateQuery(nameContains: name))
    }

    /// All candidates of a specific type, sorted by recoverability.
    public func search(type: RecoveredFileType) -> [FileCandidate] {
        search(query: CandidateQuery(fileTypes: [type]))
    }

    /// All candidates in a category, sorted by recoverability.
    public func search(category: FileCategory) -> [FileCandidate] {
        search(query: CandidateQuery(categories: [category]))
    }

    /// Total candidate count for a given file type.
    public func count(for type: RecoveredFileType) -> Int {
        candidates.filter { $0.fileType == type }.count
    }

    /// Total candidate count for a given category.
    public func count(for category: FileCategory) -> Int {
        candidates.filter { $0.fileType.category == category }.count
    }
}
