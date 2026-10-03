# Contributing to Burrow

Thanks for helping. Burrow is a native SwiftUI front end for the [Mole](https://github.com/tw93/mole) CLI. Before you start, read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (code layout and rules) and the section of [`docs/mole-cli-research.md`](docs/mole-cli-research.md) for any `mo` command you touch.

## Requirements

- macOS 26 or later on Apple silicon
- Xcode 26 or later (Swift 6.2+, macOS 26 SDK)
- The Mole CLI: `brew install mole`
- No other dependencies. Burrow uses only Apple frameworks; please don't add Swift packages. If you think one is truly needed, open an issue first.

## Build and run

```bash
swift build                          # debug binary: .build/debug/Burrow (runs without a bundle)
./scripts/build-app.sh debug         # build/Burrow.app
open build/Burrow.app
./scripts/make-dmg.sh 0.0.0-dev      # build/Burrow-0.0.0-dev.dmg (optional)
```

`build-app.sh` signs with your **Apple Development** certificate if Xcode has one (Xcode → Settings → Accounts), so macOS privacy permissions survive rebuilds. Without one it signs ad-hoc and macOS asks for permissions again after every build. Set `MOLE_SIGN_IDENTITY` to choose an identity, or `-` for ad-hoc.

The build must finish with **zero errors and zero warnings** (Swift 6 language mode).

## End-to-end tests

Burrow is tested end to end, in the real app against the real Mole:

```bash
./scripts/e2e.sh                        # every screen and every Settings tab
./scripts/e2e.sh clean uninstall        # just some screens
./scripts/update-e2e.sh                 # Burrow's in-app updater, against a local fake GitHub API
```

Each screen is launched with its **safe** automated action only (a scan, a dry run or a listing) and writes an automation report. The script captures screenshots and writes `e2e-results/<timestamp>/index.html` and `summary.json`. Please attach the summary (and relevant screenshots) to your pull request. Screenshots are best-effort: pass or fail comes from each screen's report.

To look at one screen: `scripts/shot.sh .build/debug/Burrow <route> out.png [wait] [YES|NO autorun]`.

## Safety rules (please read)

Burrow can delete files. These rules are not negotiable:

1. **Never automate a destructive action.** Automation and E2E code may only start scans, dry runs (`--dry-run`), listings (`--list`) and JSON reports (`--json`). Never add an autorun that cleans, uninstalls, purges, optimizes, removes installers, or changes Touch ID, shell config or Mole itself.
2. **Test with dry runs.** When you develop a destructive flow, exercise it with Mole's `--dry-run` first, and only run the real thing on a test account or a disposable VM. Never test on files you care about.
3. **Confirm first.** Every destructive `mo` command needs an in-app confirmation that lists exactly what will happen. Return must never confirm a destructive action.
4. **Respect EOF-means-yes prompts.** Some Mole prompts treat end-of-input as "confirm". Runs that reach such a prompt must use `keepInputOpen: true` and answer deliberately. See the research doc.
5. **Admin only when needed.** Pass `admin: true` only for work that truly needs `sudo`. Never ask for, store or log a password yourself; use the existing `AuthCoordinator` flow.
6. **Don't touch `Core/PrivilegedHelper.swift`** without discussing it in an issue first.
7. **Prefer the Trash** wherever Mole offers it.

## Style

- Swift 6 language mode; UI state types are `@MainActor @Observable`.
- Liquid Glass, SF Symbols and system fonts; every screen needs empty, loading, error and success states.
- Parsers are pure types in the feature's folder and parse Mole's output line by line as it streams.
- User-facing text: say **Burrow** for the app and **Mole** for the CLI and what it does. Friendly, plain language.

## Pull requests

- Keep each pull request focused on one change.
- Describe what changed and why, how you tested it (E2E routes, dry runs), and include screenshots for UI changes.
- By contributing, you agree that your work is licensed under the [GPL-3.0](LICENSE), like the rest of Burrow.

## Reporting bugs and security issues

Use the issue templates for bugs and feature requests. Report security problems privately, as described in [SECURITY.md](SECURITY.md).
