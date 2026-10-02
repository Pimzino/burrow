#!/bin/sh
# Regenerates the whole Burrow brand pack into art/brand/out/
# (Blender 5.2 + Cycles on Metal for the icon, numpy compositing, CoreText for type, iconutil for the .icns).
#   art/brand/build.sh                  full render
#   BRAND_REUSE=1 art/brand/build.sh    reuse the cached renders in .work/ and recompose only
set -eu
cd "$(dirname "$0")"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
OUT="$(pwd)/out"
LOG="$(pwd)/.work/build.log"
mkdir -p .work
rm -rf "$OUT/AppIcon.iconset" "$OUT/presentation.png"
"$BLENDER" -b --factory-startup -P build.py -- "$OUT" > "$LOG" 2>&1 || true
grep -E "^(wrote|DONE)" "$LOG" || true
if ! grep -q "^DONE" "$LOG"; then
  grep -E -A20 "Traceback|Error" "$LOG" >&2 || tail -40 "$LOG" >&2
  echo "error: build.py failed (log: $LOG)" >&2
  exit 1
fi
iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
echo "wrote AppIcon.icns"
