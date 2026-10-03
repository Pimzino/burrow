#!/bin/zsh
# End-to-end test of Burrow's in-app updater against a local stand-in for the GitHub Releases API.
#
# Builds two real app versions (OLD and NEW) signed for updates with a throwaway Ed25519 key and a separate
# bundle id (so the real app's settings are untouched), packages NEW as a real DMG, installs OLD into a
# scratch "Applications" folder, and launches it with `-BurrowUpdateE2E install` once per scenario:
#
#   not-newer    the feed's newest release is OLD itself            → "Up to date", nothing downloaded
#   no-signature the release has a DMG but no .sig asset            → offered, but never installed in place
#   bad-digest   GitHub's sha256 digest doesn't match the DMG       → refused, OLD untouched
#   tampered     one byte of the DMG changed (no digest to catch it) → signature check refuses, OLD untouched
#   wrong-key    DMG signed by a different key                       → signature check refuses, OLD untouched
#   wrong-app    validly signed DMG holding a different bundle id    → refused, OLD untouched
#   happy        valid DMG and signature                             → NEW swapped in, OLD quits, NEW relaunches
#
# Writes e2e-results/update-<timestamp>/ with index.html, summary.json, per-scenario reports, the fake
# server's request log, and a capture of the Software Update window.
#
#   scripts/update-e2e.sh
#   UPDATE_E2E_SYSTEM_APPLICATIONS=1 scripts/update-e2e.sh   # also run "happy" from /Applications/Burrow E2E.app
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OLD=1.0.0; NEW=1.1.0
BUNDLE_ID=io.github.pimzino.burrow.e2e
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/e2e-results/update-$STAMP"
W="$ROOT/build/update-e2e"
SERVER_PID=""

cleanup() {
  pkill -f "$W/" 2>/dev/null
  [[ -n "${SYSTEM_APP:-}" ]] && pkill -f "$SYSTEM_APP/Contents/MacOS/Burrow" 2>/dev/null
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  [[ -n "${SYSTEM_APP:-}" && -d "$SYSTEM_APP" ]] && rm -rf "$SYSTEM_APP"
}
trap cleanup EXIT
rm -rf "$W"; mkdir -p "$W/server" "$W/keys" "$OUT/reports" "$OUT/shots"

# 1. Keys: the trusted one, and an untrusted one for the wrong-key scenario.
PUB=$(swift scripts/update-signing.swift generate --key-file "$W/keys/trusted.key") || exit 1
swift scripts/update-signing.swift generate --key-file "$W/keys/untrusted.key" >/dev/null || exit 1

# 2. NEW as a real DMG, plus a DMG of a different app (same version, other bundle id).
build() {   # build <version> <bundle id>
  BURROW_VERSION="$1" BURROW_UPDATE_PUBLIC_KEY="$PUB" BURROW_BUNDLE_ID="$2" ./scripts/build-app.sh release >/dev/null || exit 1
}
echo "▶ building $NEW and its DMG"
build "$NEW" "$BUNDLE_ID"
BURROW_SKIP_BUILD=1 BURROW_SKIP_FINDER=1 ./scripts/make-dmg.sh "$NEW" >/dev/null 2>&1 || { echo "make-dmg failed"; exit 1; }
mv "build/Burrow-$NEW.dmg" "$W/server/Burrow-$NEW.dmg"
build "$NEW" "io.example.not-burrow"
BURROW_SKIP_BUILD=1 BURROW_SKIP_FINDER=1 ./scripts/make-dmg.sh "$NEW" >/dev/null 2>&1 || exit 1
mv "build/Burrow-$NEW.dmg" "$W/server/other-app.dmg"
rm -f build/Burrow-$NEW.dmg.sha256

# 3. OLD, installed into a scratch Applications folder.
echo "▶ building $OLD"
build "$OLD" "$BUNDLE_ID"
mkdir -p "$W/Applications"

