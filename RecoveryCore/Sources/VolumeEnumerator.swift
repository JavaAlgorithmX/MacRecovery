import Foundation
import DiskArbitration
import os.log

private let log = Logger(subsystem: "com.macrecovery", category: "VolumeEnumerator")

// MARK: - VolumeInfo

/// Metadata about a single attached volume or partition.
public struct VolumeInfo: Identifiable, CustomStringConvertible {
    public let id:          String     // BSD name, e.g. "disk2s1"
    public let bsdPath:     String     // "/dev/disk2s1"
    public let mountPoint:  String?    // "/Volumes/MyDisk" if mounted
    public let volumeName:  String?
    public let fsType:      FileSystemType
    public let sizeBytes:   UInt64
    public let isWholeDisk: Bool       // true for "disk2", false for "disk2s1"
    public let isInternal:  Bool
    public let isEncrypted: Bool

    public var description: String {
        let mount = mountPoint ?? "(unmounted)"
        let name  = volumeName ?? "(unnamed)"
        return "\(bsdPath)  \(fsType.rawValue)  \(name)  \(mount)  \(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))"
    }
}

// MARK: - FileSystemType

public enum FileSystemType: String, Codable {
    case apfs    = "APFS"
    case hfsPlus = "HFS+"
    case exFAT   = "exFAT"
    case fat32   = "FAT32"
    case ntfs    = "NTFS"
    case unknown = "Unknown"

    static func from(daString: String?) -> FileSystemType {
        guard let s = daString else { return .unknown }
        switch s.uppercased() {
        case "APFS":             return .apfs
        case "JHFS+", "HFS+":   return .hfsPlus
        case "EXFAT":            return .exFAT
        case "FAT32", "MS-DOS FAT32": return .fat32
        case "NTFS":             return .ntfs
        default:                 return .unknown
        }
    }
}

// MARK: - DriveCategory

/// What kind of drive this is — used by the UI to pick an icon and sort order.
public enum DriveCategory: String, Codable {
    case internalDisk = "Internal"   // built-in SSD/HDD
    case externalDisk = "External"   // USB, Thunderbolt, SD card
    case virtualDisk  = "Virtual"    // iOS Simulator, DMG, RAM disk

    /// SF Symbol name for each category (ready for SwiftUI Image(systemName:))
    public var symbolName: String {
        switch self {
        case .internalDisk: return "internaldrive"
        case .externalDisk: return "externaldrive"
        case .virtualDisk:  return "cpu"
        }
    }

    /// Emoji fallback for CLI / non-SwiftUI contexts
    public var emoji: String {
        switch self {
        case .internalDisk: return "💻"
        case .externalDisk: return "💾"
        case .virtualDisk:  return "📱"
        }
    }
}

// MARK: - ScanCapability

/// What scan modes are available for a given volume.
public enum ScanCapability: String, Codable {
    /// APFS / HFS+ — full file-system B-tree walk + raw carving
    case quickAndDeep = "Quick + Deep"
    /// exFAT / FAT32 / NTFS — no file-system parser yet, raw carving only
    case deepOnly     = "Deep scan only"
    /// Encrypted and locked — cannot read sectors without key
    case lockedEncrypted = "Locked (encrypted)"

    public var note: String? {
        switch self {
        case .quickAndDeep:    return nil
        case .deepOnly:        return "Quick scan not available for \(self.rawValue)"
        case .lockedEncrypted: return "Unlock the volume before scanning"
        }
    }
}

// MARK: - UIVolume

/// A user-facing representation of a volume — ready to be displayed in the UI.
/// Wraps the raw `VolumeInfo` and adds all display-level metadata.
public struct UIVolume: Identifiable, Codable {
    // MARK: Identity
    public let id:          String          // BSD name e.g. "disk3s1"
    public let bsdPath:     String          // "/dev/disk3s1"

    // MARK: Display
    public let displayName:  String         // "Macintosh HD"
    public let category:     DriveCategory
    public let fsType:       FileSystemType
    public let sizeBytes:    UInt64
    public let mountPoint:   String?
    public let isEncrypted:  Bool

    /// Bytes currently used on the volume. Nil if the volume is not mounted.
    public let usedBytes:    UInt64?

    /// Bytes available on the volume. Nil if the volume is not mounted.
    public let freeBytes:    UInt64?

    // MARK: Scan metadata
    public let scanCapability: ScanCapability

    /// True for the primary internal APFS/HFS+ volume — UI can highlight this.
    public let isRecommended: Bool

    // MARK: Computed helpers for UI

