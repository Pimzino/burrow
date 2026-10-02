#!/bin/zsh
# Launches a Burrow build on one route (optionally autorunning its safe action), waits, and captures
# its main window.  Usage: scripts/shot.sh <binary> <route> <out.png> [wait-seconds] [autorun YES|NO] [report-dir]
set -euo pipefail
BIN="$1"; ROUTE="$2"; OUT="$3"; WAIT="${4:-6}"; AUTORUN="${5:-NO}"; REPORT="${6:-}"
ARGS=(-MoleE2ERoute "$ROUTE" -MoleE2EAutorun "$AUTORUN")
[[ -n "$REPORT" ]] && ARGS+=(-MoleE2EReportDir "$REPORT")
"$BIN" "${ARGS[@]}" >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
sleep "$WAIT"
WID=$(swift "$(dirname "$0")/window-id.swift" "$PID")
if [[ -z "$WID" ]]; then echo "no window for pid $PID" >&2; exit 1; fi
screencapture -x -o -l "$WID" "$OUT"
echo "$OUT"
