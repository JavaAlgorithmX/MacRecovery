import Foundation

// MARK: - NodeTag

/// Semantic classification of a tree node used by the UI to decide
/// what to show, hide, or highlight.
public enum NodeTag: String, Codable, Equatable {
    case normal      // ordinary user file or folder
    case system      // OS internals — hidden by default in UI
    case trash       // was inside .Trashes / Trash at time of deletion
    case recycleBin  // was inside $RECYCLE.BIN / RECYCLER
}

// MARK: - FileTreeNode

/// A node in the recovered file tree — either a folder or a file leaf.
///
/// Uses class semantics so the builder can mutate children while walking
/// the candidate list. Codable for serialisation to the UI layer.
public final class FileTreeNode: Codable {

    // MARK: Stored

    /// Display name of this node (last path component).
    public let name: String

    /// Absolute path from the volume root, e.g. `/Documents/photo.jpg`.
    public let path: String

    /// True for directory nodes, false for file leaves.
    public let isFolder: Bool

    /// Semantic tag — inherited by children when a folder is tagged.
    public let tag: NodeTag

    /// Non-nil for file leaves; nil for folder nodes.
    public let file: FileCandidate?

    /// Direct children (folders and files). Empty for file leaves.
    public internal(set) var children: [FileTreeNode]

    // MARK: Computed

    /// Recursive count of file leaves under this node (1 for file leaves).
    public var fileCount: Int {
        isFolder ? children.reduce(0) { $0 + $1.fileCount } : 1
    }

    /// Path split into components for breadcrumb display, e.g. `["Documents", "Work"]`.
    public var breadcrumbs: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: Init — folder

    init(folderName: String, path: String, tag: NodeTag = .normal) {
        self.name     = folderName
        self.path     = path
        self.isFolder = true
        self.tag      = tag
        self.file     = nil
        self.children = []
    }

    // MARK: Init — file leaf

    init(file: FileCandidate, path: String, tag: NodeTag = .normal) {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        self.name     = components.last.map(String.init) ?? file.suggestedFileName
        self.path     = path
        self.isFolder = false
        self.tag      = tag
        self.file     = file
        self.children = []
    }
}

// MARK: - FileTree

/// An in-memory tree built from a flat `[FileCandidate]` list.
///
/// Quick-scan candidates (with `originalPath`) are placed at their original
/// location. Deep-scan candidates (no path) are grouped under a synthetic
/// `(Recovered Files)` folder at the root.
///
/// Folder tags propagate to children: files inside `.Trashes` are tagged
/// `.trash`; files inside `Spotlight-V100` are tagged `.system`, etc.
public struct FileTree: Codable {

    // MARK: Public interface

    /// Synthetic root node — its `children` are the top-level folders/files.
    public let root: FileTreeNode

    /// Total file leaves in the tree (pathed + unpathed).
    public let totalFiles: Int

    /// All candidates that were inside a Trash / Recycle Bin folder.
    public let trashedFiles: [FileCandidate]

    /// All candidates tagged as system files.
    public let systemFiles: [FileCandidate]

    /// Candidates with no path info (deep-scan carving results).
    public let unpathedFiles: [FileCandidate]

    // MARK: Build

    public init(candidates: [FileCandidate]) {
        let builder = FileTreeBuilder(candidates: candidates)
        self.root         = builder.root
        self.totalFiles   = builder.totalFiles
        self.trashedFiles = builder.trashedFiles
        self.systemFiles  = builder.systemFiles
        self.unpathedFiles = builder.unpathedFiles
    }
}

// MARK: - FileTreeBuilder (internal)

private final class FileTreeBuilder {

    let root: FileTreeNode
    private(set) var totalFiles:    Int = 0
    private(set) var trashedFiles:  [FileCandidate] = []
    private(set) var systemFiles:   [FileCandidate] = []
    private(set) var unpathedFiles: [FileCandidate] = []

    /// Folder nodes keyed by their path (e.g. `"/Documents"`).
    private var folderIndex: [String: FileTreeNode] = [:]

