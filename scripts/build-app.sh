#!/bin/zsh
# Builds Burrow.app into ./build using SwiftPM (no Xcode project needed).
#
#   scripts/build-app.sh [debug|release]
#
# Environment:
#   BURROW_VERSION      sets CFBundleShortVersionString in the bundled Info.plist (a leading "v" is dropped)
#   BURROW_BUILD        sets CFBundleVersion in the bundled Info.plist
#   BURROW_UPDATE_PUBLIC_KEY  overrides BurrowUpdatePublicKey (the Ed25519 key updates must be signed with;
#                       scripts/update-e2e.sh uses a throwaway key)
#   BURROW_BUNDLE_ID    overrides CFBundleIdentifier (test builds that must not share the real app's settings)
#   MOLE_SIGN_IDENTITY  codesigning identity (name or SHA-1); "-" forces an ad-hoc signature
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Burrow.app"

swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Burrow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Burrow"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Version override (the source Info.plist is never modified).
if [[ -n "${BURROW_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${BURROW_VERSION#v}" "$APP/Contents/Info.plist"
fi
if [[ -n "${BURROW_BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BURROW_BUILD" "$APP/Contents/Info.plist"
fi
if [[ -n "${BURROW_UPDATE_PUBLIC_KEY+set}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :BurrowUpdatePublicKey $BURROW_UPDATE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi
if [[ -n "${BURROW_BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BURROW_BUNDLE_ID" "$APP/Contents/Info.plist"
fi

# Brand artwork is rendered by art/brand/build.sh (Blender) and committed, so builds and CI never
# need Blender.
BRAND="art/brand/out"
if [[ ! -f "$BRAND/AppIcon.icns" ]]; then
  echo "error: $BRAND/AppIcon.icns is missing; run art/brand/build.sh" >&2
  exit 1
fi
mkdir -p build
cp "$BRAND/AppIcon.icns" build/AppIcon.icns
cp "$BRAND/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for f in menubar-template.png menubar-template@2x.png; do
  [[ -f "$BRAND/$f" ]] && cp "$BRAND/$f" "$APP/Contents/Resources/$f"
done

# Sign with a stable identity so macOS privacy permissions (Files & Folders, Automation, Full Disk
# Access) survive rebuilds. TCC ties grants to the signature; an ad-hoc signature changes every build.
# Override with MOLE_SIGN_IDENTITY="<name or SHA-1>" (or "-" for ad-hoc).
IDENTITY="${MOLE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP" >/dev/null
  echo "Built $APP (signed: $IDENTITY)"
else
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "Built $APP (ad-hoc signed — permissions will be re-requested after each rebuild;" >&2
  echo "  add your Apple ID in Xcode → Settings → Accounts to get an Apple Development certificate)" >&2
fi