# 4. Signatures and the tampered copy (same size; last byte flipped).
sign() { swift scripts/update-signing.swift sign "$1" --key-file "$2"; }
sign "$W/server/Burrow-$NEW.dmg" "$W/keys/trusted.key" > "$W/server/good.sig"
sign "$W/server/Burrow-$NEW.dmg" "$W/keys/untrusted.key" > "$W/server/untrusted.sig"
sign "$W/server/other-app.dmg" "$W/keys/trusted.key" > "$W/server/other-app.sig"
python3 - "$W/server/Burrow-$NEW.dmg" "$W/server/tampered.dmg" <<'PY'
import sys
data = bytearray(open(sys.argv[1], "rb").read())
data[-1] ^= 0xFF
open(sys.argv[2], "wb").write(data)
PY

# 5. A stand-in for api.github.com: /releases/latest answers per the scenario in $W/scenario.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat > "$W/server.py" <<'PY'
import hashlib, http.server, json, os, sys
W, OLD, NEW, PORT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
S = os.path.join(W, "server")
def sha(path): return "sha256:" + hashlib.sha256(open(path, "rb").read()).hexdigest()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        open(os.path.join(W, "requests.log"), "a").write(f"{open(os.path.join(W, 'scenario')).read().strip()} {self.path}\n")
    def send(self, code, body, kind="application/json"):
        self.send_response(code); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        scenario = open(os.path.join(W, "scenario")).read().strip()
        base = f"http://127.0.0.1:{PORT}"
        if self.path.startswith("/assets/"):
            name = self.path.split("/")[2]
            files = {"Burrow-%s.dmg" % NEW: {"tampered": "tampered.dmg", "wrong-app": "other-app.dmg"}.get(scenario, f"Burrow-{NEW}.dmg"),
                     "Burrow-%s.dmg.sig" % NEW: {"wrong-key": "untrusted.sig", "wrong-app": "other-app.sig"}.get(scenario, "good.sig")}
            path = os.path.join(S, files.get(name, "missing"))
            return self.send(200, open(path, "rb").read(), "application/octet-stream") if os.path.exists(path) else self.send(404, b"{}")
        if self.path.rstrip("/").endswith("/releases/latest"):
            version = OLD if scenario == "not-newer" else NEW
            dmg = os.path.join(S, {"tampered": "tampered.dmg", "wrong-app": "other-app.dmg"}.get(scenario, f"Burrow-{NEW}.dmg"))
            assets = [{"name": f"Burrow-{version}.dmg", "browser_download_url": f"{base}/assets/Burrow-{version}.dmg",
                       "size": os.path.getsize(dmg), "state": "uploaded",
                       "digest": None if scenario == "tampered" else ("sha256:" + "0" * 64 if scenario == "bad-digest" else sha(dmg))}]
            if scenario != "no-signature":
                assets.append({"name": f"Burrow-{version}.dmg.sig", "browser_download_url": f"{base}/assets/Burrow-{version}.dmg.sig",
                               "size": 89, "state": "uploaded", "digest": None})
            body = {"tag_name": f"v{version}", "name": f"Burrow {version}", "draft": False, "prerelease": False,
                    "html_url": f"https://github.com/Pimzino/burrow/releases/tag/v{version}", "published_at": "2026-10-03T09:00:00Z",
                    "body": "## What's Changed\n* In-app updates from GitHub Releases\n* Signed update packages (Ed25519)\n\n**Full Changelog**: v1.0.0...v1.1.0",
                    "assets": assets}
            return self.send(200, json.dumps(body).encode())
        self.send(404, b'{"message": "Not Found"}')
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY
echo "not-newer" > "$W/scenario"
python3 "$W/server.py" "$W" "$OLD" "$NEW" "$PORT" &
SERVER_PID=$!
sleep 1

# 6. Scenarios.
FAIL=0
typeset -a ROWS
# The app's pid (not one of its `--mole-helper` children, which share the executable path).
app_pid() {
  local p
  for p in $(pgrep -f "$1/Contents/MacOS/Burrow"); do
    ps -o args= -p "$p" | grep -q -- '--mole-helper' || echo "$p"
  done | tail -1
}
version_at() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
report() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["passed"], d["detail"], sep="\t")' "$1" 2>/dev/null; }

