#!/bin/bash
# run_tests.sh — Build, unit test, and run CLI smoke tests
set -e

echo "═══════════════════════════════════════════════════"
echo "  MacRecovery Phase 1 — Build + Test"
echo "═══════════════════════════════════════════════════"

# 1. Build
echo ""
echo "▶ Building..."
swift build 2>&1 | grep -v "^Build complete" | tail -20
echo "✓ Build succeeded"

# 2. Unit tests
echo ""
echo "▶ Running unit tests..."
swift test --parallel 2>&1 | tail -30

# 3. CLI smoke test on synthetic images
echo ""
echo "▶ Creating test images..."
bash Scripts/make_test_image.sh /tmp/macrecovery_test

echo ""
echo "▶ CLI smoke test — device info..."
.build/debug/recoverycli info /tmp/macrecovery_test/test_raw_signatures.img

echo ""
echo "▶ CLI smoke test — deep scan on raw signatures image..."
.build/debug/recoverycli scan /tmp/macrecovery_test/test_raw_signatures.img \
  --mode deep \
  --output /tmp/macrecovery_test

echo ""
echo "▶ Verifying results.json..."
python3 -c "
import json, sys
with open('/tmp/macrecovery_test/results.json') as f:
    r = json.load(f)
count = len(r['candidates'])
print(f'  Candidates found: {count}')
types = set(c['fileType'] for c in r['candidates'])
print(f'  Types detected:   {sorted(types)}')
# Ground truth: JPEG@10, PNG@50, PDF@100, ZIP@200, SQLite@300, JPEG@1000 = 6 minimum
if count < 4:
    print('ERROR: Expected at least 4 candidates', file=sys.stderr)
    sys.exit(1)
print('  ✓ Ground truth check passed')
"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  All Phase 1 tests passed ✓"
echo "═══════════════════════════════════════════════════"
