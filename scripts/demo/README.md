# Demo Mole

A stand-in `mo` launcher that lets Burrow run with dummy data. Use it for the README screenshots
(`scripts/screenshots.sh` uses it automatically), demos and recordings, so no capture shows the real
Mac's apps, files, history, processes, devices or addresses.

```sh
build/Burrow.app/Contents/MacOS/Burrow -moleLauncherPath "$PWD/scripts/demo/mo" -BurrowPrivacyMode YES
```

`-moleLauncherPath` is a launch argument, so it only lasts for that launch and never changes the
launcher saved in Settings. The real Mole must be installed with Homebrew: Burrow still loads Mole's
libraries (Protection inventory, Optimize catalog) from the real install, and `scripts/demo/mo` names
`/opt/homebrew/opt/mole/libexec/mole` literally so Burrow's `MoleLocator` can find them.

## It never changes anything

Every command that could change the Mac is refused (exit 1, with a message on stderr) unless it is
a preview, a listing or a status query:

| Command | Demo behaviour |
|---|---|
| `--version`, `--help` | Real Mole |
| `status …` (incl. `--watch`, `--json`) | Real Mole, each JSON line anonymised: host `My Mac`, generic process names, generic Bluetooth devices, `192.168.1.x` addresses, no proxy host, external disks shown as `/Volumes/Backup` |
| `clean --dry-run` | Replays `fixtures/clean-dry-run.txt` (~30 s) and writes the matching preview file to `$TMPDIR/burrow-demo/clean-list.txt`. When `$TMPDIR/burrow-demo/clean-variant` contains `system` it replays `fixtures/clean-dry-run-system.txt` instead: a scan that includes system caches, where Mole prints a row without a size and counts some paths under another section |
| `clean --external … --dry-run` | Real Mole (read-only dry run) |
| `optimize --dry-run` | Replays `fixtures/optimize-dry-run.txt` (a recorded real dry run with generic process names) |
| `purge --dry-run` | Replays `fixtures/purge-dry-run.txt` |
| `installer --dry-run` | Emulates Mole's key-driven selector over stdin with five dummy installers. Burrow can't find those files on disk, so it lists them under "Unknown" and won't offer to remove them |
| `uninstall --list` | `fixtures/uninstall-list.json` (real `/Applications` paths where the app is installed, so icons render) |
| `uninstall --dry-run …` | Real Mole (dry run) |
| `history [--json] [--limit N]` | 40 sessions and their deletion records over the past ~3 weeks, generated relative to now |
| `analyze --json [PATH]` | Overview fixture, `fixtures/analyze-projects.json` for any folder named `Projects`, and a small deterministic listing for other folders |
| `touchid status`, `touchid … --dry-run`, `completion --dry-run`, `remove --dry-run` | Real Mole |
| Anything else (real `clean`/`optimize`/`purge`/`installer`/`uninstall`, `update`, `remove`, `--whitelist`, `purge --paths`, the main menu, the analyze TUI) | Refused |

Nothing here writes outside `$TMPDIR/burrow-demo/`; it never touches `~/.config/mole` or `~/.cache/mole`.

Burrow still reads a few things from the real Mac directly, not through `mo`: Mole's whitelist files
(Protection), app icons and last-used dates (Uninstall, from Mole's metadata cache) and the update
notice. Check captures before publishing them.

## Files

- `mo`: the launcher (bash). Decides what is allowed and dispatches.
- `lib/demo.py`: status anonymiser, paced replays, history and analyze generators, installer selector
  emulation. Python 3 standard library only.
- `fixtures/`: static data. Paths use the dummy home `/Users/demo`.