    init(candidates: [FileCandidate]) {
        root = FileTreeNode(folderName: "/", path: "/")
        folderIndex["/"] = root

        for candidate in candidates {
            if let rawPath = candidate.originalPath, !rawPath.isEmpty {
                insert(candidate: candidate, rawPath: rawPath)
            } else {
                // Deep-scan result — no path info
                let unpathedFolder = getOrCreateFolder(path: "/(Recovered Files)",
                                                       tag: .normal)
                let filePath = "/(Recovered Files)/\(candidate.suggestedFileName)"
                let node = FileTreeNode(file: candidate, path: filePath, tag: .normal)
                unpathedFolder.children.append(node)
                unpathedFiles.append(candidate)
                totalFiles += 1
            }
        }
    }

    // MARK: - Private helpers

    private func insert(candidate: FileCandidate, rawPath: String) {
        // Normalise: ensure leading slash, clean double-slashes
        let normalised = "/" + rawPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")

        let components = normalised
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !components.isEmpty else { return }

        // Build the parent folder chain
        var folderPath = ""
        var parentTag  = NodeTag.normal
        for component in components.dropLast() {
            let childPath = folderPath + "/" + component
            let tag       = nodeTag(for: component, inheritedTag: parentTag)
            _ = getOrCreateFolder(path: childPath, tag: tag)
            folderPath = childPath
            parentTag  = tag
        }

        // File leaf
        let parentPath = folderPath.isEmpty ? "/" : folderPath
        let parent     = getOrCreateFolder(path: parentPath, tag: parentTag)
        let fileTag    = nodeTag(for: candidate.suggestedFileName, inheritedTag: parentTag)
        let fileNode   = FileTreeNode(file: candidate, path: normalised, tag: fileTag)

        parent.children.append(fileNode)
        totalFiles += 1

        switch fileTag {
        case .trash:      trashedFiles.append(candidate)
        case .system:     systemFiles.append(candidate)
        case .recycleBin: trashedFiles.append(candidate)
        case .normal:     break
        }
    }

    /// Get an existing folder node or create the full ancestor chain.
    @discardableResult
    private func getOrCreateFolder(path: String, tag: NodeTag) -> FileTreeNode {
        if let existing = folderIndex[path] { return existing }

        // Recursively ensure parent exists
        let parentPath: String
        let name: String
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.isEmpty {
            return root
        }
        name       = parts.last!
        parentPath = parts.count == 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")

        let parent    = getOrCreateFolder(path: parentPath, tag: tag)
        let resolvedTag = nodeTag(for: name, inheritedTag: tag)
        let node      = FileTreeNode(folderName: name, path: path, tag: resolvedTag)
        parent.children.append(node)
        folderIndex[path] = node
        return node
    }

    /// Determine the semantic tag for a file or folder name.
    /// Inherits parent tag (e.g. files inside .Trashes stay .trash).
    private func nodeTag(for name: String, inheritedTag: NodeTag) -> NodeTag {
        // Inherited tag always wins — don't downgrade children
        if inheritedTag != .normal { return inheritedTag }

        let lower = name.lowercased()

        if Self.systemFolderNames.contains(lower) { return .system }
        if Self.trashFolderNames.contains(lower)  { return .trash  }
        if Self.recycleBinNames.contains(lower)   { return .recycleBin }

        return .normal
    }

    // MARK: - Tag name sets

    private static let systemFolderNames: Set<String> = [
        "spotlight-v100", ".spotlight-v100",
        ".fseventsd",
        "system volume information",
        ".documentrevisions-v100",
        ".temporaryitems",
        ".pkinstallsandboxmanager",
        ".pkinstallsandboxmanager-systemcontainers",
        "fsevents",
        "lost+found",
    ]

    private static let trashFolderNames: Set<String> = [
        ".trashes", "trash", ".trash",
        // macOS per-user trash directories inside .Trashes are numeric UIDs — handled by parent inheritance
    ]

    private static let recycleBinNames: Set<String> = [
        "$recycle.bin", "recycler",
    ]
}
