#!/bin/zsh
# End-to-end check that the Clean screen's category sizes add up to Mole's own total.
#
# Mole sums "Potential space" from its preview file, not from the rows it prints: a row can have no
# size at all ("Browser code signature caches, 1 items" for a 6.74GB folder) and another can repeat
# bytes an earlier section already counted (Homebrew downloads inside ~/Library/Caches/Homebrew).
# This replays such a scan through the demo Mole (its `system` clean variant; nothing is deleted), then
# compares what the app shows per category with the preview file. Writes a screenshot and an
# HTML + JSON report to e2e-results/clean-totals-<timestamp>/.
#
#   scripts/clean-totals-e2e.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BIN="$ROOT/build/Burrow.app/Contents/MacOS/Burrow"
# Never leave test instances behind, whatever happens.
VARIANT="${TMPDIR:-/tmp}/burrow-demo/clean-variant"
trap 'pkill -f "$BIN -MoleE2ERoute" 2>/dev/null; rm -f "$VARIANT"' EXIT
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/e2e-results/clean-totals-$STAMP"
mkdir -p "$OUT/reports"

./scripts/build-app.sh debug >/dev/null || { echo "build failed"; exit 1; }

# The demo scan already contains the System section, so the app must not ask for a password.
mkdir -p "${VARIANT:h}" && print system > "$VARIANT"
open -n "$ROOT/build/Burrow.app" --args -MoleE2ERoute clean -MoleE2EAutorun YES \
  -MoleE2EReportDir "$OUT/reports" -moleLauncherPath "$ROOT/scripts/demo/mo" -BurrowPrivacyMode YES \
  -clean.includeSystem NO -MoleE2EExpand System
sleep 1; PID=$(pgrep -n -f "$BIN -MoleE2ERoute")
start=$SECONDS
while (( SECONDS - start < 120 )) && [[ ! -f "$OUT/reports/clean.json" ]]; do sleep 1; done
sleep 3   # let the finished state animate in
for attempt in 1 2 3 4 5; do
  open "$ROOT/build/Burrow.app"; sleep 1.5
  WID=$(swift scripts/window-id.swift "$PID")
  [[ -n "$WID" ]] && screencapture -x -o -l "$WID" "$OUT/clean-totals.png" 2>/dev/null && break
  sleep 2
done
kill "$PID" 2>/dev/null

python3 - "$OUT" "$ROOT/scripts/demo/fixtures/clean-list-system.txt" <<'PY'
import html, json, os, re, sys
out, fixture = sys.argv[1], sys.argv[2]
UNITS = {"TB": 1e12, "GB": 1e9, "MB": 1e6, "KB": 1e3, "B": 1, "bytes": 1}

def size(text):
    m = re.search(r"([\d.,]+)\s*(TB|GB|MB|KB|bytes|B)\b", text)
    return float(m[1].replace(",", "")) * UNITS[m[2]] if m else None

# What Mole counts per section: every measured path that isn't inside another listed path.
expected, section, total = {}, None, None
for line in open(fixture):
    if m := re.match(r"=== (.+) ===", line):
        section = m[1]
    elif m := re.match(r"# Potential cleanup: (\S+)", line):
        total = size(m[1])
    elif section and "  # " in line and "counted under" not in line:
        expected[section] = expected.get(section, 0) + (size(line.split("  # ")[1]) or 0)
expected = {k: v for k, v in expected.items() if v > 0}

path = os.path.join(out, "reports", "clean.json")
report = json.load(open(path)) if os.path.exists(path) else None
metrics = (report or {}).get("metrics", {})
shown = {k: size(v) for k, v in (p.split("=") for p in metrics.get("categorySizes", "").split("; ") if "=" in p)}

def close(a, b):   # the app shows three significant digits
    return a is not None and b is not None and abs(a - b) <= max(0.01 * b, 1000)

checks = [("the scan finished and was reported", bool(report and report.get("passed")), (report or {}).get("detail", "no report"))]
checks.append(("headline is Mole's total", close(size(metrics.get("potential", "")), total), metrics.get("potential", "—")))
checks.append(("categories add up to the headline", close(size(metrics.get("categoriesTotal", "")), total), metrics.get("categoriesTotal", "—")))
for name, want in expected.items():
    checks.append((f"{name} shows what the preview file lists", close(shown.get(name), want),
                   f"shown {shown.get(name)}, listed {want:.0f} bytes"))
checks.append(("no category beyond the preview file", set(shown) <= set(expected), ", ".join(sorted(set(shown) - set(expected))) or "none"))

passed = all(ok for _, ok, _ in checks)
json.dump({"passed": passed, "checks": [{"check": c, "passed": ok, "detail": d} for c, ok, d in checks], "metrics": metrics},
          open(os.path.join(out, "summary.json"), "w"), indent=2)
rows = "".join(f'<tr><td><span class="{"pass" if ok else "fail"}">{"PASS" if ok else "FAIL"}</span></td><td>{html.escape(c)}</td><td>{html.escape(str(d))}</td></tr>'
               for c, ok, d in checks)
shot = '<img src="clean-totals.png" alt="Clean">' if os.path.exists(os.path.join(out, "clean-totals.png")) else "<p><i>Screenshot unavailable (window was not on screen).</i></p>"
open(os.path.join(out, "index.html"), "w").write(f"""<!doctype html><meta charset="utf-8"><title>Burrow clean totals</title>
<style>body{{font:14px -apple-system;margin:32px;background:#111;color:#eee}}img{{max-width:100%;border-radius:12px;margin-top:16px}}
td{{padding:4px 12px 4px 0}}.pass{{background:#1f7a3a}}.fail{{background:#9a2222}}span{{padding:2px 8px;border-radius:6px;font-size:12px}}</style>
<h1>Clean totals — {"passed" if passed else "FAILED"}</h1><table>{rows}</table>{shot}""")
for c, ok, d in checks:
    print(("  ✓ " if ok else "  ✗ ") + c + f" ({d})")
print(("PASSED" if passed else "FAILED") + f" → {out}/index.html")
sys.exit(0 if passed else 1)
PY
