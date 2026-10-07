#!/bin/zsh
# End-to-end check that an update keeps Burrow's macOS privacy permissions.
#
# macOS stores each permission (Full Disk Access, Files & Folders, Automation) with the designated
# requirement of the app it was given to, and honours it only for code that satisfies that requirement.
# This builds two versions of Burrow the way a release does, signed with a throwaway identity made by
# scripts/signing-identity.sh, and checks that each satisfies the other's requirement. It then signs the
# same two builds ad-hoc and checks that they do not, which is the bug this guards against. Nothing here
# touches the real identity, the real app's permissions or its settings.
#
# Writes e2e-results/signing-<timestamp>/index.html and results.json.
#
#   scripts/signing-e2e.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/e2e-results/signing-$STAMP"
W="$ROOT/build/signing-e2e"
BUNDLE_ID=io.github.pimzino.burrow.e2e
export BURROW_SIGNING_SERVICE="io.github.pimzino.burrow.code-signing.e2e-$STAMP"
export BURROW_SIGNING_KEYCHAIN="$W/signing-e2e.keychain-db"
OLD=1.0.0; NEW=1.1.0

cleanup() {
  pkill -f "$W/" 2>/dev/null
  security delete-keychain "$BURROW_SIGNING_KEYCHAIN" >/dev/null 2>&1   # also leaves the search list
  for account in p12 password; do
    security delete-generic-password -s "$BURROW_SIGNING_SERVICE" -a "$account" >/dev/null 2>&1
  done
}
trap cleanup EXIT
rm -rf "$W"; mkdir -p "$W" "$OUT"
RESULTS="$OUT/results.tsv"; : > "$RESULTS"
FAILED=0
check() {   # check <name> <ok: 0|1> <detail>
  local mark="PASS"; [[ "$2" == 1 ]] || { mark="FAIL"; FAILED=1; }
  print -r -- "$mark	$1	${3//$'\n'/ }" >> "$RESULTS"
  echo "$mark  $1"; [[ "$mark" == PASS ]] || echo "      $3"
}
requirement() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^.*designated => //p'; }
satisfies() { codesign --verify -R="$2" "$1" 2>/dev/null; }   # satisfies <app> <requirement>

SEARCH_BEFORE=$(security list-keychains -d user)

echo "▶ creating a throwaway signing identity"
SHA=$(./scripts/signing-identity.sh create 2>"$OUT/create.log")
[[ "$SHA" =~ ^[0-9A-F]{40}$ ]] && ok=1 || ok=0
check "A signing identity is created without any prompt" $ok "$(tail -3 "$OUT/create.log")"
(( ok )) || { echo "cannot continue"; exit 1; }
[[ "$(./scripts/signing-identity.sh unlock 2>&1)" == "$SHA" ]] && ok=1 || ok=0
check "The build can unlock it and read its fingerprint" $ok "unlock did not print $SHA"

echo "▶ building $OLD and $NEW"
build() {   # build <version>: leaves $W/Burrow-<version>.app, signed by build-app.sh's default identity
  BURROW_VERSION="$1" BURROW_BUNDLE_ID="$BUNDLE_ID" ./scripts/build-app.sh debug >"$OUT/build-$1.log" 2>&1 || return 1
  rm -rf "$W/Burrow-$1.app" && cp -R build/Burrow.app "$W/Burrow-$1.app"
}
build "$OLD" && build "$NEW" || { check "Both versions build" 0 "see build logs in $OUT"; exit 1; }
A="$W/Burrow-$OLD.app"; B="$W/Burrow-$NEW.app"

grep -q "signed: $SHA" "$OUT/build-$NEW.log" && ok=1 || ok=0
check "build-app.sh signs with the release identity by default" $ok "$(tail -1 "$OUT/build-$NEW.log")"

REQ_A=$(requirement "$A"); REQ_B=$(requirement "$B")
EXPECTED="identifier \"$BUNDLE_ID\" and certificate leaf = H\"${SHA:l}\""
[[ "$REQ_A" == "$EXPECTED" ]] && ok=1 || ok=0
check "The requirement names the app and the certificate, not one build" $ok "got: $REQ_A"
[[ -n "$REQ_A" && "$REQ_A" == "$REQ_B" ]] && ok=1 || ok=0
check "$OLD and $NEW have the same requirement" $ok "$OLD: $REQ_A | $NEW: $REQ_B"
[[ "$(codesign -dvvv "$A" 2>&1 | sed -n 's/^CDHash=//p')" != "$(codesign -dvvv "$B" 2>&1 | sed -n 's/^CDHash=//p')" ]] && ok=1 || ok=0
check "The two builds really are different code" $ok "both builds have the same CDHash"
satisfies "$B" "$REQ_A" && ok=1 || ok=0
check "$NEW satisfies the requirement macOS stored for $OLD (permissions carry over)" $ok "codesign --verify -R failed"
satisfies "$A" "$REQ_B" && ok=1 || ok=0
check "$OLD satisfies the requirement of $NEW (a downgrade keeps them too)" $ok "codesign --verify -R failed"
codesign --verify --deep --strict "$B" 2>"$OUT/verify.log" && ./scripts/signing-identity.sh requirement "$B" >/dev/null 2>&1 && ok=1 || ok=0
check "The signature is valid and passes the release workflow's check" $ok "$(cat "$OUT/verify.log")"

