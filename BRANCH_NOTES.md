# Branch: backend_bug_fixed

## What this branch fixes (backend bugs resolved)

### 1. HFS+ Catalog Fork Offset (HFSParser.swift)
- Fixed wrong byte offsets for reading the HFS+ Volume Header catalog fork.
- `catalogForkOffset` corrected: `VH + 248` → `VH + 272`
- `startBlock` field offset corrected: `+20` → `+16` (was reading blockCount instead)

### 2. APFS Unknown Block Address (APFSParser.swift)
- `parseInode()` always returned `blockAddr = 0` (extent trees not walked).
- Fixed: candidates with `blockAddr == 0` now get `sectorCount = 0` so the extractor skips them instead of reading garbage from sector 0.

### 3. Sector 0 Claimed by Ghost Candidates (RecoveryEngine.swift)
- `claimedRanges` filter now excludes candidates with `startSector == 0` so carver doesn't skip sector 0 thinking it's taken.

### 4. SignatureScanner Footer Search (SignatureScanner.swift)
- On a bad sector during footer search, code was using `continue` (skip and keep searching).
- Fixed to `return` (stop and use what was found so far), preventing runaway sector reads.

### 5. Video Preview Temp File Extension (PreviewProvider.swift)
- Temp file for video thumbnail was always written as `.dat`, causing AVFoundation to fail.
- Fixed to use the actual file extension (`.mp4`, `.mov`, etc.).

### 6. Data Race on Cancel/Pause Flags (RecoveryEngine.swift)
- `_cancelRequested` and `_pauseRequested` were plain `Bool` vars accessed from `Task.detached` and `MainActor` simultaneously.
- Fixed with a `DispatchQueue` (flagQueue) wrapping both flags.

### 7. SectorMap.progress() O(N) Scan (SectorMap.swift)
- `progress()` was iterating all sectors on every call — O(N) per tick.
- Fixed with running counters (`_scannedCount`, `_badCount`, `_candidateCount`) updated on every state change — O(1) per tick.

### 8. O(n²) Candidate Deduplication (RecoveryEngine.swift)
- `deduplicateCandidates` was using `kept.contains { }` — O(n²) on large drives.
- Replaced with an O(n) `maxEnd: [RecoverabilityScore: UInt64]` lookup table.

### 9. DiskDevice Size Detection (DiskDevice.swift)
- USB/exFAT drives (e.g. PS5 external storage) fail both `lseek(SEEK_END)` and DK ioctls.
- Added Strategy 3: DiskArbitration `DADiskCopyDescription` fallback — same API used by `list` command, reliably returns media size.

### 10. Device Node Always Opened as Raw (DiskDevice.swift)
- `/dev/disk*` block nodes don't support DK ioctls or unbuffered I/O.
- All `/dev/disk*` paths are now transparently converted to `/dev/rdisk*` on open.

### 11. Results Directory Creation (RecoveryCLI/main.swift)
- `saveResult()` failed with "file doesn't exist" when output directory didn't exist.
- Fixed with `FileManager.default.createDirectory(at:withIntermediateDirectories:)` before writing.

### 12. GB Display (RecoveryCLI/main.swift)
- Device size was displayed in GiB (÷ 1,073,741,824) instead of GB (÷ 1,000,000,000).
- Fixed divisor to match what Disk Utility and the OS display.

### 13. Single-File Recovery (RecoveryCLI/main.swift)
- Added `--index N` flag to `recover` command.
- Recovers exactly the Nth file shown by `preview`, without extracting everything.

---

## What the app can do (current capabilities)

### CLI (`recoverycli`)
| Command | Description |
|---------|-------------|
| `list` | List user-facing external/internal drives with size, FS, mount point |
| `list --all` | Show every raw partition the system exposes |
| `info <path>` | Print device size, sector count, estimated scan time |
| `scan <path> --mode quick` | HFS+ / APFS / FAT32 / exFAT B-tree walk — fast, finds named files |
| `scan <path> --mode deep` | Raw signature carving — works on wiped/reformatted drives |
| `scan <path> --mode both` | Both phases (recommended) |
| `scan --types jpg,mp4,pdf` | Limit to specific file types |
| `preview <results.json>` | Show hex/text previews with recoverability scores |
| `recover <results.json>` | Extract all files meeting a minimum score |
| `recover --index N` | Extract a single file by position shown in `preview` |

### GUI (`MacRecoveryApp`)
- Drive picker with visual cards (external, internal, image files)
- Scan options sheet (mode, file types)
- Live scan progress with speed, ETA, candidate count
- Results view: sidebar by type/path, grid/list toggle, search, filters
- Preview panel: image thumbnail, hex dump, metadata
- Recovery queue: manually select files to recover
- Recovery sheet: pick output volume or folder, progress, done state

### Supported file types for carving
`jpg`, `png`, `gif`, `tiff`, `bmp`, `heic`, `webp`,
`mp4`, `mov`, `avi`, `mkv`,
`mp3`, `aac`, `flac`, `wav`, `aiff`,
`pdf`, `zip`, `docx`, `xlsx`, `pptx`,
`sqlite`, `plist`

### Supported filesystems (quick scan)
- HFS+ (read catalog B-tree, walk extents)
- APFS (container/volume superblock, omap, inode tree)
- FAT32 / exFAT (directory chain walk)

---

## Known UI bugs (not yet fixed — frontend)

### Bug 1 — Stale drive selection after "New Scan" (VISUAL)
**File:** `MacRecoveryApp/ScanViewModel.swift` — `resetToStart()` line 179  
`selectedVolume` is not cleared when returning to drive picker. The previously scanned drive keeps its blue highlight. Also, `device` (open file descriptor) is never nilled out — old FD stays open until the next scan overwrites it.  
**Fix needed:** Add `selectedVolume = nil` and `device = nil; previewProvider = nil` to `resetToStart()`.

### Bug 2 — Silent extraction failure (NO ERROR SHOWN)
**File:** `MacRecoveryApp/RecoverySheet.swift` — `startExtraction()` line 465  
`guard let device = vm.device else { return }` — if `DiskDevice.open()` failed silently (line 143 of ScanViewModel), the Save button does nothing with no error message shown to the user.  
**Fix needed:** Show an alert when `vm.device` is nil on extraction start.

### Bug 3 — Recovery to source drive not blocked (DATA RISK)
**File:** `MacRecoveryApp/RecoverySheet.swift` — `localVolumeList` line 149  
Source drive shows a warning triangle but Save button stays fully enabled. Writing recovered files back to the source drive risks overwriting data still being recovered.  
**Fix needed:** Disable the Save button when `selectedVolumeID == sourceID`, or add a confirmation dialog.

### Bug 4 — Scan mode and type filters not reset between scans (VISUAL)
**File:** `MacRecoveryApp/ScanViewModel.swift` — `resetToStart()` line 179  
`scanMode` and `targetTypes` are never reset. If user ran a deep scan filtered to `jpg`, the next scan opens the options sheet pre-set to deep + jpg instead of the defaults.  
**Fix needed:** Reset `scanMode = .both` and `targetTypes = []` in `resetToStart()`.
