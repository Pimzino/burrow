#!/bin/zsh
# End-to-end run of first-run setup: builds the app, shows every setup step in dark and light
# appearance (`-BurrowSetup <step>`, which never saves anything or requests a permission), captures
# each one, then walks the whole flow the way the Continue button does and checks that the app opens.
# Writes an HTML + JSON report to e2e-results/setup-<timestamp>/.
#
#   scripts/setup-e2e.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BIN="$ROOT/build/Burrow.app/Contents/MacOS/Burrow"
# Never leave test instances behind, whatever happens.
trap 'pkill -f "$BIN -BurrowSetup" 2>/dev/null' EXIT
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/e2e-results/setup-$STAMP"
mkdir -p "$OUT/shots" "$OUT/reports"

./scripts/build-app.sh debug >/dev/null || { echo "build failed"; exit 1; }

# launch <report-subdir> <args...>: starts an instance and sets PID.
launch() {
  local dir="$1"; shift
  mkdir -p "$OUT/reports/$dir"
  # Launch through LaunchServices so macOS brings the window forward (not a Stage Manager thumbnail).
  open -n "$ROOT/build/Burrow.app" --args "$@" -MoleE2EReportDir "$OUT/reports/$dir"
  sleep 1; PID=$(pgrep -n -f "$BIN -BurrowSetup")
}

wait_for() {   # wait_for <file> <seconds>
  local start=$SECONDS
  while (( SECONDS - start < $2 )) && [[ ! -f "$1" ]]; do sleep 0.5; done
  [[ -f "$1" ]]
}

capture() {    # capture <out.png>
  for attempt in 1 2 3; do
    WID=$(swift scripts/window-id.swift "$PID")
    [[ -n "$WID" ]] && screencapture -x -o -l "$WID" "$1" 2>/dev/null && return 0
    open "$ROOT/build/Burrow.app"; sleep 1.5
  done
  return 1
}

for appearance in dark light; do
  for step in welcome mole access ready; do
    echo "▶ $step ($appearance)"
    launch "$appearance" -BurrowSetup "$step" -BurrowAppearance "$appearance"
    wait_for "$OUT/reports/$appearance/setup-$step.json" 30 || echo "  NO REPORT"
    sleep 1.5   # let the step settle
    capture "$OUT/shots/$step-$appearance.png" || echo "  no screenshot"
    kill "$PID" 2>/dev/null; sleep 1
  done
done

echo "▶ walk (welcome → finish)"
launch walk -BurrowSetup welcome -BurrowSetupWalk YES -BurrowAppearance dark
wait_for "$OUT/reports/walk/setup-finish.json" 60 || echo "  NO REPORT"
sleep 3   # the main interface fades in
capture "$OUT/shots/after-setup.png" || echo "  no screenshot"
kill "$PID" 2>/dev/null

python3 - "$OUT" <<'PY'
import json, os, sys, html, datetime
out = sys.argv[1]
def report(sub, name):
    p = os.path.join(out, "reports", sub, name + ".json")
    return json.load(open(p)) if os.path.exists(p) else None
results, rows = [], []
def add(name, r, shot, expect=None):
    r = r or {"passed": False, "detail": "no report (timeout)", "metrics": {}}
    passed = bool(r["passed"]) and (expect is None or expect(r))
    has_shot = shot is not None and os.path.exists(os.path.join(out, "shots", shot))
    results.append({"check": name, "passed": passed, "detail": r["detail"], "metrics": r.get("metrics", {}), "screenshot": has_shot})
    metrics = "".join(f"<li><b>{html.escape(k)}</b>: {html.escape(str(v))}</li>" for k, v in sorted(r.get("metrics", {}).items()))
    img = f'<img src="shots/{shot}" alt="{name}">' if has_shot else ("" if shot is None else "<p><i>Screenshot unavailable (window was not on screen).</i></p>")
    badge = "pass" if passed else "fail"
    rows.append(f'<section><h2>{html.escape(name)} <span class="{badge}">{badge.upper()}</span></h2><p>{html.escape(r["detail"])}</p><ul>{metrics}</ul>{img}</section>')
for appearance in ("dark", "light"):
    for step in ("welcome", "mole", "access", "ready"):
        add(f"{step} ({appearance})", report(appearance, f"setup-{step}"), f"{step}-{appearance}.png")
# The walk must visit every step of its list, in order, and end with the app open.
first = report("walk", "setup-welcome")
steps = (first or {}).get("metrics", {}).get("steps", "welcome,access,ready").split(",")
for i, step in enumerate(steps):
    add(f"walk: {step}", report("walk", f"setup-{step}"), None,
        expect=lambda r, i=i: r["detail"] == f"Step {i + 1} of {len(steps)}")
add("walk: finish", report("walk", "setup-finish"), "after-setup.png")
passed = sum(r["passed"] for r in results)
json.dump({"passed": passed, "total": len(results), "results": results}, open(os.path.join(out, "summary.json"), "w"), indent=2)
open(os.path.join(out, "index.html"), "w").write(f"""<!doctype html><meta charset="utf-8"><title>Burrow setup E2E</title>
<style>body{{font:14px -apple-system;margin:32px;background:#111;color:#eee}}img{{max-width:100%;border-radius:12px;margin-top:8px}}
section{{margin-bottom:48px}}.pass{{background:#1f7a3a}}.fail{{background:#9a2222}}span{{padding:2px 8px;border-radius:6px;font-size:12px}}</style>
<h1>Burrow setup end-to-end run — {passed}/{len(results)} passed</h1><p>{datetime.datetime.now().isoformat(timespec='seconds')}</p>{''.join(rows)}""")
print(f"{passed}/{len(results)} passed → {out}/index.html")
sys.exit(0 if passed == len(results) else 1)
PY
