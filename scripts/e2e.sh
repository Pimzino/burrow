#!/bin/zsh
# End-to-end run: builds the app, then for every screen launches it with its safe automated action
# (scan / dry run / list — never destructive), waits for the screen's automation report, captures
# a screenshot, and writes an HTML + JSON report to e2e-results/<timestamp>/.
#
#   scripts/e2e.sh [route ...]      (default: all routes)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
# Never leave test instances behind, whatever happens.
trap 'pkill -f "$ROOT/build/Burrow.app/Contents/MacOS/Burrow -MoleE2E" 2>/dev/null' EXIT
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/e2e-results/$STAMP"
mkdir -p "$OUT/shots" "$OUT/reports"

./scripts/build-app.sh debug >/dev/null || { echo "build failed"; exit 1; }
BIN="$ROOT/build/Burrow.app/Contents/MacOS/Burrow"

typeset -A MAXWAIT
MAXWAIT=(dashboard 60 history 60 protection 60 uninstall 120 installers 180 purge 300 optimize 240 analyze 400 clean 900)
ROUTES=("$@")
(( $# )) || ROUTES=(dashboard clean uninstall optimize analyze purge installers history protection)
ROUTES=(${ROUTES:#settings})

for route in $ROUTES; do
  echo "▶ $route"
  rm -f "$OUT/reports/$route.json"
  # Launch through LaunchServices so macOS brings the window forward (not a Stage Manager thumbnail).
  open -n "$ROOT/build/Burrow.app" --args -MoleE2ERoute "$route" -MoleE2EAutorun YES -MoleE2EReportDir "$OUT/reports"
  sleep 1; PID=$(pgrep -n -f "$BIN -MoleE2ERoute")
  start=$SECONDS
  limit=${MAXWAIT[$route]:-120}
  while (( SECONDS - start < limit )) && [[ ! -f "$OUT/reports/$route.json" ]]; do sleep 2; done
  sleep 3   # let the finished state animate in
  for attempt in 1 2 3 4 5; do
    open "$ROOT/build/Burrow.app"   # re-activates the running instance
    sleep 1.5
    WID=$(swift scripts/window-id.swift "$PID")
    [[ -n "$WID" ]] && screencapture -x -o -l "$WID" "$OUT/shots/$route.png" 2>/dev/null && break
    sleep 2
  done
  kill "$PID" 2>/dev/null; sleep 1
  if [[ -f "$OUT/reports/$route.json" ]]; then echo "  report written after $((SECONDS - start))s"; else echo "  NO REPORT (timeout ${limit}s)"; fi
done

# Settings window: capture every tab (screenshot-only check; nothing is changed).
if [[ $# -eq 0 || " $* " == *" settings "* ]]; then
  for tab in general touchID completion updates activity logs uninstall about; do
    echo "▶ settings/$tab"
    open -n "$ROOT/build/Burrow.app" --args -MoleE2ERoute dashboard -MoleE2EOpenSettings YES -settingsTab "$tab"
    sleep 1; PID=$(pgrep -n -f "$BIN -MoleE2ERoute")
    sleep 7
    WID=$(swift scripts/window-id.swift "$PID" smallest)
    if [[ -n "$WID" ]] && screencapture -x -o -l "$WID" "$OUT/shots/settings-$tab.png"; then
      printf '{"feature":"settings-%s","passed":true,"detail":"Settings tab rendered","metrics":{}}' "$tab" > "$OUT/reports/settings-$tab.json"
    fi
    kill "$PID" 2>/dev/null; sleep 1
  done
fi

python3 - "$OUT" <<'PY'
import json, os, sys, html, datetime
out = sys.argv[1]
rows, results = [], []
routes = sorted({f[:-5] for f in os.listdir(os.path.join(out, "reports")) if f.endswith(".json")} |
                {f[:-4] for f in os.listdir(os.path.join(out, "shots")) if f.endswith(".png")})
for route in routes:
    f = route + ".png"
    rp = os.path.join(out, "reports", route + ".json")
    r = json.load(open(rp)) if os.path.exists(rp) else {"feature": route, "passed": False, "detail": "no report (timeout)", "metrics": {}}
    # Screenshots are best-effort: macOS may keep the window off screen (Spaces, Stage Manager)
    # while you use the Mac. Pass/fail comes from the screen's own automation report.
    r = dict(r, screenshot=os.path.exists(os.path.join(out, "shots", f)))
    results.append(r)
    badge = "pass" if r["passed"] else "fail"
    metrics = "".join(f"<li><b>{html.escape(k)}</b>: {html.escape(str(v))}</li>" for k, v in sorted(r.get("metrics", {}).items()))
    shot = f'<img src="shots/{f}" alt="{route}">' if r["screenshot"] else "<p><i>Screenshot unavailable (window was not on screen).</i></p>"
    rows.append(f"""<section><h2>{html.escape(route)} <span class="{badge}">{badge.upper()}</span></h2>
<p>{html.escape(r['detail'])}</p><ul>{metrics}</ul>{shot}</section>""")
passed = sum(r["passed"] for r in results)
json.dump({"passed": passed, "total": len(results), "results": results}, open(os.path.join(out, "summary.json"), "w"), indent=2)
open(os.path.join(out, "index.html"), "w").write(f"""<!doctype html><meta charset="utf-8"><title>Burrow E2E</title>
<style>body{{font:14px -apple-system;margin:32px;background:#111;color:#eee}}img{{max-width:100%;border-radius:12px;margin-top:8px}}
section{{margin-bottom:48px}}.pass{{background:#1f7a3a}}.fail{{background:#9a2222}}span{{padding:2px 8px;border-radius:6px;font-size:12px}}</style>
<h1>Burrow end-to-end run — {passed}/{len(results)} passed</h1><p>{datetime.datetime.now().isoformat(timespec='seconds')}</p>{''.join(rows)}""")
shots = sum(r["screenshot"] for r in results)
print(f"{passed}/{len(results)} passed ({shots} screenshots) → {out}/index.html")
PY
