#!/bin/zsh
# Burrow's release signing identity: a self-signed code-signing certificate that every release is signed
# with, so macOS keeps Burrow's privacy permissions (Full Disk Access, Files & Folders, Automation)
# across updates.
#
# macOS ties a permission to the app's designated requirement. An ad-hoc signature's requirement is the
# hash of that one build, so every update is a different app to macOS and it asks again. With a
# certificate the requirement is `identifier "io.github.pimzino.burrow" and certificate leaf = H"…"`,
# which every build signed with the same certificate satisfies. The certificate needs no Apple Developer
# Program membership and changes nothing about Gatekeeper: releases stay un-notarized.
#
#   scripts/signing-identity.sh create               make the identity (once per project, not per release)
#   scripts/signing-identity.sh install              rebuild the signing keychain from the login Keychain
#   scripts/signing-identity.sh unlock               unlock the signing keychain, print the SHA-1 to sign with
#   scripts/signing-identity.sh fingerprint          print the certificate's SHA-1
#   scripts/signing-identity.sh set-github-secrets [owner/repo]
#                                                    store it as MACOS_CERT_P12_BASE64 / MACOS_CERT_PASSWORD
#   scripts/signing-identity.sh requirement APP      print APP's designated requirement; fails if it is
#                                                    ad-hoc (tied to one build)
#
# Where it lives: the certificate and private key (a base64 .p12) and a random password are kept in the
# login Keychain under the service io.github.pimzino.burrow.code-signing. codesign reads identities from
# keychain files, so they are also imported into ~/Library/Keychains/burrow-signing.keychain-db, which is
# locked with that password and added to the keychain search list. The pinned SHA-1 is in
# Resources/release-signing.sha1; the release workflow refuses to publish a build signed with anything else.
#
# BURROW_SIGNING_KEYCHAIN and BURROW_SIGNING_SERVICE override the keychain file and the service
# (scripts/signing-e2e.sh uses throwaway ones).
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE="${BURROW_SIGNING_SERVICE:-io.github.pimzino.burrow.code-signing}"
KEYCHAIN="${BURROW_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/burrow-signing.keychain-db}"
COMMON_NAME="Burrow Release Signing (self-signed)"
PIN_FILE="Resources/release-signing.sha1"
OPENSSL=/usr/bin/openssl   # the system LibreSSL writes a .p12 that `security import` reads

fail() { echo "error: $*" >&2; exit 1; }
secret() { security find-generic-password -s "$SERVICE" -a "$1" -w 2>/dev/null; }
store() { security add-generic-password -U -s "$SERVICE" -a "$1" -l "Burrow release signing ($1)" -T /usr/bin/security -w "$2"; }
search_list() { security list-keychains -d user | sed 's/^ *"//; s/"$//'; }

fingerprint() {
  local sha
  sha=$(security find-certificate -c "$COMMON_NAME" -Z "$KEYCHAIN" 2>/dev/null | awk '/^SHA-1 hash:/ {print $3; exit}')
  [[ -n "$sha" ]] || fail "no signing identity in $KEYCHAIN (run: scripts/signing-identity.sh create)"
  echo "$sha"
}

# Builds the keychain file from the .p12 in the login Keychain and puts it on the search list.
install() {
  local p12b64 password work
  p12b64=$(secret p12) || fail "no signing identity in the login Keychain (run: scripts/signing-identity.sh create)"
  password=$(secret password) || fail "the signing identity's password is missing from the login Keychain"
  work=$(mktemp -d); trap "rm -rf '$work'" EXIT
  echo "$p12b64" | base64 --decode > "$work/identity.p12"

  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  security create-keychain -p "$password" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # no auto-lock timeout; `unlock` runs before every use anyway
  security unlock-keychain -p "$password" "$KEYCHAIN"
  security import "$work/identity.p12" -k "$KEYCHAIN" -P "$password" -f pkcs12 -T /usr/bin/codesign >/dev/null
  # Let codesign use the key without a prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" >/dev/null
  # codesign only finds identities in keychains on the search list. Keep the existing ones, in order.
  local -a current; current=("${(@f)$(search_list)}")
  if (( ! ${current[(Ie)$KEYCHAIN]} )); then security list-keychains -d user -s "${current[@]}" "$KEYCHAIN"; fi
}

case "${1:-}" in
  create)
    if secret p12 >/dev/null; then
      fail "a signing identity already exists. Replacing it makes macOS ask every user for their permissions again, so this script never does it; delete the '$SERVICE' items from the login Keychain first if you really mean to."
    fi
    work=$(mktemp -d); trap "rm -rf '$work'" EXIT
    password=$($OPENSSL rand -base64 24)
    cat > "$work/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $COMMON_NAME
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    # 20 years: a new certificate is a new identity to macOS, so it should outlive the project's releases.
    $OPENSSL req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$work/openssl.cnf" \
      -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    $OPENSSL pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$COMMON_NAME" \
      -passout "pass:$password" -out "$work/identity.p12"
    store password "$password"
    store p12 "$(base64 -i "$work/identity.p12")"
    rm -rf "$work"; trap - EXIT
    install
    sha=$(fingerprint)
    if [[ -z "${BURROW_SIGNING_SERVICE:-}" ]]; then echo "$sha" > "$PIN_FILE"; fi
    echo "Created \"$COMMON_NAME\" ($sha)." >&2
    echo "Back up the login Keychain items named '$SERVICE': if they are lost, the next release has a new identity and macOS asks everyone for permissions once more." >&2
    echo "$sha"
    ;;
  install)
    install
    fingerprint
    ;;
  unlock)
    [[ -f "$KEYCHAIN" ]] || fail "no signing keychain at $KEYCHAIN"
    password=$(secret password) || fail "the signing identity's password is missing from the login Keychain"
    security unlock-keychain -p "$password" "$KEYCHAIN"
    fingerprint
    ;;
  fingerprint)
    fingerprint
    ;;
  set-github-secrets)
    repo="${2:-Pimzino/burrow}"
    p12b64=$(secret p12) || fail "no signing identity in the login Keychain"
    password=$(secret password) || fail "the signing identity's password is missing from the login Keychain"
    printf '%s' "$p12b64" | gh secret set MACOS_CERT_P12_BASE64 -R "$repo"
    printf '%s' "$password" | gh secret set MACOS_CERT_PASSWORD -R "$repo"
    ;;
  requirement)
    app="${2:-}"; [[ -d "$app" ]] || fail "usage: signing-identity.sh requirement APP"
    requirement=$(codesign -d -r- "$app" 2>/dev/null | sed -n 's/^.*designated => //p')
    [[ -n "$requirement" ]] || fail "$app has no designated requirement (is it signed?)"
    echo "$requirement"
    if [[ "$requirement" == cdhash* ]]; then
      fail "$app is ad-hoc signed: macOS will ask for its privacy permissions again after every update"
    fi
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
