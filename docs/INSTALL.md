# Installing Burrow

Burrow needs **macOS 26 (Tahoe) or later on a Mac with Apple silicon**, and the **Mole CLI** (Burrow can install Mole for you, see [below](#the-mole-cli)).

## Why macOS warns you about Burrow

Apple only lets an app open without warnings if it is signed with a paid **Developer ID** certificate and **notarized** (scanned by Apple). Burrow is a free, independent project without a paid Apple Developer Program membership, so release builds are signed ad-hoc or with a development certificate, and they are **not notarized**.

When you open Burrow for the first time, Gatekeeper cannot verify it and blocks it. This is expected. You approve it once, and after that it opens normally.

On macOS 15 Sequoia and later, including macOS 26, the old shortcut (Control-click or right-click the app, then choose **Open**) **no longer bypasses Gatekeeper**. Apple removed it in Sequoia. You now approve the app in System Settings, as described below.

## 1. Download and check the file

1. Download `Burrow-<version>.dmg` and `Burrow-<version>.dmg.sha256` from the [Releases page](https://github.com/Pimzino/burrow/releases). Only download Burrow from there.
2. Optionally, check that the download is intact and matches the published checksum. In Terminal, in your Downloads folder:

   ```bash
   cd ~/Downloads
   shasum -a 256 -c Burrow-<version>.dmg.sha256
   ```

   It should print `Burrow-<version>.dmg: OK`. If it prints `FAILED`, delete the file and download it again. You can also compare by eye: `shasum -a 256 Burrow-<version>.dmg` must print the same hash as the release page and the `.sha256` file.

The checksum proves the file is the one published with the release. It does not replace Apple's notarization; it only tells you nothing changed in transit.

## 2. Install

1. Double-click `Burrow-<version>.dmg` to open it.
2. Drag **Burrow** onto the **Applications** folder in the window.
3. Eject the disk image (the eject button next to "Burrow" in the Finder sidebar).

## 3. Open Burrow the first time (System Settings method, recommended)

1. Open **Applications** and double-click **Burrow**.
2. macOS shows a dialog titled **"Burrow" Not Opened**, saying that Apple could not verify "Burrow" is free of malware that may harm your Mac or compromise your privacy. Click **Done**. Do not click **Move to Trash**.
3. Open **System Settings** (Apple menu → System Settings) and click **Privacy & Security** in the sidebar.
4. Scroll down to the **Security** section. You will see a message that **"Burrow" was blocked to protect your Mac**, with an **Open Anyway** button. Click **Open Anyway**.
   - The button appears only after you have tried to open Burrow, and Apple says it stays available for about an hour. If you don't see it, repeat step 1 and come back.
5. macOS asks again whether you want to open Burrow. Click **Open Anyway**.
6. Enter your Mac login password (or use Touch ID) to confirm.

Burrow opens. macOS saves it as an exception to your security settings, so from now on it opens with a normal double-click.

After you install a **new version** of Burrow, macOS may ask you to repeat these steps once, because the new build has a different signature.

## Alternative: remove the quarantine flag in Terminal

If you prefer Terminal, or the System Settings button does not appear, you can remove the quarantine flag instead:

```bash
xattr -dr com.apple.quarantine /Applications/Burrow.app
```

What this does:

- When a browser downloads a file, macOS attaches an extended attribute called `com.apple.quarantine` to it, and copies it onto the app when you drag it out of the disk image. Gatekeeper checks an app only when it has this flag.
- `xattr -d` deletes that attribute. `-r` does it for every file inside `Burrow.app`.
- Without the flag, macOS treats Burrow like software you built yourself: it opens without the Gatekeeper check or any dialog.

The trade-off:

- You skip Gatekeeper's check for this app entirely, including the malware check it would otherwise attempt. Only do this for a file you have verified (step 1) and that came from the official Releases page.
- It does not change any system-wide setting. It affects only this copy of Burrow, and the next version you download is quarantined and checked again.
- You do not need `sudo`. Never disable Gatekeeper globally (`spctl --master-disable`) to run Burrow.

## 4. Permissions Burrow asks for

Burrow asks for access only when a feature needs it. You can review or change any of these later in **System Settings → Privacy & Security**.

| Permission | Where | Why |
|---|---|---|
| **Full Disk Access** (recommended) | Privacy & Security → Full Disk Access → add **Burrow** | Mole runs inside Burrow and inherits its access. Without it, macOS hides Mail, Safari, Messages, `~/Library/CloudStorage`, the Trash and similar locations, so Clean, Analyze and Purge see less and report smaller sizes. Burrow shows a banner with a button to this pane when access is missing. Quit and reopen Burrow after granting it. |
| **Files and Folders** (Desktop, Documents, Downloads, removable and network volumes) | Asked the first time, or Privacy & Security → Files & Folders | Installers and Project Purge look for old installers and build folders in these places. Analyze can measure external and network drives. Not needed if you grant Full Disk Access. |
| **Automation → Finder** | Asked the first time, or Privacy & Security → Automation → Burrow | Burrow asks Finder for accurate free-space figures, and Burrow and Mole use Finder to move items to the Trash (so you can put them back). |
| **Administrator password** | A Burrow sheet when needed | Only for system-level tasks such as Optimize, cleaning system caches, Touch ID for sudo, or uninstalling root-owned apps. The password goes straight to `sudo` and is never stored. See [SECURITY.md](../SECURITY.md). |

Privacy permissions are tied to the app's signature. Because Burrow is not signed with a Developer ID, macOS may ask for some permissions again after you update Burrow.

## The Mole CLI

Burrow is a front end: all the actual work is done by the open-source [Mole](https://github.com/tw93/mole) CLI (`mo`).

- **Let Burrow install it.** If Mole is missing, Burrow's welcome screen offers **Install Now**, which runs `brew install mole` for you and shows the output. This needs [Homebrew](https://brew.sh).
- **Or install it yourself** in Terminal:

  ```bash
  brew install mole
  ```

  Then click **Check Again** in Burrow. Mole's own install script from its GitHub page also works; Burrow finds `mo` in the usual locations and you can set its path in **Settings → General**.
- **Updates.** Burrow tells you when a new Mole version is available and can update it from **Settings → Updates**.

## Updating Burrow

Burrow checks its GitHub Releases once a day (you can turn this off, or include pre-releases, in **Settings → Updates**). You can also check any time with **Burrow → Check for Updates…**. When a new version is out, Burrow shows its release notes. **Install and Relaunch** then:

- downloads the new disk image
- checks that it is signed with Burrow's release key
- replaces the app in place and reopens it

You don't need to repeat the Gatekeeper steps above, because an update installed this way isn't quarantined. If Burrow lives in a folder that only an administrator can change, macOS asks for an administrator's approval.

In-place updates need Burrow to run from a normal folder such as Applications. They don't work if it runs from the disk image, or from the temporary location macOS uses for apps it hasn't approved yet. In those cases Burrow links to the download instead.

## Uninstalling Burrow

Quit Burrow (menu bar icon → Quit Burrow) and move `/Applications/Burrow.app` to the Trash. This does not remove Mole. To remove Mole too, use **Settings → Uninstall Mole** first, or run `brew uninstall mole`.