    /// Human-readable total size e.g. "245.1 GB"
    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    /// Human-readable used space e.g. "128.3 GB used", or nil if unmounted.
    public var displayUsed: String? {
        usedBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + " used" }
    }

    /// Human-readable free space e.g. "116.8 GB free", or nil if unmounted.
    public var displayFree: String? {
        freeBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + " free" }
    }

    /// Used fraction 0.0–1.0 for a drive-card progress bar. Nil if unavailable.
    public var usedFraction: Double? {
        guard let used = usedBytes, sizeBytes > 0 else { return nil }
        return min(Double(used) / Double(sizeBytes), 1.0)
    }

    /// One-line subtitle for the UI card e.g. "245.1 GB  •  APFS  •  Internal"
    public var subtitle: String {
        var parts = [displaySize, fsType.rawValue, category.rawValue]
        if let note = scanCapability.note { parts.append(note) }
        return parts.joined(separator: "  •  ")
    }

    /// SF Symbol name for SwiftUI
    public var symbolName: String { category.symbolName }

    /// Emoji icon for CLI
    public var emoji: String { category.emoji }
}

// MARK: - VolumeEnumerator

/// Lists all block devices and volumes using DiskArbitration.
/// Does not require elevated privileges — DA runs as the current user.
///
/// Usage:
///   let volumes = try VolumeEnumerator.listAll()
///   volumes.forEach { print($0) }
public final class VolumeEnumerator {

