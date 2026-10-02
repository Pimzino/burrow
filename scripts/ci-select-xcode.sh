#!/bin/zsh
# CI helper: selects the Xcode used to build Burrow on a GitHub-hosted macOS runner.
#
#   scripts/ci-select-xcode.sh [/Applications/Xcode_26.6.app]
#
# Uses the requested Xcode if it is installed, otherwise the newest /Applications/Xcode_26*.app or
# later, so a runner image update that drops one point release doesn't break the build. Burrow needs
# the macOS 26 SDK and Swift 6.2+ (swift-tools-version 6.2, Liquid Glass APIs).
set -euo pipefail

WANT="${1:-${XCODE_APP:-}}"
if [[ -n "$WANT" && -d "$WANT" ]]; then
  XCODE="$WANT"
else
  [[ -n "$WANT" ]] && echo "::warning::$WANT is not installed on this runner; falling back to the newest Xcode 26+"
  XCODE=$(print -l /Applications/Xcode_2[6-9]*.app(N) | sort -V | tail -1)
fi
[[ -n "$XCODE" && -d "$XCODE" ]] || { echo "::error::No Xcode 26 or later found in /Applications"; ls -d /Applications/Xcode* || true; exit 1; }

sudo xcode-select -s "$XCODE/Contents/Developer"
xcodebuild -version
swift --version
xcrun --sdk macosx --show-sdk-version
