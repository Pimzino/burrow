#!/bin/zsh
# End-to-end check of a built DMG's Finder window: mounts the image the way a user does, opens its window,
# and verifies that
#   1. the window opens with the whole 660 x 420 pt composition visible (frame = content + title bar), and
#   2. the icon labels are readable (Finder draws them black on a picture background, so they need a light backing), and
#   3. the background still fills the window when it is made much larger (Finder paints white past the
#      picture, so the artwork must be big enough).
# Captures of both states are written to build/dmg-e2e/ (open.png, resized.png) for review.
#
#   scripts/dmg-e2e.sh [path/to/Burrow-x.y.z.dmg]     (default: the newest build/Burrow-*.dmg)
#
# Needs permission to control Finder (Automation) and to record the screen (for screencapture).
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-$(ls -t build/Burrow-*.dmg 2>/dev/null | head -1)}"
[[ -f "$DMG" ]] || { echo "error: no DMG found (run scripts/make-dmg.sh first)" >&2; exit 1; }
OUT="build/dmg-e2e"
rm -rf "$OUT"; mkdir -p "$OUT"

# Must match scripts/make-dmg.sh.
WIN_W=660; WIN_H=420; TITLEBAR_H=32

DEVICE=""
cleanup() { [[ -n "$DEVICE" ]] && hdiutil detach "$DEVICE" -force -quiet 2>/dev/null || true; }
trap cleanup EXIT

ATTACH=$(hdiutil attach "$DMG" -readonly -noverify -noautoopen)
DEVICE=$(echo "$ATTACH" | awk '$1 ~ /^\/dev\/disk[0-9]+$/ {print $1; exit}')
MOUNT=$(echo "$ATTACH" | awk -F'\t' '/Apple_HFS/ {print $NF; exit}')
DISK_NAME="$(basename "$MOUNT")"
echo "mounted $DMG at $MOUNT"

