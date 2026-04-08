#!/bin/bash
# make_test_image.sh
# Creates controlled disk images with known files, then deletes them.
# Run this before `swift test` or `recoverycli scan`.
#
# Requires: hdiutil (built into macOS), standard coreutils

set -e

OUT_DIR="${1:-/tmp/macrecovery_test}"
mkdir -p "$OUT_DIR"

echo "Creating test disk images in $OUT_DIR"
echo ""

# ────────────────────────────────────────────────────────────────
# Image 1: HFS+ with deleted files (quick scan target)
# ────────────────────────────────────────────────────────────────
HFSIMG="$OUT_DIR/test_hfsplus.dmg"

if [ -f "$HFSIMG" ]; then
  echo "⏭  $HFSIMG already exists — skipping"
else
  echo "→ Creating HFS+ test image..."
  hdiutil create -size 20m -fs HFS+ -volname "TestHFSPlus" "$HFSIMG" -quiet

  hdiutil attach "$HFSIMG" -mountpoint /Volumes/TestHFSPlus -quiet

  # Write test files with known content
  echo "Hello, recovery!" > /Volumes/TestHFSPlus/test_text.txt
  cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns \
     /Volumes/TestHFSPlus/test_icon.icns 2>/dev/null || \
     dd if=/dev/urandom bs=1024 count=10 > /Volumes/TestHFSPlus/test_random.bin 2>/dev/null

  # Create a fake JPEG (just the magic bytes + some data)
  python3 -c "
import struct
data = bytes([0xFF,0xD8,0xFF,0xE0,0x00,0x10,0x4A,0x46,0x49,0x46,0x00,0x01]) + b'X'*2000 + bytes([0xFF,0xD9])
open('/Volumes/TestHFSPlus/photo.jpg', 'wb').write(data)
"

  # Create a fake PDF
  python3 -c "
data = b'%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF'
open('/Volumes/TestHFSPlus/document.pdf', 'wb').write(data)
"

  # Create a fake PNG
  python3 -c "
import struct, zlib
def chunk(t, d):
    c = zlib.crc32(t+d) & 0xffffffff
    return struct.pack('>I',len(d)) + t + d + struct.pack('>I',c)
sig = b'\x89PNG\r\n\x1a\n'
ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB',1,1,8,2,0,0,0))
idat = chunk(b'IDAT', zlib.compress(b'\x00\xff\xff\xff'))
iend = chunk(b'IEND', b'')
open('/Volumes/TestHFSPlus/image.png','wb').write(sig+ihdr+idat+iend)
"

  ls -la /Volumes/TestHFSPlus/
  echo "→ Files written. Now deleting them..."

  rm /Volumes/TestHFSPlus/test_text.txt
  rm /Volumes/TestHFSPlus/photo.jpg
  rm /Volumes/TestHFSPlus/document.pdf
  rm /Volumes/TestHFSPlus/image.png

  sync
  hdiutil detach /Volumes/TestHFSPlus -quiet
  echo "✓ HFS+ image ready: $HFSIMG"
  echo "  Ground truth: test_text.txt, photo.jpg, document.pdf, image.png"
fi

echo ""

# ────────────────────────────────────────────────────────────────
# Image 2: Raw sectors with injected file signatures (deep scan target)
# Used for testing SignatureScanner without any file system overhead.
# ────────────────────────────────────────────────────────────────
RAWIMG="$OUT_DIR/test_raw_signatures.img"

if [ -f "$RAWIMG" ]; then
  echo "⏭  $RAWIMG already exists — skipping"
else
  echo "→ Creating raw signature test image..."
  python3 - <<'PYEOF'
import os, struct, sys

SECTOR = 512
TOTAL  = 4096   # 4096 sectors = 2 MB

data = bytearray(TOTAL * SECTOR)

def write_at(offset, payload):
    data[offset:offset+len(payload)] = payload

# Sector 10: JPEG header
write_at(10*SECTOR, bytes([0xFF,0xD8,0xFF,0xE0,0x00,0x10,0x4A,0x46,0x49,0x46,0x00,0x01]))
write_at(10*SECTOR + 300, bytes([0xFF,0xD9]))  # JPEG footer

# Sector 50: PNG header + valid footer
png_sig = bytes([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A])
png_end = bytes([0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82])
write_at(50*SECTOR, png_sig)
write_at(51*SECTOR - len(png_end), png_end)

# Sector 100: PDF
write_at(100*SECTOR, b'%PDF-1.4\n')
write_at(101*SECTOR - 7, b'%%EOF\n\x0a')

# Sector 200: ZIP/DOCX
write_at(200*SECTOR, bytes([0x50,0x4B,0x03,0x04]))

# Sector 300: SQLite
write_at(300*SECTOR, b'SQLite format 3\x00')

# Sector 1000: another JPEG (tests multiple detections)
write_at(1000*SECTOR, bytes([0xFF,0xD8,0xFF,0xE1]))

out = os.path.join(os.environ.get('OUT_DIR','/tmp/macrecovery_test'), 'test_raw_signatures.img')
with open(out, 'wb') as f:
    f.write(data)
print(f"Written {len(data)} bytes to {out}")
print("Ground truth sectors: JPEG@10, PNG@50, PDF@100, ZIP@200, SQLite@300, JPEG@1000")
PYEOF
fi

echo ""

# ────────────────────────────────────────────────────────────────
# Image 3: Formatted volume (simulate "someone reformatted my drive")
# Original HFS+ content written, then reformatted as HFS+.
# Deep scan should still find the carved files from the old filesystem.
# ────────────────────────────────────────────────────────────────
FMTIMG="$OUT_DIR/test_reformatted.dmg"

if [ -f "$FMTIMG" ]; then
  echo "⏭  $FMTIMG already exists — skipping"
else
  echo "→ Creating reformatted volume test image..."
  hdiutil create -size 30m -fs HFS+ -volname "BeforeFormat" "$FMTIMG" -quiet
  hdiutil attach "$FMTIMG" -mountpoint /Volumes/BeforeFormat -quiet

  # Write recognisable content
  python3 -c "
data = bytes([0xFF,0xD8,0xFF,0xE0,0x00,0x10]) + b'A'*5000 + bytes([0xFF,0xD9])
open('/Volumes/BeforeFormat/important.jpg','wb').write(data)
open('/Volumes/BeforeFormat/notes.txt','w').write('Secret notes\n' * 100)
"
  sync
  hdiutil detach /Volumes/BeforeFormat -quiet

  # Reformat in-place (overwrites FS metadata, leaves data sectors intact)
  hdiutil attach "$FMTIMG" -nomount -quiet
  DISK=$(hdiutil info | grep BeforeFormat | awk '{print $1}' | head -1 || echo "")
  if [ -n "$DISK" ]; then
    newfs_hfs -v "AfterFormat" "$DISK" 2>/dev/null || true
    hdiutil detach "$DISK" -quiet 2>/dev/null || true
  fi

  echo "✓ Reformatted image ready: $FMTIMG"
  echo "  Ground truth: important.jpg should survive deep scan"
fi

echo ""
echo "────────────────────────────────────────────────────"
echo "Test images ready. Run scans with:"
echo ""
echo "  .build/debug/recoverycli scan $RAWIMG --mode deep"
echo "  .build/debug/recoverycli scan $HFSIMG --mode quick"
echo "  .build/debug/recoverycli scan $FMTIMG --mode deep"
echo ""
echo "Or run unit tests:"
echo "  swift test"
echo "────────────────────────────────────────────────────"