    public static func listAll() throws -> [VolumeInfo] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw EnumeratorError.sessionCreationFailed
        }

        // Enumerate whole disks + partitions from the IORegistry
        var volumes: [VolumeInfo] = []
        let diskSequence = try ioRegistryDisks()

        for bsdName in diskSequence {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault,
                                                     session, bsdName) else { continue }
            guard let descRaw = DADiskCopyDescription(disk) else { continue }
            let desc = descRaw as NSDictionary

            let info = VolumeInfo(
                id:          bsdName,
                bsdPath:     "/dev/\(bsdName)",
                mountPoint:  (desc[kDADiskDescriptionVolumePathKey] as? URL)?.path,
                volumeName:  desc[kDADiskDescriptionVolumeNameKey] as? String,
                fsType:      .from(daString: desc[kDADiskDescriptionVolumeKindKey] as? String),
                sizeBytes:   (desc[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.uint64Value ?? 0,
                isWholeDisk: (desc[kDADiskDescriptionMediaWholeKey] as? Bool) ?? false,
                isInternal:  (desc[kDADiskDescriptionDeviceInternalKey] as? Bool) ?? false,
                isEncrypted: (desc[kDADiskDescriptionMediaEncryptedKey] as? Bool) ?? false
            )
            volumes.append(info)
            log.debug("Found: \(info.description)")
        }

        return volumes.sorted { $0.bsdPath < $1.bsdPath }
    }

    /// Filter to only partitions the engine can scan (excludes system-sealed volumes)
    public static func scannable() throws -> [VolumeInfo] {
        try listAll().filter { v in
            !v.isWholeDisk &&                    // skip bare disk2 containers
            v.sizeBytes > 0 &&
            !isSystemSealedVolume(v)
        }
    }

    // MARK: - UI-ready listing

    /// Returns only the volumes a user actually cares about, enriched with
    /// display metadata ready for a UI list or picker.
    ///
    /// Hides: EFI partitions, Recovery/Update/Preboot/VM volumes,
    ///        unnamed containers, and the sealed system root.
    ///
    /// Sorted: internal first → external → virtual, then alphabetically by name.
    public static func listForUI() throws -> [UIVolume] {
        let raw = try listAll()
        return raw
            .filter { isUserVisible($0) }
            .map    { makeUIVolume($0) }
            .sorted { lhs, rhs in
                let order: [DriveCategory] = [.internalDisk, .externalDisk, .virtualDisk]
                let li = order.firstIndex(of: lhs.category) ?? 99
                let ri = order.firstIndex(of: rhs.category) ?? 99
                if li != ri { return li < ri }
                return lhs.displayName < rhs.displayName
            }
    }

    /// Testable overload: accepts a pre-built array of VolumeInfo instead of
    /// calling DiskArbitration. Used by unit tests to avoid needing a real disk.
    public static func listForUI(from raw: [VolumeInfo]) -> [UIVolume] {
        raw
            .filter { isUserVisible($0) }
            .map    { makeUIVolume($0) }
            .sorted { lhs, rhs in
                let order: [DriveCategory] = [.internalDisk, .externalDisk, .virtualDisk]
                let li = order.firstIndex(of: lhs.category) ?? 99
                let ri = order.firstIndex(of: rhs.category) ?? 99
                if li != ri { return li < ri }
                return lhs.displayName < rhs.displayName
            }
    }

    // MARK: - Visibility filter

    /// True if this volume should be shown to the user.
    static func isUserVisible(_ v: VolumeInfo) -> Bool {
        // Never show whole-disk nodes (disk0, disk1 …)
        guard !v.isWholeDisk else { return false }

        // Must have a real name
        guard let name = v.volumeName, !name.isEmpty else { return false }

        // Must be a meaningful size (> 1 GB)
        guard v.sizeBytes > 1_000_000_000 else { return false }

        // Hide system-sealed root and its sub-volumes
        guard !isSystemSealedVolume(v) else { return false }

        // Apple system partition names are only meaningful on internal drives.
        // An external drive the user named "Recovery" or "Data" must never be hidden.
        if v.isInternal {
            let lowered = name.lowercased()
            let hiddenNames: [String] = ["recovery", "update", "preboot", "vm", "data"]
            for blocked in hiddenNames {
                if lowered == blocked || lowered.hasSuffix(" \(blocked)") { return false }
            }
            // Catch compound names like "APFS Recovery", "macOS Recovery", "iOS Recovery"
            if lowered.contains("recovery") { return false }
        }

        return true
    }

    // MARK: - UIVolume factory

    private static func makeUIVolume(_ v: VolumeInfo) -> UIVolume {
        let category      = driveCategory(for: v)
        let capability    = scanCapability(for: v)
        let isRecommended = category == .internalDisk &&
                            (v.fsType == .apfs || v.fsType == .hfsPlus) &&
                            !v.isEncrypted
        let space         = v.mountPoint.flatMap { spaceInfo(mountPoint: $0) }

        return UIVolume(
            id:             v.id,
            bsdPath:        v.bsdPath,
            displayName:    v.volumeName ?? v.id,
            category:       category,
            fsType:         v.fsType,
            sizeBytes:      v.sizeBytes,
            mountPoint:     v.mountPoint,
            isEncrypted:    v.isEncrypted,
            usedBytes:      space?.used,
            freeBytes:      space?.free,
            scanCapability: capability,
            isRecommended:  isRecommended
        )
    }

    /// Query the kernel for used/free bytes on a mounted volume via statfs(2).
    static func spaceInfo(mountPoint: String) -> (used: UInt64, free: UInt64)? {
        var st = statfs()
        guard statfs(mountPoint, &st) == 0 else { return nil }
        let blockSize = UInt64(st.f_bsize)
        guard blockSize > 0 else { return nil }
        let total = UInt64(st.f_blocks) * blockSize
        let free  = UInt64(st.f_bfree)  * blockSize
        let used  = total > free ? total - free : 0
        return (used, free)
    }

    // MARK: - Category detection

    static func driveCategory(for v: VolumeInfo) -> DriveCategory {
        // Mounted under developer/simulator paths → virtual
        if let mount = v.mountPoint {
            if mount.contains("CoreSimulator") ||
               mount.contains("Developer")    ||
               mount.hasPrefix("/private/var") {
                return .virtualDisk
            }
        }
        // DiskArbitration tells us internal vs external
        return v.isInternal ? .internalDisk : .externalDisk
    }

    // MARK: - Scan capability

    static func scanCapability(for v: VolumeInfo) -> ScanCapability {
        if v.isEncrypted { return .lockedEncrypted }
        switch v.fsType {
        case .apfs, .hfsPlus:          return .quickAndDeep
        case .exFAT, .fat32:           return .quickAndDeep
        case .ntfs:                    return .deepOnly
        case .unknown:                 return .deepOnly
        }
    }

    // MARK: - Private

    /// Walk the IORegistry for disk BSD names.
    /// Returns names like ["disk0", "disk0s1", "disk0s2", "disk2", "disk2s1"]
    private static func ioRegistryDisks() throws -> [String] {
        var names: [String] = []

        let matchDict = IOServiceMatching("IOMedia") as NSMutableDictionary
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iter)
        guard kr == KERN_SUCCESS else {
            throw EnumeratorError.ioRegistryFailed(kr: kr)
        }

        var service = IOIteratorNext(iter)
        while service != 0 {
            var name = [CChar](repeating: 0, count: iokit_common_err(0))
            if IORegistryEntryGetName(service, &name) == KERN_SUCCESS {
                // BSD name is stored in the "BSD Name" property
                if let bsdNameCF = IORegistryEntryCreateCFProperty(
                    service,
                    "BSD Name" as CFString,
                    kCFAllocatorDefault, 0) {
                    if let bsdName = bsdNameCF.takeRetainedValue() as? String {
                        names.append(bsdName)
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        IOObjectRelease(iter)
        return names
    }

    /// macOS Big Sur+ seals the root system volume — we can't scan it and
    /// should not try (SIP will block any raw read attempt).
    private static func isSystemSealedVolume(_ v: VolumeInfo) -> Bool {
        guard let mount = v.mountPoint else { return false }
        return mount == "/" || mount.hasPrefix("/System/Volumes/")
    }
}

// MARK: - Helper: iokit_common_err size
// io_name_t is char[128]
private func iokit_common_err(_ n: Int) -> Int { 128 }

// MARK: - Errors

public enum EnumeratorError: Error, LocalizedError {
    case sessionCreationFailed
    case ioRegistryFailed(kr: kern_return_t)

    public var errorDescription: String? {
        switch self {
        case .sessionCreationFailed:
            return "Failed to create DiskArbitration session"
        case .ioRegistryFailed(let kr):
            return "IOServiceGetMatchingServices failed: \(kr)"
        }
    }
}
