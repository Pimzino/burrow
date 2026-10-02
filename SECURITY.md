# Security

Burrow drives the Mole CLI, which can delete files and change system settings. This page explains how Burrow handles administrator access and how to report a vulnerability.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

- Report it privately through GitHub: on [github.com/Pimzino/burrow](https://github.com/Pimzino/burrow), open the **Security** tab and click **Report a vulnerability**.
- Include the Burrow version (Settings → About), the Mole version (`mo --version`), your macOS version, and steps to reproduce.
- You should get a reply within a week. Fixes are released as a new version, and the advisory is published once users have had time to update.

If the problem is in the Mole CLI itself (for example, `mo clean` removing something it should not), please report it to Mole following [its security policy](https://github.com/tw93/mole/security), and let us know if Burrow makes it worse.

Only the latest release of Burrow receives security fixes.

## How administrator access works

Mole takes administrator rights only through a `sudo` credential cached for a terminal. Burrow never runs as root and never installs a privileged helper, daemon or launch agent. For the few tasks that need `sudo` (a real Optimize, cleaning system caches, Touch ID for sudo, uninstalling root-owned apps, and updating or removing a Mole installed in a root-owned folder), Burrow re-launches its own executable in a small helper mode for that one task:

1. The helper becomes the session leader of a new, private pseudo-terminal, so the credential `sudo` caches belongs only to that session.
2. It runs `sudo -v`. The password prompt appears in Burrow's own sheet, which names the task.
3. It runs Mole inside that session.
4. When Mole exits, it runs `sudo -k` to revoke the credential.

Your password:

- is written directly to `sudo` on the private pseudo-terminal
- is never stored, logged, put in an environment variable or on a command line, or sent anywhere
- is cleared from the sheet when you submit or cancel

If you have enabled Touch ID for sudo, macOS shows its own Touch ID prompt first.

## Other safeguards

- **Nothing destructive without confirmation.** Every destructive action has a confirmation that lists what will happen. Where Mole prints its own plan (uninstall, installers, Mole removal), Burrow checks that plan against your selection and declines Mole's prompt if they differ.
- **Supervised prompts.** Several Mole prompts treat end-of-input as "yes". For those runs, the helper owns Mole's input and stops Mole if Burrow goes away, so a crash or force-quit never confirms anything.
- **Previews are binding.** Clean runs only the configuration you previewed; Purge re-checks just before running.
- **Trash first.** Burrow prefers the Trash wherever Mole offers it. The analyzer applies Mole's own protected-path rules before moving anything to the Trash.
- **Minimal networking.** Burrow's only request of its own is an anonymous check of Mole's latest release on the GitHub API (`api.github.com/repos/tw93/mole/releases/latest`). It sends no data about your Mac. Mole contacts GitHub or Homebrew when you update or install it.

## Code signing

Release builds are not notarized. See [docs/INSTALL.md](docs/INSTALL.md) for why, and for how to verify a download with the published SHA-256 checksum.