run() {   # run <scenario> <expect: up-to-date|offer-only|refused|installed> [app path]
  local scenario=$1 expect=$2 app=${3:-$W/Applications/Burrow.app}
  local dir="$OUT/reports/$scenario"; mkdir -p "$dir"
  rm -rf "$app"; ditto "$ROOT/build/Burrow.app" "$app"
  echo "$scenario" > "$W/scenario"
  echo "▶ $scenario (expect $expect)"
  open -n "$app" --args -BurrowUpdateAPIURL "http://127.0.0.1:$PORT/releases" -BurrowUpdateE2E install -BurrowUpdateE2EInstallDelay 6 -MoleE2EReportDir "$dir"
  local start=$SECONDS pid=""
  while (( SECONDS - start < 20 )) && [[ -z "$pid" ]]; do pid=$(app_pid "$app"); sleep 0.3; done
  local want="$dir/update-install.json"; [[ $expect == up-to-date || $expect == offer-only ]] && want="$dir/update-check.json"
  while (( SECONDS - start < 120 )) && [[ ! -f "$want" ]]; do
    # Capture the Software Update window while it offers the release (the app waits 6 s before installing).
    if [[ $scenario == happy && ! -f "$OUT/shots/update-window.png" && -f "$dir/update-check.json" && -n "$pid" ]]; then
      sleep 1.5; WID=$(swift scripts/window-id.swift "$pid" smallest)
      [[ -n "$WID" ]] && screencapture -x -o -l "$WID" "$OUT/shots/update-window.png" 2>/dev/null
    fi
    sleep 0.3
  done
  local result="" ok=1 detail
  [[ -f "$want" ]] && result=$(report "$want")
  detail="${result#*	}"
  case $expect in
    up-to-date) [[ "$result" == "True	Up to date" ]] || ok=0 ;;
    offer-only) [[ "$result" == True* ]] && grep -q '"installBlocker" : "This release has no signed disk image' "$want" || ok=0 ;;
    refused)
      sleep 1
      [[ "$result" == False* ]] || ok=0
      [[ "$(version_at "$app")" == "$OLD" ]] || { ok=0; detail+=" | app on disk changed to $(version_at "$app")"; } ;;
    installed)
      [[ "$result" == True* ]] || ok=0
      # OLD quits, then the detached relauncher opens NEW from the same path.
      local t=$SECONDS newpid=""
      while (( SECONDS - t < 30 )); do
        newpid=$(app_pid "$app")
        [[ -n "$newpid" && "$newpid" != "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && break
        newpid=""; sleep 0.5
      done
      [[ "$(version_at "$app")" == "$NEW" ]] || { ok=0; detail+=" | app on disk is $(version_at "$app")"; }
      [[ -n "$newpid" ]] || { ok=0; detail+=" | NEW was not relaunched"; }
      codesign --verify --deep --strict "$app" 2>/dev/null || { ok=0; detail+=" | installed app fails codesign"; }
      [[ "$app" == "$W/"* ]] && ls -A "$(dirname "$app")" | grep -vx 'Burrow.app' | grep -q . && { ok=0; detail+=" | leftovers next to the app"; }
      [[ -n "$newpid" ]] && { sleep 3; WID=$(swift scripts/window-id.swift "$newpid"); [[ -n "$WID" ]] && screencapture -x -o -l "$WID" "$OUT/shots/relaunched-$scenario.png" 2>/dev/null; }
      [[ -n "$newpid" ]] && detail+=" | relaunched as pid $newpid running $(version_at "$app")" ;;
  esac
  pkill -f "$app/Contents/MacOS/Burrow" 2>/dev/null; sleep 1
  (( ok )) && echo "  PASS: $detail" || { echo "  FAIL: ${detail:-no report}"; FAIL=1; }
  ROWS+=("$scenario	$expect	$ok	${detail:-no report}")
}

run not-newer up-to-date
run no-signature offer-only
run bad-digest refused
run tampered refused
run wrong-key refused
run wrong-app refused
run happy installed
if [[ "${UPDATE_E2E_SYSTEM_APPLICATIONS:-0}" == 1 ]]; then
  SYSTEM_APP="/Applications/Burrow E2E.app"
  run happy-system-applications installed "$SYSTEM_APP"
fi

# Settings › Updates with an update on offer (screenshot only).
echo "▶ settings capture"
rm -rf "$W/Applications/Burrow.app"; ditto "$ROOT/build/Burrow.app" "$W/Applications/Burrow.app"
echo "happy" > "$W/scenario"
open -n "$W/Applications/Burrow.app" --args -BurrowUpdateAPIURL "http://127.0.0.1:$PORT/releases" -BurrowUpdateE2E check \
  -MoleE2EReportDir "$OUT/reports/settings" -MoleE2ERoute dashboard -MoleE2EOpenSettings YES -settingsTab updates
sleep 1; PID=$(app_pid "$W/Applications/Burrow.app")
sleep 8
WID=$(swift scripts/window-id.swift "$PID" smallest)
[[ -n "$WID" ]] && screencapture -x -o -l "$WID" "$OUT/shots/settings-updates.png" 2>/dev/null
pkill -f "$W/Applications/Burrow.app/Contents/MacOS/Burrow" 2>/dev/null

cp "$W/requests.log" "$OUT/requests.log" 2>/dev/null
# Assert from the server's side: a refused or up-to-date run never fetched more than it had to.
grep -q "^not-newer /assets/" "$OUT/requests.log" && { echo "FAIL: not-newer downloaded assets"; FAIL=1; ROWS+=("not-newer-requests	no downloads	0	assets were requested"); }
grep -q "^no-signature /assets/" "$OUT/requests.log" && { echo "FAIL: no-signature downloaded assets"; FAIL=1; ROWS+=("no-signature-requests	no downloads	0	assets were requested"); }

printf '%s\n' "${ROWS[@]}" > "$W/rows.tsv"
python3 - "$OUT" "$OLD" "$NEW" "$W/rows.tsv" <<'PY'
import datetime, html, json, os, sys
out, old, new, tsv = sys.argv[1:5]
rows = [l.rstrip("\n").split("\t", 3) for l in open(tsv) if l.strip()]
results = [{"scenario": s, "expect": e, "passed": ok == "1", "detail": d} for s, e, ok, d in rows]
passed = sum(r["passed"] for r in results)
json.dump({"old": old, "new": new, "passed": passed, "total": len(results), "results": results},
          open(os.path.join(out, "summary.json"), "w"), indent=2)
trs = "".join(f"<tr><td>{html.escape(r['scenario'])}</td><td>{html.escape(r['expect'])}</td>"
              f"<td class={'pass' if r['passed'] else 'fail'}>{'PASS' if r['passed'] else 'FAIL'}</td><td>{html.escape(r['detail'])}</td></tr>" for r in results)
shots = "".join(f'<figure><img src="shots/{f}"><figcaption>{html.escape(f)}</figcaption></figure>'
                for f in sorted(os.listdir(os.path.join(out, "shots"))))
log = html.escape(open(os.path.join(out, "requests.log")).read()) if os.path.exists(os.path.join(out, "requests.log")) else ""
open(os.path.join(out, "index.html"), "w").write(f"""<!doctype html><meta charset="utf-8"><title>Burrow update E2E</title>
<style>body{{font:14px -apple-system;margin:32px;background:#111;color:#eee}}table{{border-collapse:collapse}}td,th{{padding:6px 10px;border-bottom:1px solid #333;text-align:left;vertical-align:top}}
.pass{{color:#4ade80}}.fail{{color:#f87171}}img{{max-width:640px;border-radius:12px}}figure{{display:inline-block;margin:16px}}pre{{background:#000;padding:12px;border-radius:8px}}</style>
<h1>Burrow in-app update E2E: {passed}/{len(results)} passed</h1><p>{old} → {new} · {datetime.datetime.now().isoformat(timespec='seconds')}</p>
<table><tr><th>Scenario</th><th>Expected</th><th>Result</th><th>Detail</th></tr>{trs}</table>{shots}<h2>Requests to the fake GitHub API</h2><pre>{log}</pre>""")
print(f"{passed}/{len(results)} passed → {out}/index.html")
PY
exit $FAIL