echo "▶ launching the signed build"
"$B/Contents/MacOS/Burrow" -BurrowSetup welcome >/dev/null 2>&1 &
APP_PID=$!; sleep 4
kill -0 $APP_PID 2>/dev/null && ok=1 || ok=0
check "macOS runs the signed build" $ok "the app exited within 4 seconds"
kill $APP_PID 2>/dev/null

echo "▶ the same builds, signed ad-hoc"
for app in "$A" "$B"; do rm -rf "${app:r}-adhoc.app"; cp -R "$app" "${app:r}-adhoc.app"; codesign --force --deep --sign - "${app:r}-adhoc.app" 2>/dev/null; done
ADHOC_A=$(requirement "${A:r}-adhoc.app"); ADHOC_B=$(requirement "${B:r}-adhoc.app")
[[ "$ADHOC_A" == cdhash* && "$ADHOC_A" != "$ADHOC_B" ]] && ! satisfies "${B:r}-adhoc.app" "$ADHOC_A" && ok=1 || ok=0
check "Ad-hoc builds do not satisfy each other's requirement (the old behaviour)" $ok "$OLD: $ADHOC_A | $NEW: $ADHOC_B"
./scripts/signing-identity.sh requirement "${B:r}-adhoc.app" >/dev/null 2>&1 && ok=0 || ok=1
check "The release workflow's check rejects an ad-hoc build" $ok "signing-identity.sh requirement accepted it"
satisfies "${B:r}-adhoc.app" "$REQ_A" && ok=0 || ok=1
check "An ad-hoc build with Burrow's bundle id does not inherit the permissions" $ok "it satisfied $REQ_A"

cleanup
[[ "$(security list-keychains -d user)" == "$SEARCH_BEFORE" ]] && ok=1 || ok=0
check "The keychain search list is left as it was" $ok "$(security list-keychains -d user | tr '\n' ' ')"

python3 - "$OUT" "$REQ_A" "$ADHOC_A" "$ADHOC_B" <<'PY'
import html, json, sys
out, req, adhoc_a, adhoc_b = sys.argv[1:5]
rows = [line.rstrip("\n").split("\t") for line in open(f"{out}/results.tsv")]
results = [{"result": r[0], "check": r[1], "detail": r[2] if r[0] == "FAIL" else ""} for r in rows]
passed = sum(r["result"] == "PASS" for r in results)
json.dump({"passed": passed, "total": len(results), "requirement": req,
           "adHocRequirements": [adhoc_a, adhoc_b], "results": results},
          open(f"{out}/results.json", "w"), indent=2)
body = "".join(f"<tr class={r['result'].lower()}><td>{r['result']}</td><td>{html.escape(r['check'])}"
               f"{'<br><small>' + html.escape(r['detail']) + '</small>' if r['detail'] else ''}</td></tr>" for r in results)
open(f"{out}/index.html", "w").write(f"""<!doctype html><meta charset=utf-8><title>Burrow signing E2E</title>
<style>body{{font:14px -apple-system,sans-serif;margin:32px;max-width:900px}}td{{padding:6px 10px;border-bottom:1px solid #8883;vertical-align:top}}
.pass td:first-child{{color:#1a7f37;font-weight:600}}.fail td:first-child{{color:#cf222e;font-weight:600}}code{{font:12px ui-monospace,monospace;word-break:break-all}}</style>
<h1>Privacy permissions across updates: {passed}/{len(results)} passed</h1>
<p>Requirement shared by both signed builds:<br><code>{html.escape(req)}</code></p>
<p>The same builds signed ad-hoc:<br><code>{html.escape(adhoc_a)}</code><br><code>{html.escape(adhoc_b)}</code></p>
<table>{body}</table>""")
print(f"{passed}/{len(results)} passed · {out}/index.html")
PY
exit $FAILED
