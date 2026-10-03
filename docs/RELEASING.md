# Releasing Burrow

Pushing a version tag (`v1.2.3`, or `v1.3.0-beta.1` for a pre-release) runs `.github/workflows/release.yml`. It builds the app and the DMG, signs the DMG for in-app updates, and publishes a GitHub Release with three assets:

| Asset | What it is |
|---|---|
| `Burrow-<version>.dmg` | The disk image people download and the in-app updater installs. |
| `Burrow-<version>.dmg.sha256` | The checksum for manual verification (docs/INSTALL.md). |
| `Burrow-<version>.dmg.sig` | The base64 Ed25519 signature of the DMG, used by the in-app updater. |

```bash
git tag v1.1.0
git push origin v1.1.0
```

The version comes from the tag. `Resources/Info.plist` does not need to change for a release.

## How in-app updates work

Burrow checks `api.github.com/repos/Pimzino/burrow/releases/latest` once a day, and when the user chooses **Check for Updates…**. With **Include pre-releases** on, it checks the full release list instead. When a newer version is found, Burrow:

1. downloads the DMG and its `.sig` and checks the DMG's size and GitHub's SHA-256 `digest`,
2. verifies the **Ed25519 signature** of the whole DMG against `BurrowUpdatePublicKey` in its own Info.plist,
3. mounts the DMG and copies `Burrow.app` next to the running app, then checks the copy:
   - same bundle identifier
   - exactly the release's version, and newer than the running one
   - valid code signature
   - same team identifier, when the running app has one
4. swaps the new bundle in atomically. If the folder needs an administrator, macOS asks for approval.
5. quits, and a detached helper reopens the new version.

The signature is the anchor of trust. Releases are not notarized and are often signed ad-hoc, so the code signature alone can't tell a genuine build from a forged one. A release without a `.sig`, or a build without a public key, is offered only as a link to the release page and is never installed in place.

## The signing key

The private key lives in two places: the `BURROW_UPDATE_SIGNING_KEY` repository secret (CI signs with it) and the maintainer's login Keychain (`io.github.pimzino.burrow.update-signing`). The public key is `BurrowUpdatePublicKey` in `Resources/Info.plist`.

**One-time setup** (already done for this repository's current key, except the secret):

```bash
swift scripts/update-signing.swift generate          # stores the key in the Keychain, prints the public key
# put the printed public key in Resources/Info.plist as BurrowUpdatePublicKey
swift scripts/update-signing.swift export-private-key | gh secret set BURROW_UPDATE_SIGNING_KEY -R Pimzino/burrow
```

The release workflow refuses to publish when Info.plist has a public key but the secret is missing or doesn't match it. Without that check, a release could be published that installed copies cannot update to.

**Keep a backup of the private key** (for example in a password manager). If it is lost, the copies people have installed can no longer update in place. You would ship a new key in a release, and users would have to download that release by hand once. Never commit the key. If it leaks, rotate it the same way and say so in the release notes.

Other commands:

```bash
swift scripts/update-signing.swift public-key                        # the public key of the Keychain key
swift scripts/update-signing.swift sign build/Burrow-1.1.0.dmg       # prints a signature
swift scripts/update-signing.swift verify FILE FILE.sig PUBLIC_KEY   # checks one
```

## Testing the updater

`scripts/update-e2e.sh` runs the whole flow against a local stand-in for the GitHub API, with a throwaway key and a separate bundle id (your real Burrow settings are untouched). It builds versions 1.0.0 and 1.1.0, packages 1.1.0 as a real DMG, and checks that:

- an up-to-date check downloads nothing
- an unsigned release is offered but not installed
- a bad checksum, a tampered DMG, a signature from the wrong key, and a DMG of a different app are all refused, and the installed app is left untouched
- a valid update is swapped in, the old version quits, and the new one relaunches

It writes `e2e-results/update-<timestamp>/index.html` with the results, the requests the fake server received, and captures of the Software Update window and Settings. `UPDATE_E2E_SYSTEM_APPLICATIONS=1` also runs the valid update from `/Applications/Burrow E2E.app`, which it removes afterwards.
