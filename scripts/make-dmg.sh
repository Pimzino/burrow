#!/bin/zsh
# Packages build/Burrow.app into a compressed, signed disk image: build/Burrow-<version>.dmg
# Uses only tools that ship with macOS / Xcode (hdiutil, tiffutil, osascript, codesign).
#
#   scripts/make-dmg.sh [version]
#
# version        defaults to CFBundleShortVersionString of Resources/Info.plist (a leading "v" is dropped)
# Environment:
#   BURROW_SKIP_BUILD=1       package the existing build/Burrow.app instead of running build-app.sh release
#   BURROW_SKIP_FINDER=1      skip the Finder window layout (the DMG still works, with Finder's default view)
#   MOLE_SIGN_IDENTITY        codesigning identity for the DMG (same rules as build-app.sh; "-" = ad-hoc)
#
# Artwork: art/brand/out/dmg-background.png (660x420) and dmg-background@2x.png (1320x840). If they are
# missing, a placeholder in the brand colours is rendered by scripts/make-dmg-background.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
VERSION="${VERSION#v}"
APP="build/Burrow.app"
VOLNAME="Burrow"
DMG="build/Burrow-$VERSION.dmg"
WORK="build/dmg-work"
STAGE="$WORK/stage"
RW="$WORK/Burrow-rw.dmg"

# Window geometry (points). Keep in sync with the artwork size.
WIN_W=660; WIN_H=420; ICON_SIZE=128
APP_X=170; APP_Y=210; APPS_X=490; APPS_Y=210

MOUNT=""; DEVICE=""
cleanup() {
  if [[ -n "$DEVICE" ]]; then hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. The app.
if [[ "${BURROW_SKIP_BUILD:-0}" != 1 ]]; then
  BURROW_VERSION="$VERSION" ./scripts/build-app.sh release
fi
[[ -d "$APP" ]] || { echo "error: $APP not found (run scripts/build-app.sh first)" >&2; exit 1; }

# 2. Staging folder: app, Applications link, hidden background.
rm -rf "$WORK" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Burrow.app"
ln -s /Applications "$STAGE/Applications"

BG1="art/brand/out/dmg-background.png"; BG2="art/brand/out/dmg-background@2x.png"
if [[ ! -f "$BG1" ]]; then
  echo "note: $BG1 not found, rendering a placeholder background"
  BG1="$WORK/background.png"; BG2="$WORK/background@2x.png"
  swift scripts/make-dmg-background.swift "$BG1" "$BG2"
fi
if [[ -f "$BG2" ]]; then
  # One multi-resolution TIFF so Finder picks the @2x representation on Retina displays.
  tiffutil -cathidpicheck "$BG1" "$BG2" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 \
    || { echo "error: tiffutil could not combine $BG1 and $BG2 (the @2x image must be exactly twice the size)" >&2; exit 1; }
  BG_NAME="background.tiff"
else
  cp "$BG1" "$STAGE/.background/background.png"
  BG_NAME="background.png"
fi

# 3. Volume icon (Finder shows it when the image is mounted).
if [[ -f build/AppIcon.icns ]]; then
  cp build/AppIcon.icns "$STAGE/.VolumeIcon.icns"
fi

# 4. Writable image, sized from the staged content plus headroom.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW"

# Mounted without -nobrowse so Finder can see (and script) the volume.
ATTACH=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen)
DEVICE=$(echo "$ATTACH" | awk '$1 ~ /^\/dev\/disk[0-9]+$/ {print $1; exit}')   # whole disk, detached at the end
MOUNT=$(echo "$ATTACH" | awk -F'\t' '/Apple_HFS/ {print $NF; exit}')
[[ -n "$DEVICE" && -d "$MOUNT" ]] || { echo "error: could not mount $RW" >&2; echo "$ATTACH" >&2; exit 1; }
DISK_NAME="$(basename "$MOUNT")"   # "Burrow", or "Burrow 1" if another Burrow volume is mounted

# Custom volume icon flag (kHasCustomIcon, 0x0400 in the root folder's FinderInfo).
if [[ -f "$MOUNT/.VolumeIcon.icns" ]]; then
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT"
  else
    xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
  fi
fi

# 5. Finder window layout, written to the volume's .DS_Store by Finder itself.
layout_with_finder() {
  osascript <<APPLESCRIPT
tell application "Finder"
  with timeout of 60 seconds
    tell disk "$DISK_NAME"
      open
      set theWindow to container window
      set current view of theWindow to icon view
      set toolbar visible of theWindow to false
      set statusbar visible of theWindow to false
      set the bounds of theWindow to {200, 120, $((200 + WIN_W)), $((120 + WIN_H))}
      set viewOptions to the icon view options of theWindow
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to $ICON_SIZE
      set text size of viewOptions to 13
      set background picture of viewOptions to file ".background:$BG_NAME"
      set position of item "Burrow.app" of theWindow to {$APP_X, $APP_Y}
      set position of item "Applications" of theWindow to {$APPS_X, $APPS_Y}
      update without registering applications
      delay 1
      close
    end tell
  end timeout
end tell
APPLESCRIPT
}

if [[ "${BURROW_SKIP_FINDER:-0}" == 1 ]]; then
  echo "warning: BURROW_SKIP_FINDER=1, the DMG window keeps Finder's default layout" >&2
else
  # Run with a watchdog: a pending Automation (TCC) prompt or a missing Finder would otherwise block.
  layout_with_finder >/dev/null 2>"$WORK/finder.log" &
  FINDER_PID=$!
  ( trap 'kill $SLEEPER 2>/dev/null; exit 0' TERM; sleep 90 & SLEEPER=$!; wait $SLEEPER; kill "$FINDER_PID" 2>/dev/null ) >/dev/null 2>&1 &
  WATCHDOG=$!
  if wait "$FINDER_PID"; then
    kill "$WATCHDOG" 2>/dev/null || true
    # Give Finder a moment to flush .DS_Store to the volume.
    for _ in {1..10}; do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 1; done
    [[ -f "$MOUNT/.DS_Store" ]] || echo "warning: Finder did not write .DS_Store; the window layout may be missing" >&2
  else
    kill "$WATCHDOG" 2>/dev/null || true
    echo "warning: Finder scripting failed or timed out, continuing without a custom window layout:" >&2
    sed 's/^/  /' "$WORK/finder.log" >&2 || true
    echo "  (allow Terminal to control Finder in System Settings › Privacy & Security › Automation, or set BURROW_SKIP_FINDER=1)" >&2
  fi
fi

# 6. Seal: drop Spotlight/Trash cruft, fix permissions, detach, compress.
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
for attempt in 1 2 3 4 5; do
  hdiutil detach "$DEVICE" -quiet && { DEVICE=""; break; }
  sleep 2
done
[[ -z "$DEVICE" ]] || { hdiutil detach "$DEVICE" -force -quiet; DEVICE=""; }

hdiutil convert "$RW" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG"

# 7. Sign the image with the same identity rules as build-app.sh.
IDENTITY="${MOLE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  codesign --force --timestamp=none --sign "$IDENTITY" "$DMG"
  SIGNED="signed: $IDENTITY"
else
  codesign --force --sign - "$DMG"
  SIGNED="ad-hoc signed"
fi

hdiutil verify -quiet "$DMG"
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built $DMG ($SIGNED, $(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "SHA-256: $(cut -d' ' -f1 "$DMG.sha256")"
