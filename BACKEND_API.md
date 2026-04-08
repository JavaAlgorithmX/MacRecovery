# MacRecovery — Backend API Reference

> **Module:** `RecoveryCore`
> **Platform:** macOS 13+
> **Swift tools:** 5.9
> **Last updated:** Phase 8B (Async/Await Refactor)

This document describes every public type, method, and property in `RecoveryCore`.
It is the contract between the backend and any UI layer (SwiftUI, CLI, or XPC service).

---

## Table of Contents

1. [DiskDevice](#1-diskdevice)
2. [SectorMap](#2-sectormap)
3. [SignatureScanner](#3-signaturescanner)
4. [FileCandidate & Related Types](#4-filecandidate--related-types)
5. [RecoveryEngine](#5-recoveryengine)
6. [VolumeEnumerator](#6-volumeenumerator)
7. [HFSParser](#7-hfsparser)
8. [APFSParser](#8-apfsparser)
9. [FATParser](#9-fatparser)
10. [FileExtractor](#10-fileextractor)
11. [FileTree](#11-filetree)
12. [FileCategory](#12-filecategory)
13. [CandidateQuery & CandidateIndex](#13-candidatequery--candidateindex)
14. [PreviewProvider](#14-previewprovider)
15. [Error Types](#15-error-types)

---

## 1. DiskDevice

**File:** `DiskDevice.swift`
**Purpose:** Read-only abstraction over a block device (`/dev/diskN`) or disk image file (`.dmg`). All I/O goes through `pread(2)` — the device is never written to.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `path` | `String` | Device path passed to `open(path:)` |
| `sectorSize` | `UInt32` | Bytes per sector (default 512) |
| `totalSectors` | `UInt64` | Total addressable sectors on the device |
| `totalBytes` | `UInt64` | `totalSectors × sectorSize` |

### Methods

#### `DiskDevice.open(path:sectorSize:) throws -> DiskDevice`
Opens a device or image file for reading.
- For block devices: uses `DKIOCGETBLOCKCOUNT` / `DKIOCGETBLOCKSIZE` ioctls (requires Full Disk Access or root).
- For regular files: uses `fstat(2)`.
- **Throws:** `DiskError.openFailed`, `DiskError.statFailed`, `DiskError.ioctlFailed`

```swift
let device = try DiskDevice.open(path: "/dev/disk2s1")
let image  = try DiskDevice.open(path: "/tmp/test.dmg")
```

#### `readSectors(startingSector:count:into:) -> Data?`
Read `count` sectors starting at `startingSector`. Returns `nil` and marks sectors bad on I/O error. Does **not** throw — bad sectors are a normal occurrence on damaged drives.
- `into: SectorMap?` — when non-nil, marks failed sectors as `.badSector`

#### `readSector(_:into:) -> Data?`
Convenience wrapper around `readSectors` for a single sector.

#### `readWithRetry(startingSector:count:sectorMap:) -> Data?`
Two-pass read: attempts the full multi-sector read first (fast), then falls back to sector-by-sector if it fails. Returns a contiguous `Data` buffer where unreadable sectors are zero-padded. Updates `sectorMap` with `.clean` or `.badSector` states.

### Errors — `DiskError`

| Case | When thrown |
|------|-------------|
| `openFailed(path:errno:)` | `open(2)` returned -1 |
| `statFailed(path:errno:)` | `fstat(2)` failed |
| `ioctlFailed(path:errno:)` | ioctl for block count/size failed |
| `readFailed(sector:errno:)` | Unused externally; internal signal |
| `outOfBounds(sector:total:)` | Read would exceed device size |

---

## 2. SectorMap

**File:** `SectorMap.swift`
**Purpose:** Thread-safe bitmap storing the state of every sector on a device. Used as the single source of truth for scan progress, bad-sector tracking, and pause/resume support. Conforms to `@unchecked Sendable`.

### `SectorState` enum

| Case | Raw | Meaning |
|------|-----|---------|
| `.unread` | 0 | Not yet visited by any scan pass |
| `.clean` | 1 | Read successfully, no file found |
| `.candidate` | 2 | Contains a file signature or inode record |
| `.badSector` | 3 | I/O error — unreadable |
| `.skipped` | 4 | Intentionally bypassed (e.g. known-zero region) |

### Init

```swift
let map = SectorMap(totalSectors: device.totalSectors, sectorSize: device.sectorSize)
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `totalSectors` | `UInt64` | Mirror of the device sector count |
| `sectorSize` | `UInt32` | Mirror of the device sector size |
| `totalBytes` | `UInt64` | Computed: `totalSectors × sectorSize` |

### Methods

#### `status(at:) -> SectorState`
Returns the current state of a sector. Returns `.skipped` for out-of-bounds indices.

#### `mark(sector:as:)`
Set the state of a single sector. Silently ignores out-of-bounds sectors.

#### `mark(range:as:)`
Set the state of a `Range<UInt64>` of sectors in one call (clamped to valid range).

#### `progress() -> SectorMap.Progress`
Scan-safe snapshot of current progress. Returns:
- `scanned: UInt64` — sectors with any state ≠ `.unread`
- `total: UInt64` — total sectors
- `badSectors: UInt64` — sectors marked `.badSector`
- `candidates: UInt64` — sectors marked `.candidate`
- `percentComplete: Double` — `scanned / total × 100`

#### `nextUnread(from:) -> UInt64?`
Returns the first unread sector at or after `from`, or `nil` if none remain.

#### `badSectors() -> [UInt64]`
Returns all sector indices currently marked `.badSector`.

#### `save(to:) throws`
Serialize the map state to a binary file. Used when pausing a scan.

#### `SectorMap.load(from:totalSectors:sectorSize:) throws -> SectorMap`
Reload a saved map. Validates that the saved file's byte count matches `totalSectors`. **Throws:** `SectorMapError.sectorCountMismatch`

---

## 3. SignatureScanner

**File:** `SignatureScanner.swift`
**Purpose:** Scans a raw data buffer for known file magic bytes. The inner loop of the deep scan — called millions of times per scan run.

### `SignatureScanner.scan(buffer:bufferStartByte:sectorSize:) -> [Detection]`
Slide every known signature over `buffer` and return all matches.
- `bufferStartByte` — absolute byte offset on the device (used to compute sector number)
- Returns an array of `Detection` structs (may be empty)

### `SignatureScanner.estimateSize(detection:buffer:device:detectionAbsoluteByte:sectorMap:) -> (sectorCount: UInt64, recoverability: RecoverabilityScore)`
Given a detection, estimate file extent:
- **With footer magic** (JPEG, PNG, PDF, GIF, ZIP): scans forward up to `maxSizeBytes` to find the footer. Returns `.high` if found within 10 sectors, `.medium` if found later, `.low` if not found.
- **BMP**: reads the 4-byte embedded size field at offset 2.
- **Fallback**: returns `maxSize / 4` sectors and `.low` recoverability.

### `SignatureScanner.disambiguateRIFF(buffer:at:) -> RecoveredFileType`
Resolves the WAV vs AVI ambiguity — both use the `RIFF` magic header. Reads bytes 8–11: `"WAVE"` → `.wav`, otherwise → `.avi`.

### `Detection` struct

| Field | Type | Description |
|-------|------|-------------|
| `fileType` | `RecoveredFileType` | The matched type |
| `byteOffset` | `Int` | Byte offset within the supplied buffer |
| `signature` | `FileSignature` | The matching signature definition |

### Supported file types (25+)

| Category | Types |
|----------|-------|
| Images | JPEG, PNG, GIF, BMP, TIFF, WebP, HEIC |
| Video | MP4, AVI, MKV (MOV covered by MP4 "ftyp") |
| Audio | MP3, FLAC, WAV, AIFF |
| Documents | PDF, ZIP (also DOCX/XLSX/PPTX) |
| Data | SQLite, binary plist |

---

## 4. FileCandidate & Related Types

**File:** `FileCandidate.swift`
**Purpose:** Core data model. A `FileCandidate` represents one file the engine believes it can recover. All scan output is ultimately a `[FileCandidate]`.

### `RecoveredFileType` enum
`String`, `CaseIterable`, `Codable`. 25+ cases. Key computed properties:
- `fileExtension: String` — e.g. `.jpeg → "jpg"`, `.mp4 → "mp4"`

### `RecoverabilityScore` enum
`Int`, `Comparable`, `Codable`. Tells the user how confident the engine is.

| Case | Raw | Meaning |
|------|-----|---------|
| `.low` | 1 | Signature found only; likely fragmented or overwritten |
| `.medium` | 2 | Intact header + body; may be truncated |
| `.high` | 3 | Header + body + footer found; contiguous sectors |
| `.certain` | 4 | Recovered via inode — original FS record intact |

- `label: String` — "Low" / "Medium" / "High" / "Certain"

### `ScanSource` enum
- `.quickScan` — produced by a file-system parser (HFS+, APFS, FAT32/exFAT)
- `.deepScan` — produced by signature carving

### `FileExtent` struct
Codable, Equatable. Represents one contiguous run of sectors for a file.

| Property | Type |
|----------|------|
| `startSector` | `UInt64` |
| `sectorCount` | `UInt64` |

### `FileCandidate` struct
`Identifiable`, `Codable`.

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Unique identity |
| `fileType` | `RecoveredFileType` | Detected type |
| `startSector` | `UInt64` | First sector of file data |
| `sectorCount` | `UInt64` | Estimated extent length (may be 0) |
| `estimatedSize` | `UInt64` | Estimated byte size |
| `originalName` | `String?` | From inode; nil for carving results |
| `originalPath` | `String?` | Full path from FS walk; nil for carving |
| `modificationDate` | `Date?` | From inode; nil for carving results |
| `recoverability` | `RecoverabilityScore` | Confidence level |
| `source` | `ScanSource` | Quick or deep scan |

**Computed:**
- `suggestedFileName: String` — `originalName` if available, else `"recovered_<sector>.<ext>"`
- `endSector: UInt64` — `startSector + sectorCount`
- `extents: [FileExtent]` — single-extent today; multi-extent when FS parsers expose fork data

#### `FileCandidate.fromInode(...) -> FileCandidate`
Factory for quick-scan (inode) candidates. Always sets `recoverability = .certain` and `source = .quickScan`.
```swift
FileCandidate.fromInode(
    fileType:         .jpeg,
    startSector:      1024,
    sectorCount:      8,
    estimatedSize:    4096,
    originalName:     "photo.jpg",
    originalPath:     "/DCIM/photo.jpg",
    modificationDate: Date()
)
```

#### `FileCandidate.fromCarving(...) -> FileCandidate`
Factory for deep-scan (carving) candidates. No name/path/date. Default `recoverability = .medium`.
```swift
FileCandidate.fromCarving(
    fileType:       .png,
    startSector:    2048,
    sectorCount:    4,
    estimatedSize:  2048,
    recoverability: .high
)
```

### `ExtractionStatus` enum
- `.success` — all sectors read cleanly
- `.partial` — some bad sectors; zeros substituted
- `.failed` — no data could be written

### `ExtractionResult` struct
Codable. Returned by `FileExtractor` after extracting one file.

| Property | Type | Description |
|----------|------|-------------|
| `candidate` | `FileCandidate` | The source candidate |
| `outputURL` | `URL?` | Where the file was written; nil if creation failed |
| `status` | `ExtractionStatus` | |
| `bytesWritten` | `UInt64` | Actual bytes written to disk |
| `badSectors` | `[UInt64]` | Sector numbers that could not be read |
| `isUsable` | `Bool` | `status != .failed` |
| `outputPath` | `String?` | `outputURL?.path` |

---

## 5. RecoveryEngine

**File:** `RecoveryEngine.swift`
**Purpose:** Orchestrates a full recovery scan. Detects the file system, runs the quick scan (FS parser) and/or the deep scan (file carving), deduplicates results, and streams progress to the caller. All long-running paths are `async`.

### `ScanMode` enum
- `.quick` — file-system parser only (fast, finds named files)
- `.deep` — file carving only (slow, finds everything regardless of FS)
- `.both` — quick then deep in sequence

### `ScanConfiguration` struct

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `mode` | `ScanMode` | `.quick` | Which scan passes to run |
| `sectorsPerRead` | `UInt32` | 128 | Sectors per `pread` call (~64 KB) |
| `maxCandidates` | `Int` | 50,000 | Stop deep scan after this many finds |
| `targetTypes` | `Set<RecoveredFileType>?` | nil | Restrict to these types; nil = all |
| `outputDirectory` | `URL?` | nil | Where recovered files go |
| `checkpointDirectory` | `URL?` | nil | Where pause state is saved; defaults to `NSTemporaryDirectory()` |

### `ScanPhase` enum
Progress label reported during a scan.

| Case | Meaning |
|------|---------|
| `.opening` | Opening the device |
| `.quickScan` | File-system parser running |
| `.deepScan` | Sector-by-sector carving |
| `.organising` | Deduplication and final sort |
| `.complete` | Scan finished successfully |
| `.paused` | Scan suspended at a checkpoint |
| `.failed` | Unrecoverable error |

### `ScanProgress` struct
Snapshot delivered to the `onProgress` callback on every significant change.

| Property | Type | Description |
|----------|------|-------------|
| `phase` | `ScanPhase` | Current stage |
| `percent` | `Double` | Overall 0–100 across all phases |
| `quickScanPercent` | `Double` | Quick-scan phase 0–100 (100 when done) |
| `deepScanPercent` | `Double` | Deep-scan phase 0–100 (0 until started) |
| `speed` | `Double` | Current throughput in MB/s |
| `eta` | `TimeInterval` | Estimated seconds remaining |
| `candidateCount` | `Int` | Files found so far |
| `badSectorCount` | `Int` | Bad sectors encountered |
| `currentSector` | `UInt64` | Current read head position |
| `currentPath` | `String?` | File path being processed (quick scan only) |
| `totalFoundBytes` | `UInt64` | Sum of `estimatedSize` of all candidates |

### `ScanCheckpoint` struct
Codable. Written to disk when a scan is paused. Passed back to `resume()`.

| Property | Type |
|----------|------|
| `devicePath` | `String` |
| `mode` | `ScanMode` |
| `resumeSector` | `UInt64` |
| `candidates` | `[FileCandidate]` |
| `sectorMapFile` | `String` |

### `ScanResult` struct
Codable. The final output of a completed or paused scan.

| Property | Type | Description |
|----------|------|-------------|
| `devicePath` | `String` | Device that was scanned |
| `scanMode` | `ScanMode` | Mode that was run |
| `startedAt` | `Date` | When the scan began |
| `completedAt` | `Date?` | When it finished (nil if paused) |
| `candidates` | `[FileCandidate]` | All found files, deduped and sorted |
| `sectorsScanned` | `UInt64` | How many sectors were read |
| `badSectors` | `[UInt64]` | All unreadable sector addresses |
| `isPaused` | `Bool` | True if scan was suspended |
| `checkpointURL` | `URL?` | Path to checkpoint JSON; non-nil when paused |
| `duration` | `TimeInterval?` | Computed: `completedAt - startedAt` |
| `totalRecoverable` | `Int` | Candidates with score ≥ `.medium` |

### `RecoveryEngine` class

#### `init(config:)`
```swift
let engine = RecoveryEngine(config: ScanConfiguration())
// or:
var config = ScanConfiguration()
config.mode = .both
config.targetTypes = [.jpeg, .png]
let engine = RecoveryEngine(config: config)
```

#### `scan(devicePath:onProgress:) async throws -> ScanResult`
Run a full scan. **Must be called from an async context** (SwiftUI `Task`, `async` function, or bridged with `DispatchSemaphore` for CLI).

- Opens the device, detects the file system, runs quick scan and/or deep scan per `config.mode`
- Calls `onProgress` on every meaningful state change
- Deep scan calls `await Task.yield()` every 256 sectors — keeps UI responsive
- If paused mid-scan, saves a checkpoint and returns `ScanResult` with `isPaused = true`
- **Throws:** `CancellationError` (via `cancel()` or `Task.cancel()`), `DiskError`, parser errors

```swift
// SwiftUI:
let result = try await engine.scan(devicePath: "/dev/disk2s1") { progress in
    await MainActor.run { self.progress = progress }
}

// CLI (sync context):
var scanResult: ScanResult?
var scanError:  Error?
let sema = DispatchSemaphore(value: 0)
Task {
    do    { scanResult = try await engine.scan(devicePath: path, onProgress: render) }
    catch { scanError = error }
    sema.signal()
}
sema.wait()
```

#### `resume(checkpointURL:onProgress:) async throws -> ScanResult`
Resume a previously paused scan from a `ScanCheckpoint` JSON file.
- Loads the checkpoint and its associated `SectorMap` binary
- Continues the deep scan from `checkpoint.resumeSector`
- Same progress / pause / cancel semantics as `scan()`

#### `scanStream(devicePath:) -> (stream: AsyncStream<ScanProgress>, task: Task<ScanResult, Error>)`
SwiftUI-optimised wrapper around `scan()`. Returns:
- `stream` — an `AsyncStream` that yields `ScanProgress` values as the scan runs
- `task` — the underlying `Task`; `await task.value` returns the `ScanResult`; `task.cancel()` cancels the scan

```swift
let (stream, task) = engine.scanStream(devicePath: path)
for await progress in stream {
    await MainActor.run { self.progress = progress }
}
let result = try await task.value
```

#### `resumeStream(checkpointURL:) -> (stream: AsyncStream<ScanProgress>, task: Task<ScanResult, Error>)`
Same as `scanStream` but resumes from a checkpoint.

#### `cancel()`
Signal the engine to stop at the next iteration. Works from any context. Prefer `task.cancel()` when using structured concurrency — `cancel()` exists for legacy callers.

#### `requestPause()`
Signal the engine to pause at the next safe checkpoint in the deep scan. The scan will complete the current sector, save state, and return a `ScanResult` with `isPaused = true`.

---

## 6. VolumeEnumerator

**File:** `VolumeEnumerator.swift`
**Purpose:** Enumerates all attached block devices and volumes via DiskArbitration and IOKit. No elevated privileges required. Provides UI-ready metadata including drive categories, scan capabilities, and used/free space.

### `FileSystemType` enum
`String`, `Codable`. `.apfs`, `.hfsPlus`, `.exFAT`, `.fat32`, `.ntfs`, `.unknown`

### `DriveCategory` enum
`String`, `Codable`.

| Case | `symbolName` | `emoji` |
|------|-------------|---------|
| `.internalDisk` | `"internaldrive"` | 💻 |
| `.externalDisk` | `"externaldrive"` | 💾 |
| `.virtualDisk` | `"cpu"` | 📱 |

### `ScanCapability` enum
`String`, `Codable`.

| Case | File Systems | `note` |
|------|-------------|--------|
| `.quickAndDeep` | APFS, HFS+, FAT32, exFAT | nil |
| `.deepOnly` | NTFS, unknown | warning string |
| `.lockedEncrypted` | any encrypted | unlock reminder |

### `VolumeInfo` struct
Raw DiskArbitration data for one partition. Used internally and in `scannable()`.

| Property | Type |
|----------|------|
| `id` | `String` (BSD name, e.g. `"disk2s1"`) |
| `bsdPath` | `String` (`"/dev/disk2s1"`) |
| `mountPoint` | `String?` |
| `volumeName` | `String?` |
| `fsType` | `FileSystemType` |
| `sizeBytes` | `UInt64` |
| `isWholeDisk` | `Bool` |
| `isInternal` | `Bool` |
| `isEncrypted` | `Bool` |

### `UIVolume` struct
`Identifiable`, `Codable`. Enriched view of a volume for the UI layer.

| Property | Type | Description |
|----------|------|-------------|
| `id` | `String` | BSD name |
| `bsdPath` | `String` | Full device path |
| `displayName` | `String` | Volume name or BSD name |
| `category` | `DriveCategory` | Internal / external / virtual |
| `fsType` | `FileSystemType` | |
| `sizeBytes` | `UInt64` | |
| `mountPoint` | `String?` | |
| `isEncrypted` | `Bool` | |
| `usedBytes` | `UInt64?` | From `statfs(2)`; nil if unmounted |
| `freeBytes` | `UInt64?` | From `statfs(2)`; nil if unmounted |
| `scanCapability` | `ScanCapability` | |
| `isRecommended` | `Bool` | True for unencrypted internal APFS/HFS+ |
| `displaySize` | `String` | e.g. `"245.1 GB"` |
| `displayUsed` | `String?` | e.g. `"128.3 GB used"` |
| `displayFree` | `String?` | e.g. `"116.8 GB free"` |
| `usedFraction` | `Double?` | 0.0–1.0 for a space bar |
| `subtitle` | `String` | e.g. `"245.1 GB  •  APFS  •  Internal"` |
| `symbolName` | `String` | SF Symbol name for `Image(systemName:)` |
| `emoji` | `String` | CLI fallback icon |

### Methods

#### `VolumeEnumerator.listAll() throws -> [VolumeInfo]`
Every partition found by IOKit + DiskArbitration, sorted by BSD path.

#### `VolumeEnumerator.scannable() throws -> [VolumeInfo]`
Filtered to partitions the engine can open: no whole-disk nodes, non-zero size, not system-sealed.

#### `VolumeEnumerator.listForUI() throws -> [UIVolume]`
UI-ready filtered list. Hides:
- Whole-disk container nodes
- Unnamed volumes
- Volumes < 1 GB
- System-sealed root (`/`, `/System/Volumes/*`)
- Internal system partition names: Recovery, Update, Preboot, VM, Data (external drives with these names are **always shown**)

Sorted: internal → external → virtual, then alphabetically by name.

#### `VolumeEnumerator.listForUI(from:) -> [UIVolume]`
Testable overload that accepts a pre-built `[VolumeInfo]` instead of calling DiskArbitration.

---

## 7. HFSParser

**File:** `HFSParser.swift`
**Purpose:** Quick-scan parser for HFS+ volumes. Walks the Catalog B-tree to find deleted file records and builds `FileCandidate` entries with original names, paths, and dates.

#### `HFSParser.findDeletedFiles(device:sectorMap:onPath:) throws -> [FileCandidate]`
Main entry point. Parses the HFS+ Volume Header, locates the Catalog B-tree, walks all leaf nodes, and returns candidates for deleted files.
- `onPath` — called with the `originalPath` string as each file is discovered (drives the quick-scan `currentPath` progress field)
- Marks live file sectors as `.candidate` in `sectorMap`
- **Throws:** `HFSError.*` if the volume header or B-tree cannot be read

**What it parses:**
- Volume Header at byte offset 1024: block size, total blocks, catalog file extents
- B-tree header node: root node address, node size
- B-tree leaf nodes: catalog records (type 2 = file, type -1 = deleted)
- File record: data fork first extent (start block, block count), data size, modification date
- Filename: UTF-16BE, up to 255 chars

---

## 8. APFSParser

**File:** `APFSParser.swift`
**Purpose:** Quick-scan parser for APFS volumes. Navigates Container Superblock → Object Map → Volume Superblock → FS B-tree to find all files (live and recently deleted).

#### `APFSParser.findFiles(device:sectorMap:onPath:) throws -> [FileCandidate]`
Main entry point.
- Parses the NXSB (Container Superblock) at block 0: block size, volume OIDs, omap OID
- Walks the container Object Map B-tree to resolve OIDs → physical blocks
- Parses each APSB (Volume Superblock): volume omap, FS root tree OID
- Walks volume Object Map then FS B-tree leaf nodes
- Joins inode records with dir-entry records by inode number to recover filenames
- Marks live sectors as `.candidate` in `sectorMap`
- **Throws:** `APFSError.*`

**What it parses:**
- `NXSB` magic (0x4253584E) at block 0
- `APSB` magic (0x42535041) per volume
- APFS nanosecond timestamps → `Date`
- Little-endian `UInt16/32/64` throughout

---

## 9. FATParser

**File:** `FATParser.swift`
**Purpose:** Quick-scan parser for FAT32 and exFAT volumes. Handles both active and deleted directory entries.

#### `FATParser.findFiles(device:sectorMap:onPath:) throws -> [FileCandidate]`
Main entry point. Detects FAT variant from the OEM name in the boot sector, then dispatches to FAT32 or exFAT parsing logic.
- **Throws:** `FATError.*`

#### `FATParser.isFAT32(boot:) -> Bool`
Static helper. Returns true if the 512-byte boot sector `boot` describes a valid FAT32 BPB. Used by `RecoveryEngine.detectFileSystem()`.

#### `FATParser.fatDateToDate(dateFld:timeFld:) -> Date?`
Converts the packed FAT date/time fields to a Swift `Date`. Year offset from 1980, standard bit-packing.

**FAT32 strategy:**
- Parses BPB: `bytesPerSector`, `sectorsPerCluster`, `reservedSectors`, `numFATs`, `fatSize32`, `rootCluster`
- Loads the FAT table (first copy, capped to device size)
- Recursive directory walk from `rootCluster` following cluster chains
- Live files: `fromInode` candidate + sectors marked `.candidate`
- Deleted entries (`name[0] == 0xE5`): `fromInode` candidate, sectors NOT marked (deep scan can corroborate)
- Skips LFN (attr=0x0F), volume labels (attr & 0x08), `.` and `..` entries
- File type from 3-char extension; falls back to `SignatureScanner` magic scan for unknowns

**exFAT strategy:**
- Parses exFAT VBR: `bytesPerSectorShift`, `sectorsPerClusterShift`, `fatOffset`, `heapOffset`, `rootDirCluster`
- Directory entry sets: primary (0x85/0x05) + stream extension (0xC0/0x40) + name extensions (0xC1/0x41)
- Active (bit-7=1) and deleted (bit-7=0) entries both captured
- UTF-16LE filename assembled from name extensions (up to 15 chars each)

**Safeguards:**
- Cycle detection via `Set<UInt32>` of visited clusters
- `maxClusters = 8192` cap per chain (corrupt FAT guard)

### `FATError` enum

| Case | Description |
|------|-------------|
| `unreadableBootSector` | Sector 0 returned nil |
| `notFAT(oemName:)` | OEM name doesn't match FAT32 or exFAT |
| `unsupportedVariant(String)` | FAT12/FAT16 detected (not implemented) |

---

## 10. FileExtractor

**File:** `FileExtractor.swift`
**Purpose:** Reads raw sectors from a `DiskDevice` and writes recovered files to an output directory. Bad sectors are zero-padded rather than aborting extraction.

### Init

```swift
let extractor = FileExtractor(device: device, chunkSize: 64)
// chunkSize: sectors per pread call (default 64 = 32 KB)
```

### Callbacks

| Typedef | Signature | Description |
|---------|-----------|-------------|
| `FileProgressCallback` | `(written: UInt64, total: UInt64) -> Void` | Bytes written so far + total expected |
| `BatchProgressCallback` | `(completed: Int, total: Int, latest: ExtractionResult?) -> Void` | Per-file completion notification |

### Methods

#### `extract(_:to:onProgress:) throws -> ExtractionResult`
Extract a single `FileCandidate` to `outputDirectory`.
- Filename: `candidate.suggestedFileName`; collisions → `name_1.ext`, `name_2.ext`, …
- Output truncated to `candidate.estimatedSize` to strip sector-alignment padding
- **Throws:** `ExtractionError.cannotCreateFile` if output file cannot be created
- Never throws for source device I/O errors — those become `.partial` status

#### `extractAll(_:to:onProgress:) throws -> [ExtractionResult]`
Batch extraction. Creates `outputDirectory` (including intermediaries) if needed. Continues extracting remaining files if one fails — returns a result for every input candidate.
- **Throws:** only if `outputDirectory` cannot be created

---

## 11. FileTree

**File:** `FileTree.swift`
**Purpose:** Reconstructs a folder hierarchy from a flat `[FileCandidate]` list. Deep-scan candidates without paths are grouped under a synthetic `(Recovered Files)` folder.

### `NodeTag` enum
`String`, `Codable`.

| Case | Meaning |
|------|---------|
| `.normal` | Ordinary user file/folder |
| `.system` | OS internals (Spotlight, .fseventsd, etc.) — UI hides by default |
| `.trash` | Was inside `.Trashes` / `Trash` / `.Trash` |
| `.recycleBin` | Was inside `$RECYCLE.BIN` / `RECYCLER` |

Tags propagate: all descendants of a tagged folder inherit the parent's tag.

### `FileTreeNode` class
`Codable`. Represents one node (folder or file leaf) in the tree.

| Property | Type | Description |
|----------|------|-------------|
| `name` | `String` | Last path component |
| `path` | `String` | Absolute path from volume root |
| `isFolder` | `Bool` | True for directory nodes |
| `tag` | `NodeTag` | Semantic classification |
| `file` | `FileCandidate?` | Non-nil for file leaves |
| `children` | `[FileTreeNode]` | Direct children (empty for file leaves) |
| `fileCount` | `Int` | Recursive count of file leaves under this node |
| `breadcrumbs` | `[String]` | Path split for breadcrumb UI, e.g. `["Documents", "Work"]` |

### `FileTree` struct
`Codable`. Top-level container returned by `FileTree.build(from:)`.

| Property | Type | Description |
|----------|------|-------------|
| `root` | `FileTreeNode` | The root folder node |
| `totalFiles` | `Int` | Total file leaves across the whole tree |
| `trashedFiles` | `[FileCandidate]` | Files tagged `.trash` |
| `systemFiles` | `[FileCandidate]` | Files tagged `.system` |
| `unpathedFiles` | `[FileCandidate]` | Deep-scan files with no original path |

#### `FileTree.build(from:) -> FileTree`
Constructs the full tree from a flat array of candidates. Groups deep-scan files without paths under `(Recovered Files)`.

---

## 12. FileCategory

**File:** `FileCategory.swift`
**Purpose:** Groups file types into user-friendly categories (Pictures, Videos, etc.) and provides SF Symbol names and human-readable kind labels.

### `FileCategory` enum
`String`, `Codable`, `CaseIterable`.

| Case | SF Symbol | Description |
|------|-----------|-------------|
| `.pictures` | `photo` | JPEG, PNG, GIF, TIFF, BMP, HEIC, WebP, RAW |
| `.videos` | `film` | MP4, MOV, AVI, MKV |
| `.audio` | `waveform` | MP3, AAC, FLAC, WAV, AIFF |
| `.documents` | `doc.text` | PDF, ZIP, DOCX, XLSX, PPTX |
| `.databases` | `cylinder` | SQLite, plist |
| `.others` | `questionmark.folder` | Unknown |

### `RecoveredFileType` extensions
- `category: FileCategory` — maps every `RecoveredFileType` to its category
- `kindLabel: String` — human-readable e.g. `"JPEG image"`, `"MPEG-4 movie"`, `"SQLite database"`

### `FileSubGroup` struct
Candidates sharing the same `(category, fileType)` pair.

| Property | Type |
|----------|------|
| `fileType` | `RecoveredFileType` |
| `category` | `FileCategory` |
| `count` | `Int` |
| `totalSize` | `UInt64` |
| `candidates` | `[FileCandidate]` |

### `FileCategoryGroup` struct
All sub-groups for one `FileCategory`.

| Property | Type |
|----------|------|
| `category` | `FileCategory` |
| `subGroups` | `[FileSubGroup]` |
| `count` | `Int` |
| `totalSize` | `UInt64` |
| `candidates` | `[FileCandidate]` (all, across sub-groups) |

### `CategorySummary` struct
Complete Type View data source built from a `[FileCandidate]` list.

| Property | Type | Description |
|----------|------|-------------|
| `groups` | `[FileCategoryGroup]` | All groups, sorted by count descending |
| `trashed` | `[FileCandidate]` | Quick-access trash bucket |
| `totalFiles` | `Int` | |
| `totalSize` | `UInt64` | |

#### `CategorySummary.build(from:trashed:) -> CategorySummary`
Build the complete summary. `trashed` is typically `FileTree.trashedFiles`.

#### `CategorySummary.group(for:) -> FileCategoryGroup?`
Look up a category group by category value.

---

## 13. CandidateQuery & CandidateIndex

**File:** `CandidateQuery.swift`
**Purpose:** Composable filter + sort specification applied by `CandidateIndex`. Powers the search bar, filter chips, and sort order picker in the results UI.

### `SortOrder` enum
`String`, `Codable`, `CaseIterable`, `Equatable`.
- `.name` — alphabetical by `suggestedFileName`
- `.date` — by `modificationDate` (nil dates always sort to the end)
- `.size` — by `estimatedSize`
- `.recoverability` — by score (default, highest first)

### `CandidateQuery` struct
All filter fields are optional; `nil` = no constraint. All active constraints are AND-ed.

| Property | Type | Default | Filter behaviour |
|----------|------|---------|-----------------|
| `nameContains` | `String?` | nil | Case-insensitive substring of `suggestedFileName` |
| `fileTypes` | `Set<RecoveredFileType>?` | nil | Exact match |
| `categories` | `Set<FileCategory>?` | nil | Matches `fileType.category` |
| `dateRange` | `ClosedRange<Date>?` | nil | Candidates without a date are excluded when active |
| `sizeRange` | `ClosedRange<UInt64>?` | nil | `estimatedSize` in range |
| `minScore` | `RecoverabilityScore?` | nil | `recoverability >= minScore` |
| `source` | `ScanSource?` | nil | Quick-scan or deep-scan only |
| `sortBy` | `SortOrder` | `.recoverability` | |
| `ascending` | `Bool` | `false` | Ascending = low first |

- `CandidateQuery.all` — empty query, returns everything sorted by recoverability descending

### `CandidateIndex` struct

#### `init(candidates:)` / `init(result:)`
Wraps a flat candidate array. Build once, search many times.

#### `search(query:) -> [FileCandidate]`
Apply query and return filtered + sorted results.

#### `search(name:) -> [FileCandidate]`
Convenience: name substring search, sorted by recoverability.

#### `search(type:) -> [FileCandidate]`
Convenience: single file type, sorted by recoverability.

#### `search(category:) -> [FileCandidate]`
Convenience: all files in a category, sorted by recoverability.

#### `count(for type:) -> Int`
Total candidates of a given `RecoveredFileType` (unfiltered).

#### `count(for category:) -> Int`
Total candidates in a given `FileCategory` (unfiltered).

---

## 14. PreviewProvider

**File:** `PreviewProvider.swift`
**Purpose:** Reads the first few KB of a candidate's sector range and produces a `PreviewData` appropriate for the file type. Uses CoreGraphics/ImageIO for image thumbnails and AVFoundation for video first-frame extraction.

### `PreviewData` enum

| Case | When returned | UI action |
|------|--------------|-----------|
| `.image(Data)` | Full image fits in `maxPreviewBytes` | Pass to `NSImage(data:)` |
| `.thumbnail(Data)` | PNG-encoded thumbnail (square, `thumbnailSize` px) | Display inline |
| `.text(String)` | plist or small readable text | Show in text view |
| `.hex(Data)` | Fallback for unrecognised types | Show hex viewer |
| `.unavailable(reason:)` | No sector info, read error, etc. | Show placeholder |

Computed:
- `isAvailable: Bool` — false only for `.unavailable`
- `summary: String` — short description ≤ 120 chars for CLI / list views

### `PreviewProvider` class

#### `init(device:maxPreviewBytes:thumbnailSize:)`
```swift
let provider = PreviewProvider(
    device:          device,
    maxPreviewBytes: 512 * 1024,   // default 512 KB
    thumbnailSize:   256           // default 256 × 256 px
)
```

#### `preview(for:) -> PreviewData`
Generate a preview for a candidate. Never throws — returns `.unavailable(reason:)` on any error.

**Dispatch logic per type:**
| Types | Strategy |
|-------|---------|
| JPEG, PNG, GIF, BMP, TIFF, WebP, HEIC, RAW | `CGImageSource` thumbnail |
| MP4, MOV, AVI, MKV | `AVAssetImageGenerator` first frame (temp-file strategy) |
| MP3, AAC, FLAC, WAV, AIFF | Hex dump of first bytes |
| PDF | ASCII text of first `maxPreviewBytes` |
| plist | UTF-8 text |
| SQLite | Header text + hex |
| ZIP, DOCX, XLSX, PPTX, unknown | Hex dump |

#### `rawBytes(for:) -> Data?`
Exposes the capped raw sector buffer for custom rendering (e.g. a full hex viewer).

#### Configuration properties
- `maxPreviewBytes: Int` — writable; caps all sector reads (default 512 KB)
- `thumbnailSize: Int` — writable; pixel dimension of generated thumbnails (default 256)

---

## 15. Error Types

All errors conform to `LocalizedError` and provide human-readable `errorDescription` strings.

| Error type | File | Cases |
|------------|------|-------|
| `DiskError` | `DiskDevice.swift` | `openFailed`, `statFailed`, `ioctlFailed`, `readFailed`, `outOfBounds` |
| `SectorMapError` | `SectorMap.swift` | `sectorCountMismatch(expected:got:)` |
| `HFSError` | `HFSParser.swift` | `unreadableVolumeHeader`, `notHFSPlus`, `unreadableCatalog`, `catalogParseError` |
| `APFSError` | `APFSParser.swift` | `unreadableContainerSuperblock`, `notAPFS`, `omapNotFound`, `volumeUnreadable` |
| `FATError` | `FATParser.swift` | `unreadableBootSector`, `notFAT(oemName:)`, `unsupportedVariant(_:)` |
| `ExtractionError` | `FileExtractor.swift` | `cannotCreateFile(path:)` |
| `EnumeratorError` | `VolumeEnumerator.swift` | `sessionCreationFailed`, `ioRegistryFailed(kr:)` |

---

## Integration Patterns

### Pattern 1 — Full scan from SwiftUI
```swift
@Observable class ScanViewModel {
    var progress = ScanProgress(...)
    var result: ScanResult?

    private var engine = RecoveryEngine()
    private var scanTask: Task<ScanResult, Error>?

    func startScan(path: String) {
        let (stream, task) = engine.scanStream(devicePath: path)
        self.scanTask = task
        Task { @MainActor in
            for await p in stream { self.progress = p }
            self.result = try await task.value
        }
    }

    func cancel() { scanTask?.cancel() }
    func pause()  { engine.requestPause() }
}
```

### Pattern 2 — Resume from checkpoint
```swift
let (stream, task) = engine.resumeStream(checkpointURL: result.checkpointURL!)
for await p in stream { ... }
let finalResult = try await task.value
```

### Pattern 3 — Search & filter results
```swift
let index = CandidateIndex(result: scanResult)
let photos = index.search(query: CandidateQuery(
    categories: [.pictures],
    minScore:   .medium,
    sortBy:     .size,
    ascending:  false
))
```

### Pattern 4 — Recover selected files
```swift
let extractor = FileExtractor(device: try DiskDevice.open(path: result.devicePath))
let outputDir = URL(fileURLWithPath: "~/Desktop/Recovered")
let results = try extractor.extractAll(selectedCandidates, to: outputDir) { done, total, latest in
    print("\(done)/\(total): \(latest?.status.rawValue ?? "")")
}
```

### Pattern 5 — Preview before recovering
```swift
let provider = PreviewProvider(device: device)
for candidate in topCandidates {
    switch provider.preview(for: candidate) {
    case .thumbnail(let png):  showImage(png)
    case .text(let str):       showText(str)
    case .unavailable(let r):  showPlaceholder(r)
    default: break
    }
}
```

### Pattern 6 — Build Type View (sidebar)
```swift
let summary = CategorySummary.build(
    from:    scanResult.candidates,
    trashed: FileTree.build(from: scanResult.candidates).trashedFiles
)
for group in summary.groups {
    print("\(group.category.rawValue): \(group.count) files, \(group.totalSize) bytes")
}
```
