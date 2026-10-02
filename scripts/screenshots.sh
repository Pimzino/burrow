#!/bin/zsh
# Captures the README screenshots into docs/screenshots/ (light and dark) with dummy data: Burrow runs
# against the demo Mole in scripts/demo (fixtures for apps, history, scans; anonymised live status) and in
# privacy mode (no host name or IP addresses). Uses only safe automated actions (scans, dry runs, listings);
# the demo Mole refuses anything else.
# Usage: scripts/screenshots.sh [name ...]   e.g. scripts/screenshots.sh status analyze
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/docs/screenshots"
mkdir -p "$OUT"
./scripts/build-app.sh release >/dev/null || exit 1
BIN="$ROOT/build/Burrow.app/Contents/MacOS/Burrow"
TMP=$(mktemp -d)
trap 'pkill -f "$BIN -MoleE2ERoute" 2>/dev/null; rm -rf "$TMP"' EXIT

# name route wait extra-args...
ONLY=("$@")
shots=(
  "status dashboard 12"
  "clean clean 180"
  "uninstall uninstall 60"
  "analyze analyze 120 -MoleE2EAnalyzePath /Users/demo/Projects"
  "optimize optimize 90"
  "history history 30"
  "protection protection 30"
)
for appearance in dark light; do
  for spec in $shots; do
    set -- ${=spec}
    name=$1 route=$2 limit=$3; shift 3
    if (( ${#ONLY} )) && (( ! ${ONLY[(Ie)$name]} )); then continue; fi
    echo "▶ $name ($appearance)"
    rm -rf "$TMP/r"
    open -n "$ROOT/build/Burrow.app" --args -MoleE2ERoute "$route" -MoleE2EAutorun YES \
      -MoleE2EReportDir "$TMP/r" -BurrowAppearance "$appearance" -BurrowPrivacyMode YES \
      -moleLauncherPath "$ROOT/scripts/demo/mo" "$@"
    sleep 1; PID=$(pgrep -n -f "$BIN -MoleE2ERoute")
    start=$SECONDS
    while (( SECONDS - start < limit )) && [[ ! -f "$TMP/r/$route.json" ]]; do sleep 2; done
    sleep 3
    for attempt in 1 2 3 4 5; do
      open "$ROOT/build/Burrow.app"; sleep 1.5
      WID=$(swift scripts/window-id.swift "$PID")
      [[ -n "$WID" ]] && screencapture -x -l "$WID" "$OUT/$name-$appearance.png" 2>/dev/null && break
      sleep 2
    done
    kill "$PID" 2>/dev/null; sleep 1
  done
done
ls -la "$OUT"