# Helpers: find the CGWindow id for a Finder window frame, and sample pixels of a capture.
cat > "$OUT/window-id.swift" <<'EOF'
import CoreGraphics
let want = CommandLine.arguments.dropFirst().map { Int($0)! }   // x y w h
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
// Finder's reported bounds can be a few points off the window server's frame right after a resize.
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Finder" && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let f = [b["X"], b["Y"], b["Width"], b["Height"]].map { Int($0 ?? -1000) }
    if zip(f, want).allSatisfy({ abs($0 - $1) <= 4 }) { print(w[kCGWindowNumber as String]!); break }
}
EOF
cat > "$OUT/main-display.swift" <<'EOF'
import CoreGraphics
let b = CGDisplayBounds(CGMainDisplayID())   // points; Finder's window coordinates start at its top-left
print(Int(b.width), Int(b.height))
EOF
cat > "$OUT/pixels.swift" <<'EOF'
// pixels.swift image.png x y [x y ...]   (pixel coordinates, top-left origin) -> "r g b" per point
import AppKit
let a = CommandLine.arguments
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
var i = 2
while i + 1 < a.count {
    let c = rep.colorAt(x: Int(a[i])!, y: Int(a[i + 1])!)!.usingColorSpace(.sRGB)!
    print(Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    i += 2
}
EOF

finder() { osascript -e "tell application \"Finder\"" -e "$1" -e "end tell"; }
bounds() { finder "get bounds of container window of disk \"$DISK_NAME\"" | tr -d ' '; }

capture() {   # capture <name>: screenshot the DMG window, print its pixel size
  local b; b=$(bounds); local l t r bt; IFS=, read l t r bt <<< "$b"
  local id; id=$(swift "$OUT/window-id.swift" "$l" "$t" "$((r - l))" "$((bt - t))")
  [[ -n "$id" ]] || { echo "error: could not find the Finder window ($b)" >&2; exit 1; }
  screencapture -x -o -l "$id" "$OUT/$1.png" 2>/dev/null || {
    echo "error: screencapture failed; allow this terminal to record the screen in System Settings › Privacy & Security › Screen Recording" >&2
    exit 1
  }
}

FAIL=0
check_dark() {   # check_dark <png> <label> x y ...: every sampled pixel must be dark (artwork, not Finder's white)
  # (zsh runs the last stage of a pipeline in this shell, so FAIL set inside the loop sticks)
  local png=$1 label=$2; shift 2
  swift "$OUT/pixels.swift" "$png" "$@" | while read r g b; do
    if (( r > 80 || g > 80 || b > 80 )); then echo "FAIL: $label: pixel ($r,$g,$b) is not background artwork"; FAIL=1; fi
  done
}

# 1. Window as it opens.
finder "open disk \"$DISK_NAME\""
sleep 2
B=$(bounds); IFS=, read L T R BT <<< "$B"
FW=$((R - L)); FH=$((BT - T))
echo "opened: frame ${FW}x${FH} pt"
if (( FW != WIN_W || FH != WIN_H + TITLEBAR_H )); then
  echo "FAIL: expected a ${WIN_W}x$((WIN_H + TITLEBAR_H)) pt frame (${WIN_W}x${WIN_H} content), got ${FW}x${FH}"; FAIL=1
fi
capture open
PW=$(sips -g pixelWidth "$OUT/open.png" | awk '/pixelWidth/ {print $2}')
PH=$(sips -g pixelHeight "$OUT/open.png" | awk '/pixelHeight/ {print $2}')
S=$((PW / FW))   # backing scale
# The hint text's baseline sits at y = 392 pt of the content; the content's bottom corners must be artwork too.
# (Samples stay 24 px clear of the window's rounded corners.)
check_dark "$OUT/open.png" "open, content bottom corners" 24 $((PH - 24)) $((PW - 24)) $((PH - 24))
# Finder draws the icon labels in black on a picture background, so the artwork must be light right beside
# each label's text (label middle at y = 293.5 pt; "Burrow" ink spans x 149...191, "Applications" 453...526).
TB=$((TITLEBAR_H * S))
swift "$OUT/pixels.swift" "$OUT/open.png" \
  $((145 * S)) $((TB + 293 * S))  $((195 * S)) $((TB + 293 * S))  $((449 * S)) $((TB + 293 * S))  $((530 * S)) $((TB + 293 * S)) |
  while read r g b; do
    if (( r < 180 || g < 180 || b < 180 )); then echo "FAIL: label backing ($r,$g,$b) is too dark for Finder's black label text"; FAIL=1; fi
  done
echo "captured $OUT/open.png (${PW}x${PH} px, @${S}x)"

# 2. Window made much larger: nearly the whole main display. (Finder's desktop bounds span every display.)
read SW SH <<< "$(swift "$OUT/main-display.swift")"
NL=20; NT=60; NR=$((SW - 20)); NB=$((SH - 20))
finder "set bounds of container window of disk \"$DISK_NAME\" to {$NL, $NT, $NR, $NB}" >/dev/null
sleep 2
B=$(bounds); IFS=, read L T R BT <<< "$B"
echo "resized: frame $((R - L))x$((BT - T)) pt"
capture resized
PW=$(sips -g pixelWidth "$OUT/resized.png" | awk '/pixelWidth/ {print $2}')
PH=$(sips -g pixelHeight "$OUT/resized.png" | awk '/pixelHeight/ {print $2}')
check_dark "$OUT/resized.png" "resized, far edges" \
  $((PW - 24)) $((TB + 24))  $((PW - 24)) $((PH / 2))  $((PW - 24)) $((PH - 24))  $((PW / 2)) $((PH - 24))  24 $((PH - 24))
echo "captured $OUT/resized.png (${PW}x${PH} px)"

finder "close container window of disk \"$DISK_NAME\""
rm -f "$OUT"/*.swift
if (( FAIL )); then echo "DMG window check FAILED (captures in $OUT)"; exit 1; fi
echo "DMG window check passed (captures in $OUT)"
