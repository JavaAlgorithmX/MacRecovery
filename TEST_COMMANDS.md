# MacRecovery — CLI Test Commands Guide

## Build

```bash
cd /Users/madhavsharma/Developer/MacRecovery
swift build -c release 2>&1
```

Binary output:
```
.build/release/recoverycli
```

---

## List Drives

```bash
# User-facing view — shows external drives with ★ recommendation
.build/release/recoverycli list

# Raw view — every partition the system exposes
.build/release/recoverycli list --all
```

---

## Inspect a Drive

```bash
# Prints size, sector count, sector size, estimated deep scan time
.build/release/recoverycli info /dev/disk2s1
```

Replace `disk2s1` with whatever `list --all` shows for your target drive.

---

## Scan

### Quick scan (filesystem B-tree walk — fast, supports HFS+/APFS/FAT32/exFAT)
```bash
.build/release/recoverycli scan /dev/disk2s1 --mode quick --output /tmp/results
```

### Deep scan (raw file carving — works on any filesystem or wiped/reformatted drive)
```bash
.build/release/recoverycli scan /dev/disk2s1 --mode deep --output /tmp/results
```

### Both phases (recommended for external drives)
```bash
.build/release/recoverycli scan /dev/disk2s1 --mode both --output /tmp/results
```

### Limit to specific file types (faster — skips unneeded signatures)
```bash
.build/release/recoverycli scan /dev/disk2s1 --mode deep \
    --types jpg,png,pdf,mp4 \
    --output /tmp/results
```

---

## Test with a Disk Image (safe — no real drive needed)

```bash
# 1. Create a 100 MB HFS+ test image
hdiutil create -size 100m -fs HFS+ -volname TestVol /tmp/test.dmg

# 2. Attach it (note the /dev/diskN shown in output)
hdiutil attach /tmp/test.dmg

# 3. Copy some files onto it
cp ~/Desktop/*.jpg /Volumes/TestVol/
cp ~/Desktop/*.pdf /Volumes/TestVol/

# 4. Detach the image
hdiutil detach /Volumes/TestVol

# 5. Scan the image file directly (quick + deep)
.build/release/recoverycli scan /tmp/test.dmg --mode both --output /tmp/results

# 6. Repeat with a FAT32 image to test the FAT parser
hdiutil create -size 100m -fs FAT32 -volname TestFAT /tmp/test_fat.dmg
hdiutil attach /tmp/test_fat.dmg
cp ~/Desktop/*.jpg /Volumes/TestFAT/
hdiutil detach /Volumes/TestFAT
.build/release/recoverycli scan /tmp/test_fat.dmg --mode both --output /tmp/results_fat
```

---

## Recover Files

```bash
# Extract all candidates with recoverability >= medium (default)
.build/release/recoverycli recover /tmp/results/results.json \
    --output /tmp/recovered \
    --min-score medium

# Only inode-backed files (highest confidence)
.build/release/recoverycli recover /tmp/results/results.json \
    --output /tmp/recovered \
    --min-score certain

# Everything including low-confidence carved files
.build/release/recoverycli recover /tmp/results/results.json \
    --output /tmp/recovered \
    --min-score low
```

---

## Preview Candidates

```bash
# Show first 20 candidates with hex/text previews
.build/release/recoverycli preview /tmp/results/results.json

# Show up to 50 candidates, JPEGs only
.build/release/recoverycli preview /tmp/results/results.json --limit 50 --type jpg

# Preview multiple types
.build/release/recoverycli preview /tmp/results/results.json --limit 100 --type jpg,png,pdf
```

---

## Full End-to-End Workflow (External Drive)

```bash
# 1. Build
cd /Users/madhavsharma/Developer/MacRecovery
swift build -c release

# 2. Find your external drive
.build/release/recoverycli list

# 3. Check device info
.build/release/recoverycli info /dev/disk2s1

# 4. Scan (both phases)
.build/release/recoverycli scan /dev/disk2s1 --mode both --output /tmp/results

# 5. Preview top results
.build/release/recoverycli preview /tmp/results/results.json --limit 20

# 6. Recover files (output must be on a DIFFERENT drive than the one being scanned)
.build/release/recoverycli recover /tmp/results/results.json \
    --output ~/Desktop/Recovered \
    --min-score medium
```

---

## Notes

- **Full Disk Access required for real drives**: System Settings → Privacy & Security →
  Full Disk Access → add Terminal (or the `recoverycli` binary). Without it you get
  `Permission denied` on `/dev/rdisk*`.

- **Output must be on a different volume**: Never point `--output` at the drive being
  scanned. The extractor refuses to write back to the source device.

- **results.json is reusable**: Scan once, recover or preview multiple times without
  re-scanning. Pass the same `results.json` to both `recover` and `preview`.

- **Interrupted scans**: If a scan is killed mid-way, the partial `results.json` is
  still valid. `recover` will extract whatever was found up to that point.

- **Sector size**: The CLI defaults to 512-byte sectors. 4K-native drives are handled
  automatically via `lseek(SEEK_END)` — no extra flags needed.

- **File type tokens for --types / --type**:
  `jpg`, `png`, `gif`, `tiff`, `bmp`, `heic`, `webp`,
  `mp4`, `mov`, `avi`, `mkv`,
  `mp3`, `aac`, `flac`, `wav`, `aiff`,
  `pdf`, `zip`, `docx`, `xlsx`, `pptx`,
  `sqlite`, `plist`
