# core+clean

# Mole v1.56.0 research report: dispatcher, lib/core and `mo clean` for a SwiftUI GUI

**Scope and method.** I read the source under `/opt/homebrew/Cellar/mole/1.56.0/libexec`, and another agent's clone of the V1.56.0 tag (`mole-src/`, commit `239c90d`) for upstream docs. I then ran only safe commands: `--version`, `--help`, bare `mo` with stdin `</dev/null`, `mo history --json`, `mo clean --dry-run` (three ways), `mo clean --external … --dry-run`, and argument-error cases. Nothing was deleted, and no sudo was used.

Captured files are in `<scratch>/research/`:
- `clean_dryrun.stdout` / `.stderr` / `.exit`: piped run, stdin `/dev/null`. Exit 0, took 141 s, stderr empty.
- `clean_dryrun_clean-list.txt`: copy of the preview file written by that run (718 lines).
- `clean_dryrun_pty.raw`: the same dry run under a PTY (`script -q`, `TERM=xterm-256color`), with the real ANSI codes and spinner frames. Exit 0.
- `clean_dryrun_debug.stdout` / `.stderr`: `--dry-run --debug`, piped. Exit 0; 453 stderr lines of `[DEBUG]` output.
- `clean_external_dryrun.stdout`: `--external "/Volumes/Backup" --dry-run`. Exit 1 (explained in §6).

---

## Findings a GUI implementer must know first

1. **A real (non-dry-run) `mo clean` with stdin that is not a TTY asks for no confirmation and deletes straight away.** It prints `Running in non-interactive mode` and proceeds (`bin/clean.sh:1607-1618`). No `--yes` is needed or exists. The GUI must show its own confirmation before spawning it.
2. **Colours turn off automatically when stdout is not a TTY** (`lib/core/base.sh:33-40`). When stdout is a pipe you also get no spinners, no cursor codes and no idle-section line recycling. So piped stdout is plain UTF-8 text with icon glyphs. The one exception is the bare `mo` main menu, which prints cursor escapes regardless (§3).
3. **Sudo.** `mo clean` never prompts for a password when stdin is not a TTY. It only adopts an already-cached sudo timestamp (`sudo -n -v`), and every privileged operation uses `sudo -n`. With sudoers' default `timestamp_type=tty` and no terminal, sudo keys the cache on the parent PID. A GUI's own `sudo -v` therefore will not carry over to Mole's many sub-process `sudo -n` calls. Workable designs are in §5.
4. **There is no JSON output for `clean`.** The machine-readable sources are:
   - the preview file `~/.config/mole/clean-list.txt` (dry run only);
   - the operations log `~/Library/Logs/mole/operations.log`;
   - `mo history --json`.
5. **`clean` also empties the Trash** unless `~/.Trash` is whitelisted or `MOLE_SKIP_TRASH_CLEANUP=1` is set (`lib/clean/user.sh:217`).

---

## 1. Dispatcher `libexec/mole` (`/opt/homebrew/bin/mo`)

- **Refuses root.** `EUID==0` prints `Run Mole without sudo; it requests administrator access when needed.` to stderr and exits 1 (`mole:10-13`). The same check is in `bin/clean.sh:10-13`. Never run `sudo mo …`.
- **Global `--debug`.** It is removed from anywhere in argv (`mole_collect_cli_args`, `mole:59-75`) and `export MO_DEBUG=1` is set before `exec`. Both `mo --debug clean` and `mo clean --debug` work.
- **`history`** is dispatched early, before `common.sh` loads (`mole:77-89`), and execs `bin/history.sh`.
- **Routing** (`mole:268-354`). Each of these is `exec`'d, so the PID is preserved:
  - `optimize|optimise`, `clean`, `uninstall`, `analyze|analyse`, `status`, `purge`, `installer`, `touchid` and `completion` go to `bin/<name>.sh`.
  - `update [--force|-f] [--nightly]` runs in-process. Never run it.
  - `remove [--dry-run|-n]` runs in-process. Never run it.
  - `help|--help|-h`, `version|--version|-V`, and empty argv (main menu).
  - Unknown commands print `Unknown command: X` and `Use 'mole --help' for usage information.` to stderr and exit 1.
- **Exit-time cleanup.** `trap cleanup_temp_files EXIT INT TERM` is installed at `mole:95`.

### `mo --version` (observed, piped)

Output starts with an empty line, then ends with a trailing blank line:
```

Mole version 1.56.0
macOS: 26.6.2
Architecture: arm64
Kernel: 25.6.0
SIP: Enabled
Disk Free: 94.20GB
Install: Homebrew
Shell: /bin/zsh

```
- Source is `lib/manage/update.sh:910-964`. On the nightly channel a `Channel: Nightly (<commit>)` line is added after the version.
- Parse the version with the regex `^Mole version (\S+)`.
- Disk Free uses decimal units (see `bytes_to_human` in §4).
- Exit code is 0.

### `mo --help`

Prints the banner, then `COMMANDS` / `OPTIONS` tables. The format is `printf "  %s%-28s%s %s\n"` (`update.sh:966-996`), and the command list comes from `lib/core/commands.sh`. Exit code is 0.

---

## 2. Global environment variables (scope: dispatcher, core, clean, whitelist)

**Colour and debug**

| Var | Effect |
|---|---|
| `NO_COLOR` (non-empty) | Disables ANSI colours; checked first (`base.sh:34`). |
| `TERM=dumb` | Disables colours; `is_ansi_supported` is false (`base.sh:1330-1370`). |
| `MO_DEBUG=1` | Same as `--debug`. Writes `[DEBUG] …` lines to stderr and resets/appends `~/Library/Logs/mole/mole_debug_session.log`. Adds `[TIMEOUT] …` stderr lines from `timeout.sh`. The summary block adds `Debug session log saved to: <path>`. |

**Logging**

| Var | Effect |
|---|---|
| `MO_NO_OPLOG=1` | Disables `operations.log` writing (`log.sh:32,205`). |
| `MOLE_OPERATIONS_LOG` | Overrides the log path read by `mo history` only (`history.sh:55`). |
| `MOLE_DELETE_LOG` | Overrides the path of `deletions.log` (`file_ops.sh:3082`). |

**Clean behaviour**

| Var | Effect |
|---|---|
| `MOLE_DRY_RUN=1` | Equivalent to `--dry-run` for clean (`clean.sh:33`). |
| `MOLE_SKIP_TRASH_CLEANUP=1` | Clean does not empty `~/.Trash`. |
| `MOLE_EXTERNAL_VOLUMES_ROOT` | Root for `--external` (default `/Volumes`) (`user.sh:1425`). |
| `MOLE_EXTERNAL_VOLUME_SCAN_TIMEOUT` | External metadata `find` timeout (default 15 s). |
| `MOLE_CLOUD_OFFICE_SECTION_BUDGET_SEC` | Wall-clock budget for the "Cloud & Office" section (default 300). |

**Timeouts** (seconds; from `timeouts.sh:61-68`)

| Var | Default |
|---|---|
| `MOLE_TIMEOUT_QUICK_DETECT_SEC` | 2 |
| `MOLE_TIMEOUT_SHORT_QUERY_SEC` | 3 |
| `MOLE_TIMEOUT_MEDIUM_PROBE_SEC` | 5 |
| `MOLE_TIMEOUT_PKG_LIST_SEC` | 10 |
| `MOLE_TIMEOUT_PKG_CLEANUP_SEC` | 20 |
| `MOLE_TIMEOUT_DISK_VERIFY_SEC` | 30 |
| `MOLE_TIMEOUT_HINT_SCAN_SEC` | 15 |

**Tuning knobs** (defaults in brackets)
- `MOLE_SUPPORT_CACHE_AGE_DAYS`(30), `MOLE_MAIL_AGE_DAYS`, `MOLE_CLAUDE_VM_ORPHAN_AGE_DAYS`(7)
- `MOLE_XCODE_DEVICE_SUPPORT_KEEP`(2), `MOLE_JETBRAINS_TOOLBOX_KEEP`(1), `MOLE_AI_AGENTS_KEEP`(1)
- `MOLE_PROJECT_CACHE_SCAN_TIMEOUT`(6), `MOLE_LARGE_CANDIDATE_SIZE_TIMEOUT`(3), `MOLE_APP_SUPPORT_ITEM_SIZE_TIMEOUT_SEC`(0.4), `MOLE_CONTAINER_CACHE_PRECISE_SIZE_LIMIT`(64)
- `MOLE_EDGE_APP_PATHS`, `MOLE_CHROME_APP_PATHS`, `MOLE_BRAVE_APP_PATHS`, `MOLE_LSREGISTER_PATH`

**Testing and misc**

| Var | Effect |
|---|---|
| `MOLE_TEST_MODE=1` | Forces colours, skips real scans (`clean.sh:1649-1703`), and disables all sudo/osascript. Not useful to a GUI. |
| `MOLE_TEST_NO_AUTH=1` | Refuses every sudo/osascript/Touch ID call and forces colours on (`base.sh:36`). A GUI could set it to guarantee Mole never tries to authenticate, but the colours must then be stripped. |
| `MOLE_TEMP_STALE_MINUTES` | Age at which stale temp files are pruned (default 1440). |
| `TMPDIR` | Temp root; falls back to `~/.cache/mole/tmp` (`base.sh:1016-1060`). |
| `MOLE_PAM_SUDO_FILE`, `MOLE_PAM_SUDO_LOCAL_FILE` | PAM file locations used for Touch ID detection. |

The upstream README documents: `MO_NO_OPLOG=1`, `MOLE_ENABLE_DISK_VERIFY=1` (optimize), `MO_LAUNCHER_APP`, and JSON for `analyze --json`, `status --json` / `--watch` (NDJSON) and `history --json`. It documents no JSON for clean. `mole-src/docs/SECURITY_DESIGN.md` documents `MOLE_TEST_NO_AUTH`.

---

## 3. `mo` with no arguments (main menu), `mole:137-266`

1. `check_for_updates` forks a detached subshell (all fds go to `/dev/null`). It contacts GitHub and Homebrew and writes `~/.cache/mole/update_message`, which is empty or `\nUpdate X available, run mo update\n\n`.
2. `interactive_main_menu` draws the menu, then loops on `read_key`.
   - `read_key` uses `IFS= read -r -s -n 1` on stdin (`ui.sh:167-269`). It returns tokens `UP`/`DOWN`/`ENTER`/`CHAR:1-5`, `MORE` (m), `VERSION` (v), `TOUCHID` (t), `UPDATE` (u), `QUIT` (q, Ctrl-C, or EOF/read failure).
   - Choosing 1-5 `exec`s `bin/clean.sh` / `uninstall.sh` / `optimize.sh` / `analyze.sh` / `status.sh` with no arguments.
3. **Without a TTY** (observed with `</dev/null`): the read fails, becomes `QUIT`, and the process exits 0. It still emits cursor escapes on stdout:
```
^[[H^M^[[2K
^M^[[2K __  __       _      
...
^M^[[2K➤ 1. Clean        Free up disk space
^M^[[2K  2. Uninstall    Remove apps completely
...
^[[J
```
   The control-hint line is printed only when stdin is a TTY (`mole:173-181`).

The GUI should not use the menu. Call the subcommands directly.

---

## 4. lib/core summary

### base.sh

**Colours** (`base.sh:42-64`). They are empty strings when disabled, otherwise:

| Name | Code |
|---|---|
| GREEN | `\e[0;32m` |
| BLUE | `\e[1;34m` |
| CYAN | `\e[0;36m` |
| YELLOW | `\e[0;33m` |
| PURPLE | `\e[0;35m` |
| PURPLE_BOLD | `\e[1;35m` |
| RED | `\e[0;31m` |
| GRAY | `\e[0;38;5;244m` |
| NC | `\e[0m` |

**Icons** (`base.sh:99-113`)

| Icon | Glyph |
|---|---|
| CONFIRM | `◎` |
| ADMIN | `⚙` |
| SUCCESS | `✓` |
| ERROR | `☻` |
| WARNING | `◎` (same glyph as CONFIRM) |
| EMPTY | `○` |
| SOLID | `●` |
| LIST | `•` |
| SUBLIST | `↳` |
| ARROW | `➤` |
| DRY_RUN | `→` |
| REVIEW | `⊙` |
| INFO | `ℹ` |

Some system.sh rows use a literal `!` as the icon.

**`bytes_to_human` uses decimal units** (1 KB = 1000 B; `base.sh:771-793`). Callers pass `KB*1024`, where KB is `du -k`/stat-derived 1024-byte blocks. Formats:
- `≥1e9` B gives `%d.%02dGB`
- `≥1e6` gives `%d.%01dMB`
- `≥1e3` gives `%dKB`
- otherwise `%dB`

**`colorize_human_size`** colours by unit: GB red, MB yellow, KB green, B gray.

**Whitelist** (`load_mole_whitelist`, `base.sh:361-445`):
- File: `$HOME/.config/mole/whitelist`, or the invoking user's home under sudo.
- If the file is absent, `DEFAULT_WHITELIST_PATTERNS` is used. If it exists, it **replaces** the defaults, except that `SAFETY_WHITELIST_PATTERNS` are always merged in.
- Parse rules: one pattern per line; lines are trimmed; blank lines and `#` comments are skipped.
- `~` and `$HOME` / `${HOME}` are expanded.
- Rejected lines become `WHITELIST_WARNINGS`, printed during clean as `  ◎ Whitelist: <msg>`:
  - containing `..` gives `Path traversal not allowed: <line>`;
  - containing control characters gives `Invalid path format: <line>`;
  - not absolute gives `Must be absolute path: <line>`;
  - containing `//` gives `Consecutive slashes: <line>`;
  - `/`, `/System*`, `/bin*`, `/sbin*`, `/usr/bin*`, `/usr/sbin*`, `/etc*`, `/var/db*` give `Protected system path: <line>`.
- The special token `FINDER_METADATA` protects `.DS_Store` cleanup.

`DEFAULT_WHITELIST_PATTERNS` (`base.sh:153-168`):
```
$HOME/Library/Caches/ms-playwright*
$HOME/.gradle/caches/*
$HOME/.gradle/daemon/*
$HOME/.ollama/models/*
$HOME/Library/Caches/com.nssurge.surge-mac/*
$HOME/Library/Application Support/com.nssurge.surge-mac/*
$HOME/Library/Caches/org.R-project.R/R/renv/*
$HOME/Library/Caches/JetBrains*
$HOME/Library/Caches/com.jetbrains.toolbox*
$HOME/Library/Caches/tealdeer/tldr-pages
$HOME/Library/Application Support/JetBrains*
$HOME/Library/Caches/com.apple.finder
$HOME/Library/Mobile Documents*
FINDER_METADATA
```
`SAFETY_WHITELIST_PATTERNS` (always merged; `base.sh:178-192`):
```
FINDER_METADATA
$HOME/Library/Caches/com.apple.FontRegistry*
$HOME/Library/Caches/com.apple.spotlight*
$HOME/Library/Caches/com.apple.Spotlight*
$HOME/Library/Caches/CloudKit*
$HOME/Library/Caches/pypoetry/virtualenvs*
```

**Matching** (`is_path_whitelisted`, `app_protection.sh:613-669`). Trailing `/` is stripped and `//` collapsed on both sides. A path matches when any of these holds:
- exact string match;
- bash glob match (`*`, `?`, `[`);
- the target is a **parent** of a pattern (the parent is protected so the whitelisted child survives);
- for a non-glob pattern, the target is a child of the pattern.

**Other base.sh facts**
- `get_free_space` runs `df -Pk /System/Volumes/Data`, falling back to `/`.
- `detect_architecture` returns `Apple Silicon` or `Intel`.
- Temp files live under `$TMPDIR` or `~/.cache/mole/tmp`. A registry file `mole.registry.<pid>` tracks them and they are removed on exit.

### log.sh

**Files**
- `~/Library/Logs/mole/mole.log`: `[YYYY-mm-dd HH:MM:SS] INFO|SUCCESS|WARNING|ERROR: msg`. Rotated to `.old` above 1 MB.
- `~/Library/Logs/mole/operations.log`: rotated to `.old` above 5 MB. Line formats (`log.sh:214-270`):
  ```
  (blank line)
  # ========== clean session started at 2026-09-30 16:29:43 ==========
  [2026-09-30 16:29:13] [clean] SKIPPED /Users/…/Caches/org.videolan.vlc (protected)
  [ts] [clean] REMOVED /path (15.2MB)
  # ========== clean session ended at 2026-09-30 16:29:43, 646 items, 7.51GB ==========
  ```
  - Actions: `REMOVED|SKIPPED|FAILED|TRASHED|REBUILT|TASK_FAILED`.
  - SKIPPED details include `protected`, `whitelist`, `compiled model cache`.
- `~/Library/Logs/mole/mole_debug_session.log` (debug only): truncated each session. Header block: `Mole Debug Session, <date>`, `User:`, `Hostname:`, `Architecture:`, `Kernel:`, `macOS: 26.6.2, 25G83`, `Shell: /bin/zsh, dumb`, `Sudo Access: Active|Required`.

**Caveats for the operations log**
- **Dry-run clean also writes a session start/end pair**, and the end line carries the would-be totals (observed `646 items, 7.51GB`). Dry-run and real sessions are indistinguishable in this log and in `mo history`.
- The log is shared across processes. Concurrent Mole runs interleave lines, and history mis-attributes sessions (observed).

**stdout/stderr split**
- `log_info` (blue) goes to stdout.
- `log_success` goes to stdout as `  ✓ msg`.
- `log_warning` (yellow) goes to stdout.
- `log_error` goes to **stderr** as `☻ msg`.
- `debug_log` goes to stderr as `[DEBUG] msg`.

**`print_summary_block`** (`log.sh:399-439`). The divider is `=` repeated `min(tput cols, 70)` times, which is 70 when piped:
```
(blank)
======================================================================
<BLUE>heading<NC>
detail line 1
...
======================================================================
```

### deletions.log (`file_ops.sh:3076-3103`)

`~/Library/Logs/mole/deletions.log` has TAB-separated fields: `<ISO8601 ts %Y-%m-%dT%H:%M:%S%z>\t<mode permanent|trash>\t<size_kb|unknown>\t<status>\t<path>`. Example: `2026-09-30T16:29:05+0100	trash	4	dry-run	/Users/…/Claude Code URL Handler.app`. It is used by `mole_delete` (uninstall paths), **not** by cache-clean paths.

### `mo history` (`bin/history.sh`, `lib/core/history.sh`)

Flags: `--json`, `--limit N` (1-200, default 20), `-h`. JSON schema (observed):
```json
{
  "logs": {"operations": string, "deletions": string},
  "limit": int,
  "sessions": [ { "command": string, "started_at": "YYYY-mm-dd HH:MM:SS", "ended_at": string (""=not ended),
      "items": int, "size": string (e.g. "7.51GB","0B"), "operation_count": int, "failed_tasks": int,
      "actions": {"removed": int, "trashed": int, "skipped": int, "failed": int, "rebuilt": int, "other": int} } ],
  "deletions": [ { "timestamp": string, "mode": string, "status": string, "size_kb": int|null, "path": string } ]
}
```
Both arrays are newest first.

### timeout.sh / timeouts.sh

- `run_with_timeout` uses `gtimeout`/`timeout` if present, otherwise a perl helper, otherwise a shell fallback.
- It returns 124 on timeout and 128+N on a signal.
- Clean treats 124 or ≥128 from a step as cancellation: the remaining sections are skipped and the summary heading becomes `Dry run cancelled` or `Cleanup interrupted`.

### ui.sh

- **Spinners** write to **stderr** as `\r\e[2K  <frame> <msg>` every 0.08 s with frames `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`. They run only when stdout is a TTY; `start_section_spinner` is a no-op when stdout is not a TTY.
- Non-TTY direct `start_inline_spinner` callers write `  | msg` (no newline) to stderr. Observed: none reached stderr in the piped clean run.
- `hide_cursor`/`show_cursor` apply only on a TTY.
- `has_full_disk_access` stats `~/Library/Safari/LocalStorage`, `~/Library/Mail/V10` and `~/Library/Messages/chat.db`. Clean shows the FDA hint only on a TTY non-dry run: `⊙ Grant Full Disk Access to your terminal in System Settings for best results`.

### app_protection.sh

- `should_protect_path` covers system and sensitive-app data (lists in `app_protection_data.sh`).
- `holds_compiled_model_cache` covers any `com.apple.e5rt.e5bundlecache`.
- These run before the whitelist in `_safe_clean_impl` (`clean.sh:1015-1040`). Skips are logged as `SKIPPED … (protected|whitelist|compiled model cache)`.

---

## 5. lib/core/sudo.sh in full, and how a GUI can supply admin auth

**Functions**
- `check_touchid_support`: greps `pam_tid.so` in `/etc/pam.d/sudo_local`, then `/etc/pam.d/sudo`. It is not configured on this Mac.
- `is_clamshell_mode`: uses `ioreg AppleClamshellState`.

**`request_sudo_access(msg)`** (`sudo.sh:71-208`)
1. Returns 0 if `sudo -n true` succeeds.
2. It decides "GUI mode" by testing `[[ -r /dev/tty && -w /dev/tty ]]`, falling back to `tty`. `/dev/tty` is `crw-rw-rw-`, so the permission test passes even without a controlling terminal. **I verified this**: in a `setsid()` child, `-r/-w` returned `perm_ok`, but opening it failed with `Device not configured`. So the osascript branch (`sudo.sh:96-126`) is effectively unreachable from a normal GUI child.
   - That branch shows `display dialog "<msg>" … with hidden answer`, then runs `printf pw | sudo -S -p "" -v`.
3. In TTY mode:
   - `sudo -k` is run first.
   - Clamshell mode, or no Touch ID: prints `➤ <msg>` to stdout, then `_request_password`. That writes `➤ Enter your credentials:` to the TTY and runs `sudo -v </dev/tty 2>/dev/tty`.
   - Touch ID: prints `➤ <msg> , Touch ID or password`. It runs a background `sudo -v </dev/null` for up to 5 s, then falls back to a password prompt.
   - Without a controlling TTY these writes and reads fail and the function returns 1. The caller then prints e.g. `  ◎ Xcode documentation cache · skipped (sudo denied)`.
   - **If the GUI child inherits a controlling terminal** (for example the GUI binary was launched from Terminal during development), sudo will prompt on that terminal and the child hangs. Spawn with `setsid`: `POSIX_SPAWN_SETSID`, or `setsid()` in a fork.

**Other entry points**
- `request_sudo_access_with_password(pw)`: `printf '%s\n' pw | sudo -S -p "" -v`.
- `adopt_sudo_session`: `sudo -n -v`. If that succeeds it starts a keepalive subshell that runs `sudo -n -v` every 30 s (every 5 s after a failure) while the parent is alive.
- `ensure_sudo_session`, `ensure_sudo_session_with_password`, `stop_sudo_session`.
- Every privileged file operation uses `sudo -n …` wrapped in `run_with_timeout` (`file_ops.sh:51-77, 2137`). `SUDO_ASKPASS` has no effect because Mole never passes `-A`.

**Where clean calls sudo**
- `start_cleanup` (`clean.sh:1573-1619`):
  - Dry run: only `adopt_sudo_session`. It prints `✓ Admin access available, system preview included` or `◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview`.
  - Real run with a TTY stdin: adopt; otherwise `prompt_for_system_clean`.
  - Real run with non-TTY stdin: adopt only, with this output:
    ```

    Running in non-interactive mode
      • System-level cleanup enabled, sudo session active      (or: "  • System-level cleanup skipped, requires sudo")
      • User-level cleanup will proceed automatically

    ```
- **Mid-run** (real run only): `lib/clean/dev.sh:1446` (Xcode documentation cache) and `dev.sh:1929` (Xcode Simulator system cache) call `ensure_sudo_session` when there is no session. Without a TTY they fail harmlessly as described above.

**`prompt_for_system_clean`** (TTY stdin only, `clean.sh:556-619`)
- Prints `➤ System caches need sudo. Enter continue, Space skip: `.
- Reads one key via `read_key` with `MOLE_READ_KEY_FORCE_CHAR=1`, from **stdin** (not `/dev/tty`):
  - ESC or Ctrl-C prints ` Canceled` and **exits 0**.
  - Space prints ` Skipped`.
  - Enter runs `ensure_sudo_session`, which prompts via the TTY.
  - Any other printable character is treated as the first character of the password. The rest is read with `read -r -s` from `/dev/tty` if readable, else stdin. Then `sudo -S -v` is attempted.
  - Two unrecognised keys in a row mean skip.
- Result lines: `✓ Admin access granted`, or `Authentication failed, continuing with user-level cleanup`.

**Timestamp scope.** sudoers `timestamp_type` defaults to `tty`. Without a TTY it behaves like `ppid` (`man sudoers`). Mole's `sudo -n` calls run from subshells, `gtimeout` or perl, so their parent PIDs differ and a PPID-keyed ticket will not match them. The keepalive also runs in a subshell.

**Recommended GUI options for admin auth**
- **(A) Controlling PTY with pipes for output.** Spawn a session leader with `setsid` + `TIOCSCTTY` on a pty slave. Use the pty slave (or `/dev/null`) for stdin and pipes for stdout/stderr. Inside that session, first run `printf '%s\n' "$PW" | sudo -S -p '' -v` (the password comes from the GUI's SecureField), then `exec /opt/homebrew/bin/mo clean`. Everything shares the TTY-keyed ticket. With stdin `/dev/null`, Mole takes the non-interactive branch and adopts the session. Output stays uncoloured because stdout is a pipe.
  - Alternatively, make stdin the pty slave and answer `prompt_for_system_clean` by writing `<password>\n` to the pty master. This works only if the first character is not a space or ESC.
- **(B) Full PTY** via `/usr/bin/script -q /dev/null mo …` or `forkpty`. This needs ANSI parsing. `TERM=dumb` kills colours but not the spinner `\r` frames.
- **(C) Skip system clean.** Run with no cached credential (or `MOLE_TEST_NO_AUTH=1` plus ANSI stripping). The user-level clean then runs and system-level work is skipped.
- `sudo -A` with `SUDO_ASKPASS` can be used by the GUI's own pre-auth step inside option (A).

**Found on this machine (context)**
- `/etc/sudoers.d/mole` (root 0440, 60 bytes, unreadable).
- `~/.config/mole/sudoers-version` containing `mole-v61`.
- `~/Library/Caches/com.tw93.MoleApp`.

These come from the separate official Mole Mac app, not the CLI; v1.56.0 source has no reference to sudoers. GitHub issue #1563 has the maintainer confirming that "every privileged probe runs as `sudo -n`" and that users should pre-authenticate (`sudo true`) in the same terminal.

---

## 6. `mo clean` (bin/clean.sh plus lib/clean/*)

### Flags (`clean.sh:2140-2200`, help at `help.sh:3-14`)

Flags are processed left to right.

| Flag | Behaviour |
|---|---|
| `--dry-run`, `-n` | Sets `MOLE_DRY_RUN=1`. |
| `--external PATH` | Validated immediately. Errors go to stderr with exit 1. |
| `--whitelist` | Runs the interactive TUI and **exits immediately**, so any later flags are ignored. |
| `--debug` | Same as the global flag. |
| `-h`, `--help` | Prints help, exit 0. |
| `--select`, `--categories`, `--exclude` | Removed. Prints `mo clean --select was removed in this release.` and `Use 'mo clean --dry-run' to preview cleanup and 'mo clean --whitelist' to protect paths.`, exit 1. |
| other `-x` | `Unknown option for mo clean: -x` and `Run 'mo clean --help' for usage.`, exit 1. |
| other positional `x` | `Unexpected argument for mo clean: x`, exit 1. |

There is no category selection, `--yes` or JSON option for clean.

**`--external` validation** (`user.sh:1428-1495`). Each observed error message:
- `Missing path for --external`
- `External volume path must be absolute: relative`
- `Refusing to clean the volumes root directly: /Volumes`
- `Refusing to clean symlinked volume path: /Volumes/Macintosh HD`
- `External volume path does not exist: …`
- `External volume path must be under /Volumes: …`
- `External cleanup only supports mounted paths directly under /Volumes: …`
- `Refusing to clean an internal volume: …` (checked via `diskutil info`)
- `Refusing to clean network volume protocol SMB: …`

External mode cleans `.TemporaryItems`, `.Trashes`, `._*` AppleDouble files and `.DS_Store` (the last unless the `FINDER_METADATA` token is whitelisted, and it is in the safety list). It runs a single section `External volume`. Result row: `  → External volume cleanup · <volname>, <size> dry` or `  ✓ External volume cleanup · <volname>, <size>`.

**Observed quirk:** on `/Volumes/Backup`, whose `.Trashes` is `d-wx--x--t`, sizing failed, the step returned 1 silently, and the output was:
```
➤ External volume

======================================================================
Dry run incomplete
◎ A required cleanup step failed (exit 1). Remaining cleanup was skipped.
Free space: 93.06GB
======================================================================
```
The exit code was 1.

### Execution flow and stdout lines (piped; observed in `clean_dryrun.stdout`)

```

Clean Your Mac

Dry Run Mode, Preview only, no deletions

◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview

⚙ Apple Silicon | Free space: 94.20GB
✓ Whitelist: 19 core patterns active            (format: "<N> core[ + <M> custom] patterns active")
  ↳ /Users/you/Library/Caches/ms-playwright*     (dry run lists each pattern; FINDER_METADATA omitted)
...
➤ User essentials
  → User app cache · 25 items, 3.18GB dry
  → User app logs · 14 items, 923.3MB dry
...
➤ Cloud & Office
  ✓ Nothing to clean
...
➤ Large files
  ⊙ NuGet packages · 1.48GB · ~/.nuget/packages
  ⊙ pnpm store · 1.31GB · ~/Library/pnpm/store

➤ Project artifacts
  ◎ Build artifacts · scan skipped · mo purge


======================================================================
Dry run complete - no changes made
Potential space: 7.51GB | Items: 645 | Categories: 6
Detailed file list: /Users/you/.config/mole/clean-list.txt
Use mo clean --whitelist to add protection rules
======================================================================

```
A real non-TTY run replaces the "Dry Run Mode…" lines with the "Running in non-interactive mode" block (§5), and the header `⚙ …` line follows.

**Sections, in order** (`clean.sh:1839-1942`). A header is `\n<PURPLE_BOLD>➤ <Title><NC>`, piped as `➤ Title`:
1. `System` (only when sudo is adopted)
2. whitelist warnings (if any)
3. `User essentials`
4. `App caches`
5. `Browsers`
6. `Cloud & Office`
7. `Developer tools`
8. `Apps & utilities`
9. `Virtualization`
10. `Application Support`
11. `App leftovers`
12. `Apple Silicon updates` (arm64 only; from `user.sh:2874`)
13. `Device backups & firmware`
14. `Time Machine`
15. `Large files`
16. `Project artifacts`

An idle section prints `  ✓ Nothing to clean` when piped or under `MO_DEBUG`. On an ANSI TTY the header is overwritten in place by the next header (`\e[1A\r\e[2K`), as the PTY capture shows.

### Item rows

The general grammar is: two spaces, `<icon>`, space, `<label>`, then ` · ` (U+00B7 with spaces) and detail fields.

**Main row, from `_safe_clean_impl`** (`clean.sh:1497-1510`)
- Dry run: `  ${YELLOW}→${NC} <desc>${NC} · [<n> items, ]<colored size> ${YELLOW}dry${NC}`
  - Raw example: `  \e[0;33m→\e[0m Chrome cache\e[0m · 5 items, \e[0;31m1.38GB\e[0m \e[0;33mdry\e[0m`
  - Piped: `  → Chrome cache · 5 items, 1.38GB dry`
- Real run: `  ${GREEN}✓${NC} <desc>${NC} · [<n> items, ]${GREEN}<size>${NC}`

**Other shapes** (grep inventory, lib/clean)
- `  → <label> · would clean`
- `  → <label> · would skip (whitelist|pnpm busy)`
- `  → X · would remove N entries (0B)`
- `  → <Browser> Service Worker, would clean <size>, <n> protected` (no `·`)
- `  → Trash · would empty, N items`
- `  → Would clean N items, about XMB`
- `  → Homebrew cleanup · would free X`
- `  ✓ <label> · skipped (whitelist)`
- `  ✓ Trash · emptied, N items`
- `  ✓ Homebrew cleanup · N items`
- `  ◎ <label> · skipped (process state unknown|sudo denied|…)`
- `  ◎ <label> · stopped (<reason>)`
- `  ◎ Project caches · skipped 2 slow/incomplete root scans`
- `  ⊙ <label> · <size>[ · date] · <path>` (review-only; nothing deleted). On a TTY the path is an OSC 8 hyperlink: `\e]8;;file://<pct-encoded>\e\\~/path\e]8;;\e\\`
- `  ! <label> · skipped (…)` (Time Machine rows)

**Suggested parse regex (piped):**
`^  (→|✓|◎|⊙|!) (.+?)(?: · (.*?))?( dry)?$`
Then extract the size with `(\d+(?:\.\d+)?)(GB|MB|KB|B)` and the count with `(\d+) items`. Rows are **display only**. The per-row sizes do not sum to the total:
- tool-based rows ("would clean") carry no size;
- overlapping paths are de-duplicated in the total.

### Totals and summary

- **Dry-run totals** come from the de-duplicated ledger (`render_clean_preview_from_ledger`, `clean.sh:480-527`):
  - Items = sum of counts;
  - Categories = number of distinct sections in the ledger, **not** the number of rows;
  - the label is `At least X` when any size is unknown.
- **Real-run summary line:** `Tracked cleanup: ${GREEN}<size>${NC} | Items cleaned: N`, prefixed `At least ` or replaced with `Partially measured` when sizing timed out. It is followed by `Free space: <X>[ (+<delta>)]`.
- **Nothing found:** `No significant reclaimable space detected, system already clean.` (dry run) or `System was already clean; no additional space freed.`
- **Summary headings:**
  - `Dry run complete - no changes made` / `Cleanup complete`
  - `Dry run cancelled` / `Cleanup cancelled` (124)
  - `Dry run interrupted` / `Cleanup interrupted` (≥128)
  - `Dry run incomplete` / `Cleanup incomplete` (other failure)
  - Each is followed by `◎ Cancelled: …` or `◎ A required cleanup step failed (exit N). …`

### Preview file `~/.config/mole/clean-list.txt` (dry run; recommended source for a GUI item list)

This is the best machine-readable dry-run output. It is written at the end of the run (`clean.sh:462-527, 2073-2085`):
```
# Mole Cleanup Preview - 2026-09-30 16:27:16
# (fixed 9-line header: how to protect files, example)

=== User essentials ===
/Users/you/Library/Caches/pip  # 22.1MB
/Users/…/Caches/GeoServices/Resources  # 51.9MB, counted under /Users/…/Caches/GeoServices
<path>  # size unknown[, N items][, counted under <ancestor>]
...
# ============================================
# Summary
# ============================================
# Potential cleanup: 7.51GB        ("At least X" if partial)
# Items: 645
# Categories: 6
```
- Line regex: `^(.*)  # (size unknown|[\d.]+(?:GB|MB|KB|B))(?:, (\d+) items)?(?:, counted under (.*))?$`
- Paths may contain spaces; the separator is two spaces, `#`, one space.
- Section markers are `^=== (.+) ===$`.

### Exit codes (clean)

| Code | Meaning |
|---|---|
| 0 | Success, including a user Cancel at the sudo prompt |
| 1 | Argument or validation error, running as root, required step failure, or preview-file failure |
| 124 | Scan timeout cancel |
| ≥128 | Signal; the INT trap gives 130, TERM gives 143 (`clean.sh:640-641`) |

On exit the EXIT trap stops spinners, removes temp files and kills the sudo keepalive.

**Cancelling from the GUI.** Send SIGINT or SIGTERM to the process group. Spawn in its own process group, because Foundation `Process` shares the GUI's group.

### Other clean behaviours

- **TCC first-run prompt:** `check_tcc_permissions` does `read -r` from stdin, but only when stdout is a TTY and `ls ~/Library/Caches` fails. It is skipped when piped (`caches.sh:10-44`). The flag file is `~/.cache/mole/permissions_granted`.
- **Throttling:** Homebrew cleanup is throttled via `~/.cache/mole/brew_last_cleanup` (epoch seconds).
- **Timing:** a full dry run took about 140 s on this Mac.
- **Idle output:** the pipe can go quiet for long stretches, and there is no progress output on a pipe. For a progress indicator, use section headers or run with `--debug` (`[DEBUG] PERF [cleanup step: …]` lines on stderr).

### `mo clean --whitelist` (`lib/manage/whitelist.sh`)

- **TUI only.** `paginated_multi_select` reads keys from stdin. With stdin at EOF it prints `Cancelled, no changes saved` and saves nothing.
- **The GUI should edit `~/.config/mole/whitelist` directly.** On save, Mole writes this header, then one blank line, then one pattern per line with `~` form for predefined entries:
  ```
  # Mole Whitelist - Protected paths won't be deleted
  # Default protections: Playwright browsers, Ollama models, Surge Mac, R renv, Finder metadata
  # Add one pattern per line to keep items safe.
  ```
- Custom (non-inventory) patterns are preserved. Safety patterns are not written out.
- The optimize whitelist is `~/.config/mole/whitelist_optimize` (legacy name `whitelist_checks`).
- **Predefined inventory** (`get_all_cache_items`, `whitelist.sh:91-182`): about 70 rows in the form `display name|pattern|category` (categories `system_cache`, `ide_cache`, `ai_ml_cache`, `compiler_cache`, `package_manager`, `browser_cache`, `network_tools`, `container_cache`, `app_cache`). A few rows are dynamic: Go build/module cache, GitHub CLI cache, Clang module cache, and `Finder metadata, .DS_Store|FINDER_METADATA`. Reuse this list verbatim for a GUI checklist.
- There is currently no whitelist file on this machine, so the defaults are active; the run showed `19 core patterns active`.

### Non-interactive checklist for the GUI

- `mo clean --dry-run` with stdin `/dev/null` never blocks. That matches the observed run: no prompts, empty stderr, exit 0.
- `mo clean` with stdin `/dev/null` never blocks either, but it **deletes without confirmation** and skips system cleanup unless sudo is shared through a TTY session (§5).
- Always spawn with `setsid` so no inherited controlling terminal can catch a sudo prompt.

---

# optimize+purge+installer

# Mole v1.56.0: `mo optimize`, `mo purge` and `mo installer` behind a GUI, plus the interactive selectors

None of the three commands has JSON output, and none reads a TTY check you can switch off, so a GUI has to parse text or drive them over a pseudo-terminal (PTY). All paths below are relative to `/opt/homebrew/Cellar/mole/1.56.0/libexec/`. Captured outputs are in `<scratch>/research/`.

What I ran: `--dry-run` for each command, `--help`, and `mo optimize --whitelist` fed EOF (it cancelled and saved nothing). I also ran `mo purge --paths` with `EDITOR=/usr/bin/true` and one bare `mo purge` without `--yes` under a stand-in `HOME` in the scratchpad; that run refused, as expected. No real clean, purge or delete was run, and nothing asked for a password.

## Answers to the main questions

- **Colour codes are off automatically under pipes.** `lib/core/base.sh:34-64` turns off all colour codes when `NO_COLOR` is set, when `TERM=dumb`, or when stdout is not a TTY. A GUI using pipes gets plain text; the icons (`✓ → ◎ ➤ ⚙ ☻ ○ ● ↳ ⊙ ℹ`) are still printed.
- **Some escape codes are printed even without a TTY.** The menus in `installer.sh` and `menu_simple.sh`/`menu_paginated.sh` always write `\033[H`, `\r\033[2K` and `\033[2J`. Strip them before parsing.
- **Setting `MOLE_TEST_MODE=1` or `MOLE_TEST_NO_AUTH=1` forces colour on** (unless `NO_COLOR` is set). It also disables sudo and Touch ID. These are test hooks, not a supported interface.
- **Confirmation prompts read stdin, never `/dev/tty`.** A GUI can answer them over a pipe or a PTY. `read_key` is at `lib/core/ui.sh:167`, installer prompts at `bin/installer.sh:513,729`, the purge confirm at `lib/clean/project.sh:1665`.
- **Sudo cannot be satisfied through a pipe.** Only `optimize` uses sudo; purge and installer never call it. Details in the sudo section below.
- **Per-item selection for purge only works with a PTY.** With stdin not a TTY, purge skips its menu and picks automatically. The installer menu *can* be driven over a stdin pipe (verified).
- **Recommendation:** use pipes plus `NO_COLOR=1` for `optimize --dry-run`, `installer --dry-run`, `purge --dry-run` and `purge --yes`. Use a PTY (`forkpty`, or wrap in `/usr/bin/script -q /dev/null mo …`) for real `optimize` (sudo) and for interactive purge selection.

---

## 1. Shared infrastructure

### Entry point `mo` (`libexec/mole`)
- Refuses to run as root (exit 1): `Run Mole without sudo; it requests administrator access when needed.` This check is also at the top of each `bin/*.sh`.
- `--debug` anywhere on the command line is stripped and becomes `MO_DEBUG=1` (`mole:59-74`).
- Dispatch at `mole:280-299`: `optimize|optimise`, `purge` and `installer` `exec` their scripts, so the PID is kept and signals reach the script directly.
- No update check runs for subcommands; `check_for_updates` only runs for the bare `mo` menu.

### Colours and icons
Colour codes (`base.sh:53-63`) when enabled:

| Name | Code |
|---|---|
| GREEN | `\e[0;32m` |
| BLUE | `\e[1;34m` |
| CYAN | `\e[0;36m` |
| YELLOW | `\e[0;33m` |
| PURPLE | `\e[0;35m` |
| PURPLE_BOLD | `\e[1;35m` |
| RED | `\e[0;31m` |
| GRAY | `\e[0;38;5;244m` |
| NC (reset) | `\e[0m` |

Icons (`base.sh:99-113`): CONFIRM `◎`, ADMIN `⚙`, SUCCESS `✓`, ERROR `☻`, WARNING `◎` (same glyph as CONFIRM), EMPTY `○`, SOLID `●`, LIST `•`, SUBLIST `↳`, ARROW `➤`, DRY_RUN `→`, REVIEW `⊙`, INFO `ℹ`, NAV `↑` `↓`.

`hide_cursor` and `show_cursor` only print when stdout is a TTY, and they write to stderr (`ui.sh:28-29`). `clear_screen` always prints `\e[2J\e[H` but callers guard it with `-t 1`. Spinners (`start_inline_spinner`, `ui.sh:340`) only run when stdout is a TTY.

### Summary block (`lib/core/log.sh:399`)
```
<blank>
======================================================================   (= × min(tput cols, 70); 70 when no TTY)
<BLUE>Heading<NC>
detail line 1
...
======================================================================
```

### `read_key` (`ui.sh:167-268`)
- Reads with `IFS= read -r -s -n 1` from **stdin**.
- On EOF or read error it returns `QUIT`.
- An empty read or `\n`/`\r` gives `ENTER`; space gives `SPACE`; `q`/`Q` and `\x03` give `QUIT`.
- `j`/`k`/`h`/`l` give DOWN/UP/LEFT/RIGHT. `G` gives BOTTOM; `gg` gives TOP.
- `R` RETRY, `m` MORE, `v` VERSION, `u` UPDATE, `t` TOUCHID.
- `\x7f`/`\x08` give DELETE; `\x15` gives CLEAR_LINE; any other printable character gives `CHAR:<c>`.
- Escape sequences, each byte read with a 1-second timeout:
  - `ESC [ A/B/C/D` → UP/DOWN/RIGHT/LEFT
  - `ESC [ H/F` → TOP/BOTTOM
  - `ESC [ 1~ / 7~` → TOP; `4~ / 8~` → BOTTOM; `5~` → LEFT; `6~` → RIGHT; `3~` → DELETE
  - A lone ESC with no follow-up byte within 1 s → QUIT
- When `MOLE_READ_KEY_FORCE_CHAR=1` (search mode), letters come back as `CHAR:x` instead of shortcuts.
- `drain_pending_input` (`ui.sh:270`) discards bytes that arrive within 10 ms of each other. Keystrokes that arrive together can therefore be dropped wherever it is called (see §5).

### Logs (shared)
- **`~/Library/Logs/mole/operations.log`**
  - Path is readonly (`log.sh:26`); disable with `MO_NO_OPLOG=1`. `docs/SECURITY_DESIGN.md` mentions `MOLE_OPLOG_PATH`, but v1.56.0 code does not read it.
  - Rotates to `.old` above 5 MB.
  - Line formats:
    - `[YYYY-mm-dd HH:MM:SS] [<command>] <ACTION> <path> (<detail>)`, where ACTION is one of REMOVED, SKIPPED, FAILED, TASK_FAILED
    - `# ========== <cmd> session started at <ts> ==========`
    - `# ========== <cmd> session ended at <ts>, <N> items, <size> ==========`
  - Dry runs still write session markers and SKIPPED lines. Real sample: `[2026-09-30 16:26:28] [optimize] TASK_FAILED shared_file_list_repair (task outcome)`.
  - Several concurrent `mo` processes interleave in this file.
- **`~/Library/Logs/mole/deletions.log`** (override with `MOLE_DELETE_LOG`; `file_ops.sh:3076`)
  - Written by `mole_delete` (used by the installer).
  - Tab-separated: `ISO8601ts<TAB>mode<TAB>size_kb|unknown<TAB>status<TAB>path`.
  - Status is one of: `ok`, `dry-run`, `rejected`, `identity-changed`, `mutable-parent`, `invalid-mode`, `privacy-denied`, `trash-failed`, `interrupted`, `timed-out`.
  - Real sample: `2026-09-30T16:30:09+0100	permanent	139444	dry-run	/Users/…/Downloads/T3-Code-0.0.44-arm64.dmg`
- **`MO_DEBUG=1` / `--debug`**: writes `[DEBUG] …` to **stderr** and a session log to `~/Library/Logs/mole/mole_debug_session.log`.

### Sudo (`lib/core/sudo.sh`) and why it matters for a GUI
`ensure_sudo_session` (`:337`) calls `request_sudo_access` (`:71`), which works like this:
1. `sudo -n true` succeeds → no prompt.
2. Otherwise it treats the run as "GUI mode" (osascript password dialog, then `sudo -S -v`) only when `/dev/tty` is **not readable and writable**.
   - **Verified here:** in a process with no controlling terminal, `[[ -r /dev/tty && -w /dev/tty ]]` still passes (the device node is mode 666), but opening it fails ("Device not configured").
   - So GUI mode is never selected and the osascript dialog never appears.
3. It then tries Touch ID (if `pam_tid.so` is in `/etc/pam.d/sudo_local` or `sudo`) with a background `sudo -v </dev/null` and a 5-second wait. This machine has no `sudo_local`, so no Touch ID.
4. Then `_request_password` writes `➤ Enter your credentials:` to the TTY and runs `sudo -v < /dev/tty`. With no TTY this fails and returns 1.
5. On success a keepalive subshell runs `sudo -n -v` every 30 s.

There is no `SUDO_ASKPASS` support (grep found none; upstream issue #1563 about corporate sudo prompts is still unanswered).

**Result for `mo optimize` without a TTY:** it does not block. It prints `  ✓ Skipping sudo-required optimizations: admin access not granted`, and the sudo tasks report `skipped (admin access required)`.

**Pre-authenticating from the GUI does not carry over.** sudo 1.9.17p2 defaults to `timestamp_type=tty`, and "if no terminal is present, the behavior is the same as ppid" (sudoers man). Mole's many `sudo` calls run from different subshells with different parent PIDs.

**Recommended approach:** run real `optimize` under a PTY. Watch for `Enter your credentials:` or sudo's `Password:` and write the password plus `\n` to the PTY master. Under a PTY the timestamp is keyed on the TTY, so all of Mole's sudo calls share it.

### Other environment variables that change behaviour

| Variable | Effect |
|---|---|
| `NO_COLOR` | Disables colour |
| `TERM=dumb` | Disables colour |
| `MO_DEBUG=1` | Debug output |
| `MO_NO_OPLOG=1` | No operations log |
| `MOLE_DRY_RUN=1` | Same as `--dry-run` (the flag just exports it) |
| `MOLE_DELETE_MODE=permanent\|trash` | Affects `mole_delete` only, so the installer can move to Trash. Purge's `safe_remove` always uses `rm -rf` |
| `MOLE_TIMEOUT_{QUICK_DETECT,SHORT_QUERY,MEDIUM_PROBE,PKG_LIST,PKG_CLEANUP,DISK_VERIFY,HINT_SCAN}_SEC` | Timeouts; defaults 2/3/5/10/20/30/15 (`timeouts.sh:61-67`) |
| `XDG_CACHE_HOME` | Location of purge stats files |

---

## 2. `mo optimize` (`bin/optimize.sh`, `lib/optimize/*`)

### Flags (`optimize.sh:204-226`, each argument parsed in order)

| Flag | Effect |
|---|---|
| `--dry-run` | Sets `MOLE_DRY_RUN=1` |
| `--debug` | Debug output |
| `--whitelist` | Opens the whitelist manager and exits 0 immediately; later arguments are ignored |
| `-h`, `--help` | Help, exit 0 |
| anything else | stderr `Unknown optimize option: X` / `Use 'mo optimize --help' for supported options.`, exit 1 |

`bc` is required: without it the command prints `☻ Missing dependency: bc` and exits 1.

### Flow
1. Print header, plus the dry-run banner.
2. Collect health data. The JSON is internal (`lib/check/health_json.sh`) with fields `memory_used_gb, memory_total_gb, disk_used_gb, disk_total_gb, disk_used_percent, uptime_days` (numbers) and `optimizations[] {category:"system", name, description, action, safe:bool}`. It is **not** exposed on the command line.
3. Load the whitelist.
4. Print the System line.
5. Run diagnostics, which sample `ps` twice about 1 s apart.
6. Sudo: in dry run, `MOLE_OPTIMIZE_SUDO_AVAILABLE=true` with no prompt; otherwise `ensure_sudo_session "System optimization requires admin access"`.
7. Run every task in the catalog, in catalog order.
8. Print the summary.

### Task catalog (`lib/optimize/catalog.sh:31-90`)
Twenty tasks, all run on every pass. The action ID is the whitelist key. "Display name" is printed as `➤ <name>`; the whitelist-menu label is the same except `login_items_audit`, which shows as "Login Items Audit".

| # | action ID | Display name | Sudo in a real run? |
|---|---|---|---|
|1|`system_maintenance`|DNS & Spotlight Check|yes (`dscacheutil`, `killall -HUP mDNSResponder`)|
|2|`cache_refresh`|Finder Cache Refresh|no|
|3|`saved_state_cleanup`|App State Cleanup|no (older than 30 days)|
|4|`fix_broken_configs`|Broken Config Repair|no|
|5|`network_optimization`|Network Cache Refresh|yes (unchanged if task 1 already flushed)|
|6|`sqlite_vacuum`|Database Optimization|no|
|7|`prevent_network_dsstore`|Prevent Finder .DS_Store|no (`defaults write`)|
|8|`legacy_overrides_audit`|Legacy Overrides|no|
|9|`network_stack_optimize`|Network Stack Refresh|yes (`route -n flush`, `arp -a -d`); skipped when a VPN is active|
|10|`disk_permissions_repair`|Permission Repair|yes (`diskutil resetUserPermissions`)|
|11|`spotlight_index_optimize`|Spotlight Optimization|yes if slow (`mdutil -E /`)|
|12|`spotlight_orphan_rules_cleanup`|Spotlight Orphan Rules|no|
|13|`periodic_maintenance`|Periodic Maintenance|yes (`sudo periodic daily weekly monthly`)|
|14|`shared_file_list_repair`|Shared File Lists|no|
|15|`disk_verify`|Disk Health|off unless `MOLE_ENABLE_DISK_VERIFY=1`; skipped in dry run|
|16|`login_items_audit`|Login Items|uses `sudo -n` only, never prompts|
|17|`quarantine_cleanup`|Quarantine Database Cleanup|no|
|18|`launch_agents_cleanup`|Launch Agents Cleanup|report only|
|19|`notification_cleanup`|Notifications|no|
|20|`coreduet_cleanup`|Usage Data|no|

Each task has a one-line description in `MOLE_OPTIMIZE_DESCRIPTIONS` (`catalog.sh`), useful as GUI subtitles. The GUI should hard-code this table; it cannot be listed from the command line.

### Output formats (colours shown as enabled)
- Header: `\n<PURPLE_BOLD>Optimize<NC>`
- Dry-run banner: `<YELLOW>→ DRY RUN MODE<NC>, No files will be modified` then a blank line
- Active whitelist (only printed when there are 1-3 entries): `⚙ Active Whitelist: a, b`
- System line (`:153`): `⚙ System  13/16 GB RAM | 345/460 GB Disk | Uptime 8d`
  - Regex: `^⚙ System  (\d+)/(\d+) GB RAM \| (\d+)/(\d+) GB Disk \| Uptime (\d+)d$`
- Diagnostics (`diagnostics.sh:371-450`, 560+):
  - Heading `<BLUE>Performance diagnosis<NC>`
  - Lines indented two spaces: `✓ No sustained high-CPU bottleneck detected` | `◎ Likely bottleneck: WindowServer (~59.6% CPU sustained)` | `⊙ <note>` | `◎ Memory pressure: swap 5.62GB of 6.44GB used (87%), 31% free` followed by 4-space-indented `<proc name padded>   619.1MB` | VM and runaway-process warnings | mounted-image list.
  - The "Detach now?" prompt (`read_key`) only appears when **not** a dry run **and** stdout is a TTY. Otherwise it prints `⊙ Review these mounted images…`.
- Task header (`optimize.sh:157-166`): a blank line between tasks, then `<BLUE>➤ <Display name><NC>`
- Task result lines (`tasks.sh:22-29`, `opt_msg`):
  - dry run: `  <YELLOW>→<NC> <msg>`
  - real run: `  <GREEN>✓<NC> <msg>`
  - warnings: `  <YELLOW>◎<NC> <msg>`
  - neutral/unavailable: `  <GRAY>-<NC> <msg>` or `  <GRAY>○<NC> <msg>`
  - A task can print several lines. Whitelisted task: `  → Skipped (whitelisted): <Display name>` (`tasks.sh:2053`).
- **The per-task outcome is not printed.** Outcomes are internal (`lib/optimize/outcomes.sh:18-23`): `applied|unchanged|skipped|unavailable|attention|failed`. The GUI can only infer them from the icon: `→`/`✓` ≈ applied or unchanged, `◎` ≈ attention or failed, `-` ≈ unavailable. Only the summary line gives exact counts.
- Summary, dry run (`optimize.sh:88-92`):
  ```
  Dry Run Complete, No Changes Made
  Would apply <YELLOW>3<NC> optimizations
  12 unchanged | 2 skipped | 1 unavailable | 2 failed        (zero counts omitted; "N need attention")
  Run without <YELLOW>--dry-run<NC> to apply these changes
  ```
- Summary, real run:
  - `Optimization Complete`
  - `Applied <GREEN>N<NC> optimizations[, 12.3MB cache cleaned | , N databases optimized | , N configs repaired]`
  - the outcome line
  - `Review the warnings above` or `Optimization pass complete`
- Sudo prompt line (stdout): `<PURPLE>➤<NC> System optimization requires admin access`
- Real sample: `optimize_dryrun_pipe.stdout` (piped); ANSI and PTY versions in `optimize_dryrun_pty_color.raw` / `optimize_dryrun_pty.raw`. The PTY version starts with `\e[2J\e[H` and has `\r`-overwritten spinners (`⠋ Collecting system info...`, `Checking preferences...`, `Checking Spotlight speed...`) cleared with `\r\e[2K`. A dry run took about 23 s.

### Exit codes
- 0: no task reported `failed`.
- **1: any task failed, even in a dry run.** My dry run exited 1 because `shared_file_list_repair` and `login_items_audit` failed, probably TCC or a timeout.
- 1 also for a bad option, missing bc, health collection failure, or incomplete outcomes.
- 130 on INT/TERM.
- Failed actions are logged as `TASK_FAILED <action> (task outcome)`.

### Whitelist
- File: `~/.config/mole/whitelist_optimize`. A legacy `~/.config/mole/whitelist_checks` is migrated automatically (`whitelist.sh:21-23, 204-287`).
- Format: one entry per line. Leading and trailing whitespace are trimmed; blank lines and `#…` are ignored.
- Entries are either task **action IDs** (exact string match, `is_whitelisted`, `whitelist.sh:295`) or **path patterns** used by diagnostics when deciding which mounted images to detach (`is_path_whitelisted`: glob, parent or child match, `~` expanded).
- Retired IDs `dock_refresh`, `memory_pressure_relief` and `launch_services_rebuild` are dropped.
- Header written by Mole: `# Mole Optimization Whitelist - These checks will be skipped during optimization`. Mole rewrites the whole file on save.
- There are no default optimize whitelist entries.
- `mo optimize --whitelist` is an interactive menu (`menu_simple.sh` version of `paginated_multi_select`; see §5). **A GUI should edit the file directly.** Fed EOF, the menu exits 0 and prints `Cancelled, no changes saved`; the menu itself is drawn to stderr.

### Optimize-specific environment variables
- `MOLE_ENABLE_DISK_VERIFY=1`
- `MOLE_ASSUME_VPN_ACTIVE=1|0`
- `MOLE_OPTIMIZE_SPOTLIGHT_SLOW_SEC` (3)
- `MOLE_OPTIMIZE_DIAG_CPU_THRESHOLD` (25), `MOLE_OPTIMIZE_DIAG_SAMPLE_DELAY` (1)
- `MOLE_OPTIMIZE_{SWAP_PCT(50), FREE_PCT(15), IDLE_VM_GB(2), RUNAWAY_PCT(25), RUNAWAY_MIN_HOURS(12)}`
- Test overrides: `MOLE_OPTIMIZE_PS_SAMPLE_1/2`, `…SWAPUSAGE`, `…MEM_FREE_SAMPLE`, `…RSS_SAMPLE`, `…PROCTIME_SAMPLE`, `…VM_SAMPLE`, `…SPCTL_STATUS`, `…HDIUTIL_INFO`
- `MOLE_OPTIMIZE_SUDO_AVAILABLE` is overwritten internally.

I checked every task handler for dry-run guards before running it (e.g. `tasks.sh:155,1017,1101,1186,1309,1443,1550`, and `safe_remove` at `file_ops.sh:1481`).

---

## 3. `mo purge` (`bin/purge.sh`, `lib/clean/project.sh`, `purge_shared.sh`, `lib/manage/purge_paths.sh`)

### Flags (`purge.sh:333-362`)

| Flag | Effect |
|---|---|
| `--paths` | Opens the paths manager, exits 0 |
| `--help` | Help. **`-h` is not accepted** (it is an unknown option) |
| `--debug` | Debug output |
| `--dry-run`, `-n` | `MOLE_DRY_RUN=1` |
| `--yes` | `MOLE_PURGE_YES=1` |
| `--include-empty` | `MOLE_PURGE_INCLUDE_EMPTY=1` |
| other | stderr `Unknown option: X` / `Use 'mo purge --help' for usage information`, exit 1 |

**Side effect on load:** sourcing `project.sh` runs `load_purge_config` (`project.sh:207-262`), even for `--help`. If `~/.config/mole/purge_paths` has no paths, it auto-discovers and **writes** that file.

### Non-TTY behaviour (`project.sh:1681-1686, 2508-2530, 2568, 2698-2705`)
- stdin not a TTY, not a dry run, no `--yes`: stderr `Purge requires confirmation. Run mo purge in a terminal, or use --dry-run to preview and --yes to confirm unattended cleanup.` and **exit 1**. Verified.
- stdin not a TTY (dry run or `--yes`): **no selector and no confirmation.** It automatically selects every artifact whose activity state is not "recent" or "uncertain".
  - Recent means an mtime within 7 days, or any file inside modified within 7 days, or a check that timed out.
  - In a real run, cloud-synced items (`~/Library/CloudStorage`, `~/Library/Mobile Documents`) are also skipped, with the message `◎ Skipped N cloud-synced artifacts in non-interactive mode (confirmation required)`.
  - Recent items are **not printed at all** without a TTY.
- **In a real run without a stdout TTY, removed items are not printed** (`elif [[ -t 1 ]]`, `:2704`). Only the summary appears. For per-item progress, tail `operations.log` (`[purge] REMOVED <path> (<size>)`) or use a PTY for stdout.
- Dry run prints each item regardless of TTY.
- `--yes` never prompts. With a TTY on stdin, the menu and confirmation still appear even with `--yes`; `--yes` only lifts the non-TTY refusal.

### Scan
- Roots come from the config file, or discovery, or the defaults.
  - Defaults (`purge_shared.sh:55-73`): `~/www ~/dev ~/Projects ~/GitHub ~/Code ~/Workspace ~/Repos ~/Development ~/Library/CloudStorage ~/.codex/worktrees ~/.claude/worktrees`.
  - Discovery also checks each `~/*/` for project markers at depth 2 or less, within a 15 s budget.
- Targets (`purge_shared.sh:18-53`): `node_modules target build dist venv .venv .pytest_cache .mypy_cache .tox .nox .ruff_cache .gradle .terragrunt-cache __pycache__ .next .nuxt .output vendor bin obj .turbo .parcel-cache .dart_tool .zig-cache zig-out .angular .svelte-kit .astro coverage DerivedData Pods .cxx .expo .build`, plus directories tagged with `CACHEDIR.TAG`.
- Depth 1-6 below each root. Uses `fd` if present, else `find`; `MO_USE_FIND=1` forces `find`.
- Up to 4 roots scanned in parallel. Per-root timeout `MO_PURGE_SCAN_TIMEOUT_SEC` (60).
- Protected: deployment key files, nested git repos, git-tracked content, .NET-only `bin`, global DerivedData. The clean whitelist `~/.config/mole/whitelist` is honoured (glob, parent and child matching; `app_protection.sh:613`).
- **Progress files a GUI can poll:** `${XDG_CACHE_HOME:-~/.cache}/mole/purge_scanning` (current root path, deleted at scan end), `purge_stats` (KB total so far), `purge_count`.
- Other timeouts: `MO_PURGE_ACTIVITY_TIMEOUT_SEC`, `MO_PURGE_ACTIVITY_TOTAL_TIMEOUT_SEC` (15), `MO_PURGE_SIZE_TIMEOUT_SEC` (15).
- **TCC:** scanning `~/Library/CloudStorage` failed here (`find` status 1). The GUI app, as the responsible process, needs Full Disk Access or Files & Folders permission.

### Output lines

Title/banner:
- `<YELLOW>→ DRY RUN MODE<NC>, No project artifacts will be removed` then a blank line
- `<PURPLE_BOLD>Purge Project Artifacts<NC>`
- Under a TTY: title, `\e[2J\e[H`, `\e[?25l`, and a spinner written straight to **`/dev/tty`**: `\r\e[2K<BLUE>⠋<NC> <GRAY>Scanning ~/Projects/webapp<NC>`

Scan failure:
```
◎ Skipped 1 project scan root because scanning did not complete:
  <GRAY>~/Library/CloudStorage<NC> (status 1)
<GRAY>Re-run with 'mo purge --debug' to inspect the scan failure.<NC>
```
If no root completed, the outcome is `scan_failed` and the exit code is 1.

Empty results:
- `✓ Great! No old project artifacts to clean`
- `No artifacts found in the completed project scans`
- `No eligible project artifacts to purge`
- `No artifacts found to purge`
- `No artifacts could be prepared for review`
- `No items selected`

Per-item stderr warnings:
- `◎ Could not inspect ~/…; kept`
- `◎ Could not measure ~/…; skipped`

Item lines (`:2700-2705`):
- dry run: `<GREEN>✓<NC> [DRY RUN] ~/Projects/rusty/target<NC>, <GREEN>5.0MB<NC>`
- real run, stdout TTY only: `✓ ~/path<NC>, <GREEN>size<NC>`
- Regex: `^✓ (?:\[DRY RUN\] )?(\[cloud\] )?(.+), (\S+)$`
- Skip warnings: `◎ Skipped <path> (scan root changed after review | path changed after review | activity changed after review | could not inspect contents; … | final removal check failed; …)`

Summary (`purge.sh:255-307`):
- Heading: `Purge complete` | `Dry run complete - no changes made` | `Purge incomplete` | `Dry run incomplete - no changes made`
- Detail: `Would free approximately: <GREEN>9.0MB<NC>[ + N unmeasured] | Items: 5 | Free: 93.11GB` (real run: `Estimated space freed: …`), or `No artifacts were removed.` + `Free space: …`
- `Some artifacts were skipped or could not be processed.` when incomplete
- The summary is **only printed for completed or incomplete outcomes**. For `no_candidates` and `cancelled` it is omitted.

Sizes use decimal units (`bytes_to_human`, 1000-based). The menu shows `<1d`, `Nd`, `Nmo`, `Ny`, `<7d` or `unknown` as ages.

Real samples:
- `purge_sandbox_dryrun_pipe.stdout`, `purge_sandbox_dryrun_empty.stdout`, `purge_sandbox_clean.stdout`: a stand-in `HOME` with synthetic projects.
- `purge_dryrun_pipe.stdout`: the real `HOME`; the CloudStorage scan failed, exit 1.
- `purge_sandbox_pty.raw`: full PTY run including the interactive menu.

### Interactive selector `select_purge_categories` (`project.sh:1151-1614`, only when `[[ -t 0 ]]`)
- Its own menu drawn to stdout, full screen. Non-recent rows are preselected.
- Keys via `read_key`, with no drain between keys:

| Key | Action |
|---|---|
| ↑/↓ or `k`/`j` | Move |
| ←/→ or `h`/`l` | Page |
| Home/End, `gg`/`G` | Top/bottom |
| `[` / `]` | Previous/next project |
| Space | Toggle row |
| `a` | Select all |
| `i` | Invert |
| `x` | Deselect the current project and jump to the next |
| `/` | Readline search prompt `Find project/artifact: ` |
| `n` | Next match |
| Enter | Confirm |
| `q`, Ctrl-C, EOF | Cancel |

- Rendering (real, 80 columns):
  ```
  \e[2K\e[1;35mSelect Artifacts to Purge[ [pos/total]]\e[0m
  \e[2K\e[0;38;5;244m9.0MB, 5 selected\e[0m
  \e[2K\e[0;36m➤ ● ─ ~/Projects/rusty                     5.0MB | target \e[0;38;5;244m| 1y\e[0m\e[0m
  \e[2K  ● ┌ ~/Projects/webapp                    3.0MB | node_modules …| 1y
  \e[2K  ○ ─ ~/Projects/fresh                    102KB | node_modules …| <1d
  Project: ~/Projects/webapp · 3.2MB · 2/2 selected
  Path: ~/Projects/webapp/node_modules
  ↑↓ [] Projects / Find | Enter Confirm | A All | X Skip Project | Q Quit
  ```
  Row format (`format_purge_display`, `:1125`): `%s%*s %9s | %s` = project path, padding, size, artifact name. Group markers are `─ ┌ ├ └`. Up to 50 rows per page (terminal height minus 10).
- Confirmation (`confirm_purge_cleanup`, `:1616`):
  - Prints `Selected paths:` and the list.
  - Then `➤ Remove 4 artifacts, 6.0MB[, N unknown size]  Enter confirm, ESC cancel: `.
  - Calls `drain_pending_input`, then `read -n1`. `""`, `\n`, `\r`, `y`, `Y` confirm; anything else cancels with `Purge cancelled`.
  - **Wait for this prompt text before sending Enter**, or the drain will swallow the key.
- Verified over a PTY with keys paced ~1 s apart (`j`, space, Enter, Enter): it deselected webapp/node_modules and purged the other 4 in dry-run mode.

### Paths config
- File: `~/.config/mole/purge_paths`, one path per line, `~` allowed, whitespace trimmed, `#` comments.
- Case is normalised with `/bin/pwd -P`; duplicates are dropped. Mole writes it atomically.
- An empty file means discovery or defaults are used.
- `mo purge --paths` prints status and then runs **`$EDITOR` / `$VISUAL` / `vim`** on the file. A GUI must not run it without `EDITOR=/usr/bin/true`; editing the file directly is better.
- Sample output: `purge_paths_sandbox.stdout`. Lines are `  ✓ ~/Projects`, `  ○ ~/Code, not found`, `Using custom config with N paths` / `Using N default paths`.

### Exit codes
- 0: completed, no candidates, or cancelled.
- 1: incomplete (including any skip), scan_failed, non-TTY without `--yes`, or bad option.
- 130: INT/TERM.

---

## 4. `mo installer` (`bin/installer.sh`)

### Flags
`--dry-run` / `-n`, `--debug`, `-h` / `--help`. Anything else prints `Unknown option: X` to stderr and exits 1.

### Scan locations (`:40-53`)
- `~/Downloads`, `~/Desktop`, `~/Documents`, `~/Public`, `~/Library/Downloads`, `/Users/Shared`, `/Users/Shared/Downloads`
- `~/Library/Caches/Homebrew`
- `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads`
- `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads`
- `~/Library/Application Support/Telegram Desktop`, `~/Downloads/Telegram Desktop`

Details:
- Depth `MOLE_INSTALLER_SCAN_MAX_DEPTH` (default 2).
- File types: `.dmg .pkg .mpkg .iso .xip`, plus `.zip` files whose first 50 entries contain `.app`, `.pkg`, `.dmg` or `.xip`. Symlinks are skipped.
- Source labels: Downloads, Desktop, Documents, Public, Library, Shared, Homebrew, iCloud, Mail, Telegram, or the directory name. Homebrew `sha256--` prefixes are stripped from names.

### Selector (`select_installers`, `:305-532`)
- Runs regardless of TTY and reads stdin directly with `read -r -s -n1`.
- **Nothing is selected by default.**
- Keys: `ESC [ A` / `ESC [ B` move up/down (no j/k); Space toggles; `a`/`A` all; `i`/`I` invert; `q`/`Q`/Ctrl-C/lone ESC cancel; `""`, `\n`, `\r` confirm.
- **EOF reads as an empty key, which means Enter**, so stdin `</dev/null` confirms an empty selection. The run then exits 0 after printing a blank line, and deletes nothing.
- Menu written to stdout with raw escape codes, even without a TTY:
  ```
  \e[HSelect Installers to Remove , 0B, 0 selected
  \r\e[2K
  \r\e[2K➤ ○ T3-Code-0.0.44-arm64.dmg                  142.8MB | Downloads
  \r\e[2K  ● …
  …blank filler rows…
  \r\e[2K↑↓  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit
  ```
  Row format: `%-*s %8s | %-10s` (name up to 20-40 characters wide, size, source). Rows per page are `tput lines - 6`, clamped to 3-50.
- Confirmation (`:709-725`):
  - `Files to be removed:`, then lines `  ✓ <basename> , <size>`
  - blank line, then `➤ Delete N installers, <size>  Enter confirm, ESC cancel: `
  - `read -n1`: Enter confirms; ESC, `q` or any other key cancels. No drain.
- **Verified: the menu can be driven over a pipe.** `printf 'a\r\r' | mo installer --dry-run` gives the result in `installer_dryrun_pipe_keys.stdout`. To choose item k, send `\x1b[B` k times then a space.

### Deletion
- `mole_delete path false` (never sudo). Identity and size are rechecked before each delete.
- `MOLE_DELETE_MODE=trash` moves files to Trash instead of deleting them.

### Summary (`:777-827`)
- Heading: `Dry run complete - no changes made` / `Installers cleaned` / `Installer cleanup incomplete`
- Detail lines:
  - `Would remove <G>N<NC> installers, free <G>X.XXMB<NC>` or `Removed … freed …` + `Your Mac is cleaner now!`
  - `No installers were removed`
  - `Failed to remove <Y>N<NC> installer(s)` plus up to 5 lines `◎ <path> (<reason>)`, where reason is one of: missing, changed since scan, size unavailable, still exists, delete failed, stale selection
- **Unit quirk:** the summary's "MB" is KB/1024 (binary), while list sizes are decimal. The same file showed 142.8MB in the list and 136.17MB in the summary.

Other output:
- Nothing found: `✓ Great! No installer files to clean`, printed **twice** when there is no TTY (`:251` and `:747`). Exit 0.
- Under a TTY: alt screen (`tput smcup`/`rmcup`) plus `Scanning for installers...` and `Calculating sizes...` spinners.

### Exit codes
- 0: success, cancel, empty selection, or nothing found.
- 1: any delete failure, or bad option.
- 130: INT/TERM.

Samples: `installer_dryrun_pipe.stdout`, `installer_dryrun_pipe_keys.stdout`.

---

## 5. Generic menus: `lib/ui/menu_paginated.sh`, `menu_simple.sh`, `app_selector.sh`

Both files define `paginated_multi_select`; the one sourced last wins. `optimize --whitelist` uses `menu_simple.sh`, sourced by `whitelist.sh`. Uninstall uses `menu_paginated.sh` via `app_selector.sh`. Neither is used by purge or installer.

**What they share:**
- Drawn to **stderr**: alt screen `tput smcup` (TTY only), `\e[2J\e[H`, header `Title  N/M selected`, rows `\r\e[2K➤ ●|○ label`.
- Keys come from `read_key` on stdin. EOF gives QUIT, which returns 1 (cancel).
- Result goes into global `MOLE_SELECTION_RESULT` as comma-separated indices.
- `MOLE_PRESELECTED_INDICES="0,3"` in the environment preselects rows. Whitelist and uninstall set or unset it themselves; uninstall does **not** unset it first, so an inherited value takes effect there.
- `MOLE_MANAGED_ALT_SCREEN=1` skips the alt screen.

**`menu_simple.sh`:** ↑/↓ (also `j`/`k`), Space, Enter (empty selection allowed). The `ALL`/`NONE` cases can never fire because `read_key` never returns them. No drain, so piped keys work in bulk.

**`menu_paginated.sh`:**
- Extra keys: `h`/`l` page, `s` sort mode (date/name/size, only when `MOLE_MENU_META_*` is set), `o` reverse order, `/` search mode, Backspace, Ctrl-U.
- **Enter with nothing selected selects the item under the cursor.**
- `MOLE_MENU_IGNORE_INITIAL_ENTER=1` ignores the first Enter (app_selector sets it).
- Environment inputs: `MOLE_MENU_SORT_DEFAULT` / `MOLE_MENU_SORT_MODE` / `MOLE_MENU_SORT_REVERSE`, `MOLE_MENU_META_EPOCHS` / `MOLE_MENU_META_SIZEKB` (CSV), `MOLE_MENU_FILTER_NAMES` (newline-separated).
- **Calls `drain_pending_input` after every key** (`:1002`), so keystrokes that arrive within about 10 ms of each other are dropped. Pace keys at 50 ms or more, ideally after each redraw.
- Moving the cursor redraws only the affected rows with `\e[<row>;1H`, which makes the output harder to parse.

**`app_selector.sh`** (`select_apps_for_uninstall`): builds rows with `format_app_display` and pipe-separated app data (`epoch|path|name|…|size|last_used|size_kb`), exports the metadata variables, then calls `paginated_multi_select "Select Apps to Remove"`.

**Non-interactive bypass:**
- No command in scope has a `--select` or `--yes` style argument except `purge --yes`, which selects all non-recent items.
- The menus cannot be bypassed through environment variables other than preselection.
- Ways to get subset selection:
  1. Installer: pipe keys to stdin.
  2. Purge: use a PTY and drive `select_purge_categories`, or narrow the scope with `purge_paths` or clean-whitelist entries (the latter changes the user's config).
  3. Optimize whitelist: write the file directly.

---

## 6. Upstream docs and issues (v1.56.0)
- **No machine-readable output for optimize, purge or installer.** JSON exists only for `mo analyze --json`, `mo status --json`/`--watch` (NDJSON) and `mo history --json`, per the README.
- Documented environment variables: `MO_NO_OPLOG=1`, `MOLE_ENABLE_DISK_VERIFY=1`, `MO_LAUNCHER_APP`. `NO_COLOR` and non-TTY colour were fixed in issue #1522, matching `base.sh`.
- README: "Non-interactive runs require `mo purge --yes`". Recent-activity artifacts are unselected by default. Scan depth is 6.
- `docs/SECURITY_DESIGN.md` lists `MOLE_DRY_RUN=1`, `MOLE_TEST_NO_AUTH=1` and `MOLE_OPLOG_PATH`; the last is not used by v1.56.0 code.
- Release notes for V1.56.0: optimize no longer rebuilds LaunchServices, and LaunchAgents are now report-only.
- No `SUDO_ASKPASS` support. Issue #1563 (corporate sudo prompt) is open-ended.
- Upstream sells a separate native GUI, "Mole Mac App" (mole.fit), which is not open source.

Files are in `<scratch>/`:
- research/optimize_dryrun_pipe.stdout
- research/optimize_dryrun_pty.raw
- research/optimize_dryrun_pty_color.raw
- research/optimize_whitelist_eof.stdout
- research/optimize_whitelist_eof.stderr
- research/purge_dryrun_pipe.stdout
- research/purge_dryrun_debug.stdout
- research/purge_dryrun_debug.stderr
- research/purge_sandbox_dryrun_pipe.stdout
- research/purge_sandbox_dryrun_pipe.stderr
- research/purge_sandbox_dryrun_empty.stdout
- research/purge_sandbox_clean.stdout
- research/purge_sandbox_pty.raw
- research/purge_paths_sandbox.stdout
- research/purge_noyes.stderr
- research/installer_dryrun_pipe.stdout
- research/installer_dryrun_pipe_keys.stdout
- sbhome/ (stand-in `HOME` with synthetic projects)
- ttytest.py (shows that `/dev/tty` passes the access check but will not open without a terminal)

---

# uninstall+touchid+history+manage

# Mole v1.56.0 research: `uninstall`, `touchid`, `history`, `completion`, `update`, `remove`

Source root is `/opt/homebrew/Cellar/mole/1.56.0/libexec` (called `L/` below). Captured outputs are in `R/` = `<scratch>/research/`.

Everything below was observed on this Mac, under Mole 1.56.0 and sudo 1.9.17p2, unless it is marked "from source".

## Read this first: four problems that affect the whole GUI

1. **An empty or closed stdin counts as "confirm" at every single-key prompt.** These prompts all use `IFS= read -r -s -n1 key || key=""`, and then treat `""` the same as Enter:
   - the uninstall final confirm (`L/lib/uninstall/batch.sh:1792-1802`)
   - `mo remove` (`L/lib/manage/remove.sh:195-203`)
   - the `mo touchid` menu with no subcommand (`L/bin/touchid.sh:300-328`)
   - `mo completion` with no arguments (`L/bin/completion.sh:268-279`)

   **Incident during research:** I ran `mo touchid </dev/null` with no subcommand. It took the Enter branch and tried to enable Touch ID. It failed harmlessly, printing `sudo: a terminal is required to read the password…`. I checked afterwards: `/etc/pam.d/sudo_local` still does not exist, and nothing changed. I did not run it again.

   The GUI must never start `mo remove`, bare `mo touchid` or bare `mo completion` with stdin at EOF.

2. **Mole's own sudo request cannot work under pipes with no controlling TTY.**
   - `request_sudo_access` (`L/lib/core/sudo.sh:84-93`) decides it is in "GUI mode" (which shows an osascript password dialog) only when `[[ -r /dev/tty && -w /dev/tty ]]` is false.
   - I tested a `setsid` child with no controlling TTY. That check passes (`RW_OK`), but opening `/dev/tty` fails (`Device not configured`). So the osascript branch is never reached.
   - The code then runs `_request_password "/dev/tty"`. The redirect `sudo -v < /dev/tty` fails before sudo even starts, so the result is always "Admin access denied".
   - Even when a credential is cached, sudoers says: "If no terminal is present, the behavior is the same as ppid". Mole's later `sudo -n …` calls run from other parent processes (subshells, the perl timeout wrapper), so they do not inherit that credential.
   - Mole 1.56.0 does not use `SUDO_ASKPASS` anywhere. `grep -rn askpass` finds only git-related `GIT_ASKPASS=/usr/bin/false`. Upstream PR #1004, which proposed askpass support, was closed.
   - **Recommendation:** run any flow that may need admin rights under a pseudo-terminal. You can use openpty with setsid and TIOCSCTTY, or simply wrap the command in `/usr/bin/script -q /dev/null /opt/homebrew/bin/mo …`. Then sudo's ticket is tied to that terminal, and the GUI writes the password when the prompt appears (formats are in the Sudo section).

3. **GUI apps start with a minimal PATH.** Mole checks for tools with `command -v brew`, `command -v mole`, `command -v trash`, `perl` and `gtimeout`. Set `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` in the child's environment. Otherwise:
   - Homebrew cask detection silently turns off: `is_homebrew_available` in `L/lib/uninstall/brew.sh:34` fails, and every app shows as source "App".
   - `mo completion` fails with "mole not found in PATH".

4. **Colours depend on the terminal, but other escape codes do not.** Colour codes appear only when stdout is a TTY, `TERM` is not `dumb` and `NO_COLOR` is empty (`L/lib/core/base.sh:34-40`). Under pipes there is no colour at all.
   - Some raw escapes are still printed. For example, `clear_screen` (`L/lib/core/ui.sh:27`) always prints `\e[2J\e[H` to stdout. It is used in `L/bin/uninstall.sh:1752,1865`.
   - Strip `\e\[[0-9;?]*[A-Za-z]` and `\r` before parsing.
   - Glyph constants are in `L/lib/core/base.sh:99-113`: ✓ `ICON_SUCCESS`, ☻ `ICON_ERROR`, ◎ `ICON_CONFIRM` and `ICON_WARNING`, • `ICON_LIST`, ↳ `ICON_SUBLIST`, ➤ `ICON_ARROW`, → `ICON_DRY_RUN`, ⊙ `ICON_REVIEW`, ℹ `ICON_INFO`.
   - Colour escapes (`L/lib/core/base.sh:53-62`): GREEN `\e[0;32m`, BLUE `\e[1;34m`, CYAN `\e[0;36m`, YELLOW `\e[0;33m`, PURPLE `\e[0;35m`, PURPLE_BOLD `\e[1;35m`, RED `\e[0;31m`, GRAY `\e[0;38;5;244m`, NC `\e[0m`.

Other points that apply to every command:
- The entry point `mole` refuses to run as root (`EUID==0` → stderr message and exit 1, `L/mole:10-13`).
- `--debug`, anywhere in the arguments, is removed from the list and exports `MO_DEBUG=1` (`L/mole:59-74`).
- Unknown commands print `Unknown command: X` to stderr and exit 1.

---

## 1. `mo uninstall` (`L/bin/uninstall.sh`, `L/lib/uninstall/{batch,brew,steam}.sh`)

### Flags (`L/bin/uninstall.sh:1677-1710`)

| Flag | Effect |
|---|---|
| `--list` | Read-only listing that exits before any destructive code. It ignores name arguments and `--dry-run`. |
| `--dry-run`, `-n` | Exports `MOLE_DRY_RUN=1`. |
| `--permanent` | Sets `MOLE_DELETE_MODE=permanent`. The default is `${MOLE_DELETE_MODE:-trash}` (line 1672), so the environment variable is also respected. |
| `--debug` | Sets `MO_DEBUG=1`. Adds `[DEBUG] …` lines on stderr and writes `~/Library/Logs/mole/mole_debug_session.log`. |
| `-h`, `--help` | Help, exit 0. |
| `--whitelist` | Error, exit 1. Uninstall has no whitelist. |
| any other `-*` | `Unknown uninstall option: X` on stderr, exit 1. |
| other words | App names. Several can be given. |

No arguments opens the interactive paginated selector, which the GUI should not use. On EOF, `read_key` returns QUIT, so it exits 0 quietly (from source: `L/lib/ui/menu_paginated.sh:656-675`).

### `--list` (lines 1553-1663)

**Output mode switches automatically:** it prints JSON when stdout is not a TTY (`[[ ! -t 1 ]]`, line 1572), and a text table otherwise.

Observed: exit 0, 42 apps, stderr empty in pipe mode. Runs took 33 s cold and 21 s warm, mostly spent on Homebrew cask detection for each app. Captures are `R/uninstall_list.json` (cold), `R/uninstall_list_warm.json` and `R/uninstall_list_tty.txt`.

The JSON is an array of objects, one per line, with 2-space indent. The printf is at line 1597:
```
[
  {"name": "Example Security Agent", "bundle_id": "com.example.securityagent", "source": "App", "uninstall_name": "Example Security Agent", "path": "/Applications/ExampleAgent.app", "size": "56.4MB"},
  {"name": "LinearMouse", "bundle_id": "com.lujjjh.LinearMouse", "source": "Homebrew", "uninstall_name": "linearmouse", "path": "/Applications/LinearMouse.app", "size": "12.9MB"},
  ...
]
```

All fields are strings:

| Field | Meaning |
|---|---|
| `name` | Display name, localized (see resolution order below). Can contain invisible characters; for example WhatsApp appears as `"\u200eWhatsApp"` in raw UTF-8. |
| `bundle_id` | `CFBundleIdentifier`, or `"unknown"`. |
| `source` | `"App"` or `"Homebrew"`. |
| `uninstall_name` | The cask token if Homebrew, otherwise the same as `name`. |
| `path` | Absolute `.app` path. |
| `size` | `"12.9MB"`, `"3.96GB"`, `"4KB"`, `"--"` (unknown size), `"N/A"`, or `"N/A (Steam-managed)"`. |

Details and caveats:
- **Escaping is minimal** (`uninstall_list_json_escape`, line 1539). It only handles `\`, `"`, and turns tab, CR and LF into spaces. Other control bytes pass through unescaped.
- **Rows are sorted by last-used time, oldest first** (`sort -t'|' -k1,1n`, line 1155). The JSON has no last-used field.
- **Cold runs show `"--"` for many sizes.** 22 of 42 apps had it on the first run, because sizes are filled in by a background refresh that is not waited for. The second run had them all. Treat `"--"` as unknown and refresh later.
- **Size format** comes from `human_size` (lines 1023-1040) and `bytes_to_human` (`L/lib/core/base.sh:768`). It uses decimal units: ≥1e9 → `%d.%02dGB`, ≥1e6 → `%d.%01dMB`, ≥1e3 → `%dKB`, otherwise `%dB`.

**Text table** (TTY only). Header, then 108 dashes, then rows with `%-36s %-30s %-30s %8s`. Bundle ID and uninstall name are cut to 28 characters. The footer is `\n42 application(s)  |  Remove with: mo uninstall <UNINSTALL NAME>\n\n`.

While scanning, the TTY spinner goes to stderr only if `-t 2`: `\r\e[K<frame> Scanning applications... N/M`, followed by "Merging cache data...", "Collecting metadata...", "Updating cache...", "Sorting application list...", "Finalizing list..." (lines 985-1165, 1249-1276).

**Where apps are found** (lines 488-515, 636-647):
- `find <dir> -maxdepth 3 -iname '*.app'` over `/Applications`, `~/Applications`, `/Library/Input Methods`, `~/Library/Input Methods`, and `/Volumes/*/Applications`.
- Plus pkgutil-receipt apps in non-standard places (`L/lib/core/pkg_receipts.sh`, cached in `~/.cache/mole/pkg_receipt_apps_v1` with a 3600 s TTL, keyed by receipt fingerprint).
- Excluded:
  - apps nested inside another `.app`
  - symlinks into `/System`, `/usr/bin` and similar
  - bundle IDs that are protected (`should_protect_from_uninstall` with `SYSTEM_CRITICAL_BUNDLES` in `L/lib/core/app_protection_data.sh:19`, minus `APPLE_UNINSTALLABLE_APPS` at `:163`)
  - `LSBackgroundOnly` apps that are not directly in a search root
- Duplicates are removed by bundle ID plus basename, preferring `/Applications` over `~/Applications` over other places over `/Volumes` (lines 903-972).

**Display name resolution** (lines 220-288), in order: the bundle's localized `InfoPlist.strings` for the user's AppleLanguages → `mdls kMDItemDisplayName` (0.04 s timeout) → `CFBundleDisplayName` → `CFBundleName`. Versioned basenames such as `Xcode-beta` are kept.

**Metadata cache** that a GUI can read directly: `~/.cache/mole/uninstall_app_metadata_v3`, with lock directory `…v3.lock`. One line per app, split on `|`:
```
path|app_mtime|size_kb|last_used_epoch|updated_epoch|bundle_id|display_name|lang_signature
/Applications/VLC.app|1789657290|150676|1789736879|1790782002|org.videolan.vlc|VLC|1078222241:11
```
This is written at line 420 and line 1141. `last_used_epoch` comes from `mdls kMDItemLastUsedDate` (0 means unknown). The refresh TTL is 7 days.

### How names are matched (`match_apps_by_name`, lines 1405-1533)
Matching is case-insensitive and runs against both the display name and the `.app` basename without `.app`.

- **Several words:** if not every word exactly names an app, the words are joined with spaces and tried as one exact name. This makes `mo uninstall Tor Browser` work.
- **For each term:** an exact match comes first, and only the first exact hit is taken. If there is none, every app whose name contains the term as a substring is selected, so one term can select several apps.
- **No match:** stdout shows `Warning: No application found matching 'X'`.
- **No matches at all:** stdout shows `No matching applications found.` and the exit code is 1.

Two cautions:
- **Cask tokens are not matched.** The `uninstall_name` from `--list` is a cask token for Homebrew apps. That only works when it happens to equal the app name case-insensitively, as `linearmouse` does for LinearMouse. **The GUI should pass the `.app` basename without `.app`, as one argument per app**, and check the "Matched N app(s)" list against what it expected.
- **Watch for substring over-matching.**

### Direct uninstall flow, prompts and output (pipe mode)

Samples: `R/un_dry_pipe.out`, `R/un_dry_multi.out`, `R/un_dry_devnull.out`, with the TTY version in `R/un_dry_tty.txt` and `R/un_dry_tty_color.txt`.

```
→ DRY RUN MODE, No app files or settings will be modified        (only with --dry-run; colour: \e[0;33m→ DRY RUN MODE\e[0m, …)
<blank>
\e[2J\e[H◎ Matched 3 app(s):                                        (◎ is BLUE; the clear-screen escape appears even under a pipe)
1. LinearMouse  12.9MB  |  Last: 1w ago                             format "%d. %s  %s  |  Last: %s"
2. VLC  154.3MB  |  Last: 1w ago
3. Example Enterprise App  140.8MB  |  Last: Yesterday
<blank>
Proceed with uninstallation? [y/N]                                  (no newline; this is PROMPT 1)
```

- `Last:` values (`format_last_used_summary`, `L/lib/core/ui.sh:487`): `Today`, `Yesterday`, `Nd ago`, `Nw ago`, `Nm ago` (months), `Ny ago`, `Unknown`.
- Size is `N/A`, `N/A (Steam-managed)`, or a human size.

**PROMPT 1** is a line read, `read -r confirm` (line 1769).
- Only exactly `y` or `Y` continues.
- Anything else prints `Aborted.` and exits 0.
- **EOF, as with `</dev/null`, aborts under `set -e` with exit 1 and no message** (observed).

Next comes the per-app scan, which is silent in pipe mode. In TTY mode a `Scanning files...` spinner goes to stderr. Warnings can print directly after the prompt with no newline between them, for example:
```
Proceed with uninstallation? [y/N] Example Enterprise App requires the official vendor uninstaller
```
Possible messages (all plain stdout via `log_warning`, or stderr `☻ msg` via `log_error`):
- `<App> requires the official <Vendor> uninstaller` (`OFFICIAL_UNINSTALLER_RULES` in `L/lib/core/app_protection_data.sh:179` covers ESET, Jamf, CrowdStrike, SentinelOne, GlobalProtect and Cisco)
- `<App> cannot be removed safely by Mole from this location` + `Move it to Trash in Finder; Mole left protected containers and app data untouched`
- `<App>: some paths could not be read, so shared leftovers are left in place`
- `<App>: leftover scan timed out; only the app bundle will be removed`
- stderr: `☻ Could not finish the uninstall scan (<stage>, exit N); nothing was removed`, `☻ The uninstall scan timed out before finishing; nothing was removed`, `☻ Could not verify whether other installs share X's bundle id; nothing was removed`

If every selected app is blocked, the run exits 1 with no further output (observed with "Example Enterprise App").

Then the preview, from `_batch_preview_and_confirm` (lines 1697-1832):
```
<blank>
Files to be removed:                                                  (\e[1;35m…\e[0m)
◎ Homebrew apps will be fully cleaned, --zap removes configs and data (GRAY; only if a cask will be zapped)
<blank>
◎ LinearMouse [Brew] , 13.7MB                                         (BLUE ◎, CYAN [Brew], GRAY ", size")
  ✓ /Applications/LinearMouse.app , 12.9MB                            (GREEN ✓; "  ✓ <path> , <size>", size part omitted when 0)
  ✓ ~/.config/LinearMouse , 4KB
  ✓ ~/Library/Caches/org.videolan.vlc                                 (no size)
  ◎ System: /Library/...                                              (BLUE; currently always empty, see below)
  ◎ Review only: /Library/LaunchDaemons/...                           (YELLOW; system files Mole will NOT delete)
  ◎ Steam launcher only; game files managed by Steam are not included (Steam launchers)
<blank>
➤ Remove 2 apps, 168.1MB [Running]  Enter confirm, ESC cancel:        (PROMPT 2, no newline)
```
- Paths use `~` for `$HOME` (`format_uninstall_preview_path`, lines 209-226).
- The line format is `"  ✓ " + path + " " + GRAY + ", " + size + NC`, so the GUI can split on the last `" , "` once escapes are stripped.
- `[Running]` appears if any app's `CFBundleExecutable` is running (`pgrep -x`).
- System-level leftovers are review-only by design: `system_files` is always emptied (lines 1619-1627).

**PROMPT 2** is a single-key read: `drain_pending_input; IFS= read -r -s -n1 key || key=""; drain_pending_input` (lines 1791-1793).
- **Confirms:** `""` (which includes EOF), `\n`, `\r`, `y`, `Y`.
- **Cancels:** ESC, `q`, `Q`, or any other key. Cancel exits 0 and prints only two blank lines.
- Observed: `printf 'y\n' | mo uninstall --dry-run VLC` ran to completion, because EOF counted as confirm. `(printf 'y\n'; sleep 30; printf q)` cancelled, exit 0.
- **The drain problem:** `drain_pending_input` reads and throws away stdin until it has been idle for 0.01 s (`L/lib/core/ui.sh:271-280`). Bytes written before the prompt, or within about 10 ms of it, are lost, and a GUI that keeps stdin open would then hang.
- **Recommended GUI protocol:**
  - write `y\n` after PROMPT 1 appears
  - wait for the text `Enter confirm, ESC cancel: `
  - to confirm, close stdin (EOF), or write `\n` at least 100 ms later
  - to cancel, write `q` after the same delay, or send SIGTERM (nothing has been changed at that point)

After confirmation, sudo may be requested (see the Sudo section). The execution phase is silent under pipes, because all spinner and `✓ [i/N] name` lines are guarded by `[[ -t 1 ]]`. Output that still appears:
- Raw `brew uninstall --cask [--zap] <token>` output, merged from stderr into stdout, because `brew_uninstall_cask` does not capture it (`L/lib/uninstall/brew.sh:357-369`).
- `  ◎ Could not remove: ~/…` for each leftover that survived (line 2292).

In TTY mode the spinners on stderr are `Uninstalling X...`, `[i/N] Uninstalling X [Brew]...`, `Removing X (size)...`, `Cleaning files for X...`, `Cleaning system files for X...`. The failure lines `☻ X failed: reason` and `☻ [i/N] X , reason` + `   ⊙ suggestion` are printed **only when stdout is a TTY** (lines 2339-2348).

The summary comes from `_batch_render_summary` (lines 2363-2525) and `print_summary_block` (`L/lib/core/log.sh:399`). The divider is `=` repeated `min(tput cols, 70)` times.
```
<blank>
======================================================================
Uninstall complete | Uninstall incomplete | Uninstall dry run complete     (BLUE)
Removed 2 apps, freed 168.1MB: LinearMouse, VLC     (dry run: "Would remove N app(s), would free X: …"; max 3 names per line, extra lines hold only names)
• Failed: <names separated by spaces> <reason_summary>
⊙ <suggestion>                                      (only when exactly 1 failed)
⊙ Kept N system-level path(s), which Mole never removes
⊙ System extensions may remain after removal: A, B
↳ Check System Settings > General > Login Items & Extensions to remove leftover extensions
⊙ Background item still running for A, turn it off in System Settings > Login Items & Extensions
⊙ Still running during uninstall, files removed but process kept alive: A
↳ Quit the app to free its in-memory copy; reinstalling before quitting may behave oddly
No applications were uninstalled.
======================================================================
Debug session log saved to: …                       (only with --debug)
<blank>
[DRY RUN] Would refresh LaunchServices and update Dock entries   (BLUE; dry run only)
```
Failure reason strings (lines 1883-2155): `selected app changed after preview`, `the app installation set changed after preview`, `unable to verify …`, `brew uninstall failed, package still installed` (suggestion `Run brew uninstall --cask --zap <token>`), `brew uninstall failed, package state unknown`, `brew cleanup incomplete, manual removal failed`, `protected system symlink, cannot remove`, `failed to remove symlink`, `parent directory not writable`, `remove failed, check permissions`, and diagnoses from `diagnose_removal_failure`.

### Exit codes
| Case | Code |
|---|---|
| Success | 0 |
| Some apps failed (summary says "Uninstall incomplete") | **0**. Parse the title. |
| PROMPT 1 answered "no" | 0 |
| PROMPT 2 cancelled | 0 |
| Interactive selector quit | 0 |
| PROMPT 1 hit EOF | 1 |
| No match | 1 |
| Every app blocked or unsafe | 1 |
| Scan failure or timeout | 1, or the scan's return code (124 for timeout) |
| Sudo denied | 1 (`☻ Admin access denied` on stderr) |
| Interrupted | 130 |

### Dry-run guarantees (verified in source and by running)
- Nothing is deleted, unloaded, killed or unregistered.
- Mole still writes: `deletions.log` rows with status `dry-run`, an operations-log session, `mole.log`, and the metadata cache.
- `brew_uninstall_cask` returns 0 in dry run without calling brew (line 325).
- A dry run of a single small app took about 40 s (the leftover scan is slow).
- `--debug` stderr shows the planned actions:
  ```
  [DEBUG] [DRY RUN] Would unload launch services for bundle: com.anthropic.claude-code-url-handler
  [DEBUG] [DRY RUN] Would remove login item: Claude Code URL Handler
  [DEBUG] [DRY RUN] Would terminate running app: Claude Code URL Handler
  [DEBUG] [DRY RUN] Would delete (trash): /Users/…/Claude Code URL Handler.app
  [DEBUG] [DRY RUN] Would clear defaults domain: com.anthropic.claude-code-url-handler
  [DEBUG] Skipping incomplete uninstall discovery root: /Users/…/Library/Application Support   (a sign of missing Full Disk Access)
  ```
  Capture: `R/un_dry_debug.{out,err}`.

### Trash vs `--permanent`, sudo needs, Homebrew and Steam
- **Trash (default):**
  - App bundles and direct children of `~/Library/Containers`, `Group Containers` and `Application Scripts` are moved to Trash directly. If that is denied by privacy protections, the bundle is sent through Finder with `osascript tell application "Finder" to delete`.
  - Other files go through the `trash` CLI if present, otherwise the same Finder osascript (`L/lib/core/file_ops.sh:2550-2626`).
  - The GUI app will therefore likely need **Automation permission for Finder and System Events** (login items are removed via osascript in `L/lib/uninstall/batch.sh:500-530`), **App Management**, and **Full Disk Access**.
- **needs_sudo** (lines 1504-1512): true if the app's parent directory is not writable, or in `--permanent` mode if the app is owned by root or another user. For admin users, `/Applications` is writable, so most trash-mode uninstalls need no sudo.
- **Homebrew casks:**
  - Detection (`get_brew_cask_name`, `L/lib/uninstall/brew.sh:275`) tries four stages: the resolved path is in the Caskroom → a `find` in the Caskroom by bundle name with `brew list --cask` and `brew info --cask` checks → a symlink into the Caskroom → a case-insensitive `brew list --cask` match checked with `brew info`.
  - Removal runs `HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 brew uninstall --cask --zap <token>`, with a 300 s timeout (600 s above 5 GB, 900 s above 15 GB). It uses `nozap` (no `--zap`) when another install shares the bundle ID. Removal is then verified.
  - **Any cask in the batch forces `ensure_sudo_session` before execution, even in trash mode** (lines 1817-1831). The prompt text is `Admin required for Homebrew casks: A B`. Afterwards Mole runs `brew autoremove` in the background.
- **Steam launchers** (`L/lib/uninstall/steam.sh`): a bundle of at most 4 KB whose executable is a shell script with a single `open steam://run/<id>` line. Its size shows as `N/A (Steam-managed)` and the preview adds a note. Only the launcher is removed.

### Sudo mechanics (`L/lib/core/sudo.sh`)
`ensure_sudo_session(prompt)` works like this:
1. If `sudo -n true` succeeds, done.
2. Otherwise `request_sudo_access`:
   - **TTY branch:**
     - It prints `➤ <prompt>` to stdout.
     - If Touch ID is set up in PAM and the lid is open, the stdout line becomes `➤ <prompt> , Touch ID or password` (with `, Touch ID or password` in GRAY). It runs `sudo -v </dev/null &` and gives Touch ID up to 5 s.
     - Otherwise it writes to `/dev/tty`: `Note: Touch ID dialog may appear once more, just cancel it` (only when Touch ID is configured), then `➤ Enter your credentials:`, then sudo's own `Password:`, then runs `sudo -v </dev/tty 2>/dev/tty`.
     - The prompt lines are cleared afterwards.
   - **"GUI mode" branch** (osascript `display dialog … with hidden answer`, then `sudo -S -v`): unreachable when spawned without a controlling TTY, as explained in the "Read this first" section.
3. A keepalive runs `sudo -n -v` every 30 s.

In test mode (`MOLE_TEST_MODE=1` or `MOLE_TEST_NO_AUTH=1`) authentication always fails. Do not use these variables in production: they also force colours on and change other behaviour.

Observation: `/etc/sudoers.d/mole` (mode 0440, 60 bytes, dated Sep 18) and `~/.config/mole/sudoers-version` (`mole-v61`) exist on this Mac. Nothing in mo 1.56.0 refers to them, so they probably come from another tool, possibly the paid "Mole for Mac" app. I could not read the file without sudo.

### Environment variables relevant to uninstall
| Variable | Effect |
|---|---|
| `MOLE_DRY_RUN=1` | Same as `--dry-run`. |
| `MOLE_DELETE_MODE` | `trash` or `permanent`. |
| `MO_DEBUG=1` | Debug output. |
| `MO_NO_OPLOG=1` | Disables `operations.log`. |
| `MOLE_DELETE_LOG` | Path of the deletions log. |
| `NO_COLOR` | Disables colour. |
| `MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC` | Default 0.04. |
| `MOLE_UNINSTALL_INLINE_MDLS_SIZE_TIMEOUT_SEC` | Default 0.04. |
| `MOLE_UNINSTALL_INLINE_DU_SIZE_TIMEOUT_SEC` | Default 2. |
| `MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS` | Default 20. |
| `MOLE_PKG_RECEIPT_CACHE_FILE`, `_TTL` (3600), `_CACHE_DISABLE`, `_LIST_TIMEOUT` (3), `_SCAN_TIMEOUT` (8) | Package receipt scan. |
| `MOLE_TIMEOUT_QUICK_DETECT_SEC` (2), `_SHORT_QUERY_SEC` (3), `_MEDIUM_PROBE_SEC` (5), `_PKG_LIST_SEC` (10), `_PKG_CLEANUP_SEC` (20), `_DISK_VERIFY_SEC` (30), `_HINT_SCAN_SEC` (15) | Timeouts, from `L/lib/core/timeouts.sh`. |
| `SUDO_USER` | If set, brew runs as `sudo -u $SUDO_USER`. |

The uninstall command has no config or whitelist file.

---

## 2. `mo touchid` (`L/bin/touchid.sh`)
**Usage:** `mo touchid [enable|disable|status] [--dry-run|-n] [-h]`. Only one subcommand is allowed per run; a second prints `☻ Only one touchid command is supported per run` on stderr and exits 1. An unknown argument prints `☻ Unknown command: X` and exits 1.

**Detection:** Mole greps for `pam_tid.so` in `/etc/pam.d/sudo_local` first, then `/etc/pam.d/sudo`. These paths can be overridden with `MOLE_PAM_SUDO_FILE` and `MOLE_PAM_SUDO_LOCAL_FILE`. **The GUI can check this itself without running mo.**

**`status`**, observed with exit 0:
- `☻ Touch ID is not configured for sudo` (☻ is YELLOW)
- or `✓ Touch ID is enabled for sudo` (✓ is GREEN)

**`--dry-run enable`**, observed with exit 0:
```
→ DRY RUN MODE, No sudo authentication files will be modified
<blank>
✓ [DRY RUN] Would enable Touch ID for sudo
⊙ Target files: /etc/pam.d/sudo and/or /etc/pam.d/sudo_local
```
If Touch ID is already on, it prints `✓ Touch ID is already enabled, no changes needed` instead.

**`--dry-run disable`**, observed with exit 0: `Touch ID is not currently enabled`, or `✓ [DRY RUN] Would disable Touch ID for sudo` followed by the target-files line.

**Real `enable` and `disable`:**
- They call plain `sudo tee`, `sudo install -m 444 -o root -g wheel`, `sudo chmod` and `sudo cp`. There is no `ensure_sudo_session`.
- Without a TTY they fail with `sudo: a terminal is required…` (observed during the incident). **They need a PTY**; sudo prompts `Password:` on it.
- On macOS Sonoma and later, `/etc/pam.d/sudo` includes `sudo_local`, so enable writes `/etc/pam.d/sudo_local` containing `auth       sufficient     pam_tid.so`. Older systems use the legacy edit with a `/etc/pam.d/sudo.mole-backup` backup.
- If `supports_touchid` fails, there is an extra `read -rp "Continue anyway? [y/N] "`.
- Result lines:
  - `  ✓ Touch ID enabled, via sudo_local, try: sudo ls`
  - `  ✓ Touch ID migrated to sudo_local`
  - `✓ Touch ID is already enabled`
  - `✓ Touch ID disabled, removed from sudo_local`
  - `✓ Touch ID disabled`
  - on stderr: `☻ Failed to …`

**Bare `mo touchid`** shows a menu: `☛ Press Enter to enable, Q to quit: ` (or "to disable"). It reads one key, and EOF counts as Enter. **Avoid it.**

The main menu's own check is `grep -q pam_tid.so /etc/pam.d/sudo /etc/pam.d/sudo_local` (`L/mole:100`).

---

## 3. `mo history` (`L/bin/history.sh`, `L/lib/core/history.sh`)
This command is dispatched early (`L/mole:76-89`), before `common.sh` loads. It is fast (0.2 s) and read-only.

**Flags:**
- `--json`
- `--limit N` (1-200, default 20). 0, more than 200, or a non-number prints `Invalid value for --limit: X` on stderr and exits 1. A missing value prints `Missing value for --limit`.
- `-h`
- Unknown options print `Unknown option for mo history: X`; stray arguments print `Unexpected argument…`. Both exit 1.

**Sources:**
- operations log: `${MOLE_OPERATIONS_LOG:-$HOME/Library/Logs/mole/operations.log}`
- deletions log: `${MOLE_DELETE_LOG:-$HOME/Library/Logs/mole/deletions.log}`

**JSON schema** (source: `L/lib/core/history.sh:480-564`; observed in `R/history.json`):
```json
{
  "logs": {"operations": "<string path>", "deletions": "<string path>"},
  "limit": 50,
  "sessions": [                        // newest first, at most `limit`
    {
      "command": "uninstall",          // clean|uninstall|optimize|purge|installer|…
      "started_at": "2026-09-30 16:31:56",   // "YYYY-MM-DD HH:MM:SS" local time, no zone
      "ended_at": "2026-09-30 16:33:01",     // "" if the end marker is missing
      "items": 1,                      // integer (0 if missing)
      "size": "13.7MB",                // string, "0B" default
      "operation_count": 3,            // integer
      "failed_tasks": 0,               // integer (optimize TASK_FAILED)
      "actions": {"removed": 0, "trashed": 0, "skipped": 3, "failed": 0, "rebuilt": 0, "other": 0}   // integers
    }
  ],
  "deletions": [                       // newest first, at most `limit` (separate from sessions)
    {"timestamp": "2026-09-30T16:33:00+0100", "mode": "trash", "status": "dry-run", "size_kb": 4, "path": "/Users/…/com.lujjjh.LinearMouse.plist"}
  ]
}
```

| Field | Type | Values |
|---|---|---|
| `mode` | string | `trash` or `permanent` |
| `status` | string | `ok`, `dry-run`, `rejected`, `identity-changed`, `mutable-parent`, `privacy-denied`, `trash-failed`, `timed-out`, `interrupted`, `error`, `invalid-mode`, `sudo-blocked-test-mode` |
| `size_kb` | integer or `null` | `null` when unknown |

String escaping handles `\ " \b \f \n \r \t`, and other control characters below 0x20 become `\u00XX`.

**Caveats:**
- Dry-run uninstall sessions look like real ones: they log items and size, and there is no dry-run flag. Only the deletions entries' `status: "dry-run"` shows the difference.
- Concurrent mo runs write to the same file, so sessions can get mixed together. This happened during research, with `[clean]` lines landing inside an uninstall session.

**Text output** (`R/history_text.txt`):
```
<blank>
Mole History
<blank>
Recent sessions
  uninstall  2026-09-30 16:31:56, 1 items, 13.7MB                   "  %-10s %s, %s items, %s"
             no file actions, ended 2026-09-30 16:33:01             counts text: "removed N, trashed N, skipped N, failed N, rebuilt N, other N" or "no file actions"; ", N optimize tasks failed"; "ended not ended"
<blank>
Deletion audit
  2026-09-30T16:33:00+0100 trash     dry-run               4KB  /path     "  %-24s %-9s %-16s %8s  %s"
<blank>
Logs
  operations: …/operations.log
  deletions:  …/deletions.log
```

**Underlying log formats:**
- **operations.log** (`L/lib/core/log.sh:214-265`, rotated to `.old` above 5 MB):
  - `\n# ========== <cmd> session started at YYYY-MM-DD HH:MM:SS ==========`
  - `[YYYY-MM-DD HH:MM:SS] [<cmd>] <ACTION> <path>[ (<detail>)]`, where ACTION is `REMOVED`, `TRASHED`, `SKIPPED`, `FAILED`, `REBUILT` or `TASK_FAILED`
  - `# ========== <cmd> session ended at <ts>, <items> items, <size> ==========`
- **deletions.log** (`L/lib/core/file_ops.sh:3076`): tab-separated `<ISO ts %Y-%m-%dT%H:%M:%S%z>\t<mode>\t<size_kb|unknown>\t<status>\t<path>`.
- **mole.log** (rotated above 1 MB): `[ts] INFO|SUCCESS|WARNING|ERROR: msg`.
- **mole_debug_session.log**: reset each `--debug` session.

---

## 4. `mo completion` (`L/bin/completion.sh`)
- **`mo completion bash|zsh|fish`**: prints the script to stdout, exit 0. Read-only and safe.
- **Unknown argument**: prints usage to stdout, exit 1.
- **`--dry-run` / `-n`**, observed with exit 0:
  ```
  → DRY RUN MODE, shell config files will not be modified
  <blank>
  <blank>
  Will add to /Users/you/.zshrc:
    if output="$(mole completion zsh 2>/dev/null)"; then eval "$output"; fi
  <blank>
  ✓ Dry run complete, no changes made
  ```
  Alternatives: `⊙ [DRY RUN] Would normalize completion entry in <rc>` if already installed.
- **No arguments (auto-install):**
  - The shell is taken from `$SHELL`.
  - The rc file is `~/.zshrc`, or `~/.bash_profile` / `~/.bashrc` for bash. Fish writes `~/.config/fish/completions/{mole,mo}.fish`.
  - It needs `mole` or `mo` on PATH, otherwise `☻ mole not found in PATH…` and exit 1.
  - An unsupported shell prints `☻ Unsupported shell: X` and exits 1.
  - Prompt: `➤ Enable completion for zsh? Enter confirm / Q cancel: `. It is a single-key read where **EOF counts as confirm**. `q`, `n` or ESC prints `Cancelled` (exit 0); another key prints `☻ Invalid key` (exit 1).
  - If completion is already installed, the line is updated silently with no prompt: `✓ Shell completion updated in <rc>`.
  - Success: `✓ Completion added to <rc>`.

---

## 5. `mo update` (`L/mole:307-323`, `L/lib/manage/update.sh:1003-1356`, `L/lib/core/common.sh:127-213`)
I did not run this.

**Flags:** `--force`/`-f` and `--nightly`. Anything else prints `Unknown update option: X` + `Use 'mole update [--force] [--nightly]'…` on stderr, exit 1 (observed).

**How a Homebrew install is detected** (`is_homebrew_install`, lines 656-710): the invoked entry path must be a symlink containing `Cellar/mole`, or a file at `/opt/homebrew/bin/mole` or `/usr/local/bin/mole` with a Cellar directory present and `brew list mole` succeeding. `mo --version` prints `Install: Homebrew|Manual`.

**Homebrew path:**
- `--nightly` prints `☻ Nightly update is only available for script installations…` and exits 1.
- `--force` is ignored.
- It runs `brew update` (timeout `MOLE_HOMEBREW_UPDATE_TIMEOUT` = 120) and `brew upgrade mole` (`MOLE_HOMEBREW_UPGRADE_TIMEOUT` = 120), both with `NONINTERACTIVE=1`.
- Output under pipes: `Updating Homebrew...`, `Upgrading Mole...`, the filtered brew output, `\n✓ Updated to latest version, X\n` or `✓ Already on latest version, X`.
- On failure: `☻ Homebrew upgrade failed` + brew output on stderr, exit 1.
- It may relink a stale launcher (`✓ Repaired stale launcher…`) and clears `~/.cache/mole/update_message`.
- No sudo is needed.

**Script (manual) install path:**
- Under pipes it prints `Checking for updates` (with no `...`), then `Downloading latest version`, then `Installing update`. It downloads `https://raw.githubusercontent.com/tw93/mole/V<ver>/install.sh` (or `/main/install.sh` for nightly) and runs it with `--prefix <dir> --config <dir> [--update]`.
- Sudo is needed only if the install directory is not writable. It uses `request_sudo_access`, then checks `/bin/sh -c 'sudo -n true'`; if that fails it prints `☻ Admin access cannot be handed to the installer in this environment` and exits 1. This will fail without a TTY.
- Messages: `✓ Already on latest version, X`, `✓ Updated to latest version, X`, `✓ Already on latest nightly, abc1234`, and various `☻ …` errors with `⊙ …` hints. Exit 1 on failure.

**Reusable "update available" logic:**
- **Stable version:** `curl https://api.github.com/repos/tw93/mole/releases/latest` → `"tag_name": "V1.56.1"`, strip the leading V. The fallback is `https://raw.githubusercontent.com/tw93/mole/main/mole` → `VERSION="1.56.1"`. Both used 2 s connect / 3 s max timeouts (lines 538-552). Observed now: latest is **1.56.1**.
- **Homebrew:** Mole only reports an update once the tap has it: `brew outdated --formula --verbose mole` → `mole (1.56.0) < 1.56.1` (exit 1 when outdated). It takes the text after `< `.
  - The fallback parses `brew info mole`, but this Homebrew's first line is now `==> mole: 1.56.0 → stable 1.56.1 (bottled), HEAD`, which Mole's parser (lines 609-615) does not handle, so only the `outdated` path works.
- **Comparison:** `sort -V`.
- **Nightly:** compares `COMMIT_HASH=` in `<config>/install_channel` (or `~/.config/mole/install_channel`, which also has `CHANNEL=stable|nightly|dev` and `INSTALL_RECEIPT=`) with `https://api.github.com/repos/tw93/mole/commits/main` `.sha`, using the first 7 characters.
- **Cache:** `~/.cache/mole/update_message`, observed bytes `\nUpdate 1.56.1 available, run mo update\n\n`. It can contain GREEN/NC escapes if it was written from a TTY; the nightly form is `New nightly commit abc1234 available, run mo update --nightly`. It is written in the background only by bare interactive `mo` (`check_for_updates`, line 848), and treated as stale if older than the mole binary's mtime (line 816).
- **Installed version:** `mo --version` line `Mole version 1.56.0` (plus `Channel: Nightly (<hash>)` for nightly). This is stable to parse, exit 0.

---

## 6. `mo remove` (`L/lib/manage/remove.sh`), only `--dry-run` was run
**Flags:** `--dry-run`/`-n`. Anything else prints `Unknown remove option: X` + `Use 'mole remove [--dry-run]'…` on stderr, exit 1 (observed).

**Dry run**, observed with exit 0 (`R/remove_dry.out`):
```
Detecting installations...            (TTY: spinner "Detecting Mole installations...")
<blank>
→ DRY RUN MODE, no files will be removed
<blank>
Remove Mole, would delete the following:
  • Would run: brew uninstall --force mole
  • Would remove: /Users/you/.cache/mole
  • Would move to Trash: /Users/you/.config/mole
  • Would remove: /Users/you/Library/Logs/mole
<blank>
✓ Dry run complete, no changes made
```

**Real run:**
- Prompt: `➤ Press Enter to confirm, ESC to cancel: `. It is a single-key read, and **EOF/empty confirms**; ESC or any other key exits 0.
- It then runs `brew uninstall --force mole`, `rm` of manual binaries (with `sudo rm` if the directory is not writable), `rm -rf ~/.cache/mole` and `~/Library/Logs/mole`, and moves `~/.config/mole` to `~/.Trash/mole-config[-N]`.
- Final line: `✓ Mole uninstalled successfully, thank you for using Mole!` or `☻ Mole uninstalled with some errors…`. Exit 0 either way.
- If no installation is found: `No Mole installation detected`, exit 0.

---

## Files, config and caches in scope
| Path | Purpose |
|---|---|
| `~/.cache/mole/uninstall_app_metadata_v3` (+ `.lock/`) | App size, last-used and name cache (format above). |
| `~/.cache/mole/pkg_receipt_apps_v1` | Header `#receipts:<cksum>`, then one app path per line. |
| `~/.cache/mole/update_message` | Update notice cache. |
| `~/.config/mole/install_channel` | `CHANNEL=`, `COMMIT_HASH=`, `INSTALL_RECEIPT=` (absent on this Homebrew install). |
| `~/Library/Logs/mole/{operations.log,deletions.log,mole.log,mole_debug_session.log}` | Logs. |
| `/etc/pam.d/sudo`, `/etc/pam.d/sudo_local` | Touch ID state. |

Upstream docs for v1.56.0 (`R/README_V1.56.0.md`) document only `MO_NO_OPLOG=1`, `mo history --json`, the automatic JSON of `mo status` / `mo analyze`, and `MO_LAUNCHER_APP`. There is no documented machine-readable interface for uninstall beyond `--list` (which is JSON when piped), and no non-interactive "yes" flag for uninstall. Related upstream items: #536 (the GUI-mode sudo that cannot be reached, as shown above), #1004 (askpass, closed, not in 1.56.0), #708 and #709 (uninstall by name).

---

# status+analyze (Go)

# Research report: `mo status`, `mo analyze` and `lib/check/health_json.sh` (Mole v1.56.0)

## 0. Sources, captures and headline findings

**Where things are**
- Upstream source is cloned at tag `V1.56.0` (commit `239c90d5`, 2026-09-25): `<scratch>/research/mole-src/`
  - All `file:line` references below are relative to `mole-src/` (`cmd/status/*.go`, `cmd/analyze/*.go`).
  - The installed `lib/check/health_json.sh` is byte-identical to upstream.
- Captured outputs are in `<scratch>/research/`:
  - `status.json`: `mo status --json`
  - `status_nontty.json`: `mo status` with stdout piped, which switches to JSON on its own
  - `status_watch.ndjson`: 56 lines of `--watch --interval 1s`. The 4s alarm did not stop the Go process, so I sent SIGTERM (see 1.3).
  - `status_watch_first_fast.json` and `status_watch_second_full.json`: the first two NDJSON lines, pretty-printed
  - `status_alerts.ndjson`: `--proc-cpu-threshold 5 --proc-cpu-window 2s`
  - `analyze_machine.json` and `analyze_machine2.json`: `mo analyze --json` (machine-wide), run twice
  - `analyze_caches.json` and `analyze_caches2.json`: `~/Library/Caches`, run twice
  - `analyze_projects.json`, `analyze_homebrew.json`
  - `health.json`: `bash libexec/lib/check/health_json.sh`
  - `status_help.txt`, `analyze_help.txt`, plus a `*.stderr` file for each run (contains `/usr/bin/time -p` timings)

**How dispatch works**
- `/opt/homebrew/bin/mo` → `Cellar/mole/1.56.0/bin/mo`, a bash script.
- It refuses to run as root: prints `Run Mole without sudo; it requests administrator access when needed.` and exits 1.
- It removes every `--debug` argument and exports `MO_DEBUG=1`. The Go binaries ignore that variable.
- It sources `lib/core/common.sh`, then runs `exec libexec/bin/status.sh` or `exec libexec/bin/analyze.sh` (`analyse` is accepted too).
- Each wrapper runs `exec "$SCRIPT_DIR/status-go" "$@"` (or `analyze-go`). If the binary is missing it prints `Bundled status binary not found. Please reinstall Mole or run mo update to restore it.` (analyze: `Bundled analyzer binary not found. ...`) and exits 1.
- The wrapper costs about 170 ms (`mo analyze --help` took 0.178 s; `analyze-go --help` took 0.006 s).
- The GUI can call `/opt/homebrew/opt/mole/libexec/bin/status-go` and `analyze-go` directly with the same arguments. Both are arm64 Mach-O binaries.

**Headline findings for the GUI**

| | `status-go` | `analyze-go` |
|---|---|---|
| Machine interface | `--json` (one snapshot) and `--watch [--interval D]` (NDJSON stream) | `--json [PATH]` (one report, written only when the scan finishes) |
| stdout not a TTY, no `--json` | Switches to one JSON snapshot on its own | Tries to start the TUI and fails: `analyzer error: could not open a new TTY: open /dev/tty: device not configured`, exit 1 |
| Reads stdin | Never, in JSON or watch mode | Never, in JSON mode |
| Prompts | None | None in JSON mode; delete confirmation exists only in the TUI |
| sudo | Never; nothing escalates | Never |
| Progress on stderr | None | None. stderr is silent unless there is an error. |
| ANSI in output | None; JSON only | None; JSON only |
| Exit codes | 0 ok; 1 for bad flag, validation error, collect error in `--json`, or encode error; 143 when killed by SIGTERM | 0 ok; 1 for bad flag, unresolvable path, or scan error (missing path, not a directory) |

- **Go flag parsing stops at the first positional argument.** `mo analyze ~/X --json` treats `--json` as a path argument and starts the TUI (observed: TTY error, exit 1). Always put flags before the path.

---

## 1. `mo status` (`status-go`)

### 1.1 Flags (`cmd/status/main.go:24-34`, help text at `:353-371`)

| Flag | Type / default | Notes |
|---|---|---|
| `--json` | bool, false | One full collection, then pretty JSON (2-space indent) and exit 0 (`runJSONMode`, `:309-324`) |
| `--watch` | bool, false | NDJSON stream, never exits on its own (`watch.go:59-81`) |
| `--interval` | Go duration string, default `""` meaning 1s | Only used with `--watch`. Must parse with `time.ParseDuration` and be > 0, otherwise `invalid --interval "0s" (must be > 0)` and exit 1 (`:335-348`) |
| `--proc-cpu-alerts` | bool, true | Pass `--proc-cpu-alerts=false` to disable; Go bool flags need `=false` |
| `--proc-cpu-threshold` | float, 100 | Percent in `ps %cpu` units (can exceed 100). Must be >= 0. |
| `--proc-cpu-window` | duration, 5m | Must be > 0 |
| `-h`, `--help` | | Prints usage to stdout, exit 0 |

- Go accepts both `-flag` and `--flag`, and `--flag=value` as well as `--flag value`.
- Unknown flag: stderr gets `flag provided but not defined: -bogus` then `Use 'mo status --help' for usage information`, exit 1 (`parseArgs`, `:377-401`).
- Mode choice (`:403-424`): `--watch` wins. Otherwise `shouldUseJSONOutput(*jsonOutput, os.Stdout)` returns true if `--json` is set or stdout is not a character device (`:36-48`). With a pipe, `mo status` and `mo status --json` behave the same (checked: `status_nontty.json`).
- The TUI (`tea.WithAltScreen`) only runs when stdout is a TTY. Its keys are `q`/`esc`/`ctrl+c` to quit, `k` to toggle the cat, `c` to cycle CPU cores 2→4→8→all. These are irrelevant to the GUI.

### 1.2 Environment
- No `MOLE_*` or `MO_*` variables are read by status-go. The only `os.Getenv` use is proxy detection (`metrics_network.go:164`, `collectProxyFromEnv(os.Getenv)`), which reads the usual `http_proxy`/`HTTPS_PROXY`/`ALL_PROXY` family and reports them as `proxy`. If the GUI's environment differs from the user's shell, proxy results will differ.
- `HOME` (through `os.UserHomeDir`) sets the prefs file location and the Trash path.
- Every subprocess is forced to `LC_ALL=C` (`metrics.go:690-705`), so locale does not affect output.
- `NO_COLOR` does not matter because JSON modes have no colour.

### 1.3 Watch-mode behaviour (`watch.go`, `main.go:250-274`)
- One warm `Collector` is used for the whole stream. Each line is `json.Encoder.Encode(snapshot)`: compact JSON plus `\n`.
- Cadence (`nextCollectionMode`):
  1. Line 1 is a fast collect, emitted immediately.
  2. Line 2 is a full collect, emitted immediately with no sleep.
  3. After that, each tick is one of:
     - full, if at least 30s (`slowRefreshInterval`) since the last full
     - process, if at least 1s since the last process sample
     - fast otherwise

     Then the loop sleeps `interval` after the collection completes.
- Effective period is therefore `interval + collection time`. Observed about 1.07–1.1s at `--interval 1s`, and about 3s for the gap after a full collect (full collect takes about 2.1s).
- With `--interval 1s`, every tick after the second is a process collect (`process_stale: false`). With `--interval 400ms`, ticks alternated between fast (`process_stale: true`, old `process_collected_at`) and process (observed).
- `collected_at` is the time the collection started, not the time it was emitted.
- On a collect error, stderr gets `status: collect failed: <err>`. The snapshot is still emitted if it has a timestamp; otherwise the loop sleeps and retries.
- Termination:
  - If stdout is closed, the next write fails and the process exits (checked with `| head -3`).
  - SIGTERM kills it (exit 143).
  - **SIGALRM is ignored by the Go runtime.** Use `Process.terminate()` (SIGTERM) or `interrupt()` (SIGINT).
- **Fast snapshots borrow slow fields.** Once a full collect has succeeded, fast and process snapshots copy these from the last full: `hardware`, `cpu.p_core_count`, `cpu.e_core_count`, `memory.cached`, `memory.pressure`, `disks` (the whole corrected array), `gpu`, `trash_size`, `trash_approx`, `proxy`, `batteries`, `thermal`, `sensors`, `bluetooth` (`metrics.go:621-664`). The health score is then recomputed.
  - **Line 1 of every stream has no enrichment.** Observed in `status_watch_first_fast.json`:
    - `hardware.*` fields are all `""`
    - `p_core_count` and `e_core_count` are 0
    - `gpu` is `null`, `memory.cached` is 0, `memory.pressure` is `""`
    - `smart_status` is `"unknown"`, and `external` is computed from the `/Volumes/` prefix
    - `batteries` and `bluetooth` are `null`, `proxy` is disabled, `thermal` is all zeros
    - `top_processes` is `null`, and `process_collected_at`, `process_stale`, `zombie_count` and `zombie_parents_complete` are omitted
    - `process_alerts` is `[]`
  - Treat line 1 as a quick first paint only.
- Rate metrics:
  - Network counters are primed in `NewCollector` (`metrics.go:324`), so even one-shot `--json` has network rates. The first `rx_history` has one sample.
  - Disk IO is not primed. **`disk_io` is always `{0,0}` in one-shot `--json`** and on the first watch line. Use watch mode for disk IO.
- **One-shot `--json` never contains process alerts.** It takes a single sample and the window must elapse first; the result is `process_alerts: []`, or `null` when alerts are disabled.

### 1.4 Full JSON schema (`MetricsSnapshot`, `metrics.go:62-95`)
All sizes are **bytes** unless noted. Percentages are **0–100**.

```
collected_at            string  RFC3339Nano with local offset ("2026-09-30T16:25:52.634369+01:00")
host                    string  hostname
platform                string  "darwin 26.6.2"  (gopsutil platform + version)
uptime                  string  formatUptime: "8d 7h" | "3h 12m" | "45m"  (health.go:232-244)
uptime_seconds          uint64
procs                   uint64  process count
hardware                object  (empty strings until the first full collect)
  model                 string  "MacBook Pro"
  cpu_model             string  "Apple M4"
  total_ram             string  "16.0 GB"
  disk_size             string  "460.4 GB"
  os_version            string  "macOS 26.6.2"
  refresh_rate          string  "144Hz" ("%dHz", max display rate) or ""
health_score            int     0-100 (see 1.5)
health_score_msg        string  "Excellent"|"Good"|"Fair"|"Needs Attention" [+ ": " + comma-joined issues]
cpu                     object
  usage                 float   0-100 total CPU (100 ms gopsutil sample, taken before the other collectors start)
  per_core              []float 0-100 per logical CPU
  per_core_estimated    bool
  load1/load5/load15    float
  core_count            int
  logical_cpu           int
  p_core_count          int     Apple Silicon (0 on fast snapshots before enrichment)
  e_core_count          int
gpu                     []object | null
  name                  string
  usage                 float   0-100, or -1 = unavailable. On Apple Silicon this is always -1 without root:
                                powermetrics --samplers gpu_power needs root (metrics_gpu.go:166-195)
  memory_used           float   (NVIDIA path only; MB, via nvidia-smi)
  memory_total          float
  core_count            int
  note                  string  e.g. "sppci_vendor_Apple"
memory                  object
  used,total,available  uint64 bytes
  used_percent          float 0-100
  swap_used,swap_total  uint64 bytes
  cached                uint64 bytes (vm_stat File-backed pages × page size; full collects only)
  pressure              string "normal"|"warn"|"critical"|""
disks                   []object (max 3; internal first, then largest; volumes < 1 GB skipped;
                                 /System/Volumes/*, /private/*, fuse, and non-/dev devices skipped)
  mount                 string  "/" or "/Volumes/Backup"
  device                string  "/dev/disk3s1s1"
  used,total            uint64 bytes (Finder/diskutil-corrected on full collects)
  used_percent          float 0-100
  fstype                string "apfs"
  external              bool   (diskutil on full; "/Volumes/" prefix on fast)
  smart_status          string "verified"|"failing"|"unsupported"|"unknown"
  purgeable             uint64 bytes, OMITTED when 0 (omitempty)
trash_size              uint64 bytes (~/.Trash walk, 2 s cap, 5 s cache)
trash_approx            bool   true = the 2 s timeout was hit
disk_io                 object
  read_rate,write_rate  float  MB/s (bytes/1024/1024/sec)
network                 []object (max 3, sorted by rx+tx desc)
  name                  string "en0"
  rx_rate_mbs,tx_rate_mbs float MB/s (MiB)
  ip                    string
network_history         object
  rx_history,tx_history []float MB/s totals, oldest→newest, ring buffer of up to 120
proxy                   object
  enabled bool, type string "HTTP"|"HTTPS"|"SOCKS"|"PAC"|"WPAD"|"TUN"|"" , host string
                        (TUN = only a utun interface was seen: VPN, iCloud Private Relay or a proxy; not definitive)
batteries               []object | null (null on desktops and in fast-before-full)
  percent               float 0-100
  status                string straight from pmset: "charged","charging","discharging","AC", ... or "Unknown"
  time_left             string pmset text, e.g. "0:00"
  health                string system_profiler condition, e.g. "Good"
  cycle_count           int
  capacity              int    max capacity % of design (e.g. 100)
thermal                 object
  cpu_temp,gpu_temp     float °C (0 = unavailable; observed 0 on M4)
  battery_temp          float °C
  fan_speed             int RPM, fan_count int
  system_power          float W
  adapter_power         float W (adapter rating)
  battery_power         float W (positive = discharging)
sensors                 null   (collection is disabled in source, so it is always null)
bluetooth               []object | null
  name string, connected bool, battery string (e.g. "85%" or "")
top_processes           []object | null  (top 5, ranked by CPU)
  pid,ppid              int
  name,command          string (ps comm)
  cpu                   float ps %cpu (can exceed 100 on multi-core, e.g. 172.4)
  memory                float ps %mem (0-100)
  memory_bytes          uint64 RSS bytes, omitted if 0
process_collected_at    string RFC3339, OMITTED before the first process sample
process_stale           bool,  OMITTED before the first sample; true = reused from an earlier sample
zombie_count            int,   OMITTED before the first sample
zombie_parents          []{pid int, name string, count int} | null (at most 3)
zombie_parents_complete bool,  OMITTED before the first sample
process_watch           {enabled bool, cpu_threshold float, window string (Go duration, "5m0s")}
process_alerts          []ProcessAlert | [] | null (null when alerts are disabled)
```

`ProcessAlert` (`process_watch.go:20-29`):
```
pid int, name string, command string (omitempty), cpu float, threshold float,
window string ("2s"), triggered_at string (RFC3339), status string (always "active")
```
- A process is tracked by the pair (pid, ppid, command).
- It becomes an alert once `cpu >= threshold` has held continuously for `window`, measured across samples.
- The alert disappears as soon as a sample falls below the threshold or the process is gone.
- Sort order: `triggered_at` ascending, then `cpu` descending, then `pid`.
- Real sample (`status_alerts.ndjson`): `{"pid":70899,"name":"caddy","command":"caddy","cpu":182.4,"threshold":5,"window":"2s","triggered_at":"2026-09-30T16:30:41.522544+01:00","status":"active"}`

### 1.5 Health score semantics (`metrics_health.go:57-207`)
Start at 100 and subtract penalties:

| Component | Rule |
|---|---|
| CPU (weight 30) | Above 50%: `15×(u−50)/35`. Above 85%: `30×(u−50)/50`, and the issue "High CPU" is added. |
| Memory (weight 25) | Above 70%: `12.5×(p−70)/18`. Above 88%: `25×(p−70)/30`, issue "High Memory". |
| Memory pressure | warn −5, issue "Memory Pressure". critical −15, issue "Critical Memory". |
| Disk (`disks[0]`, weight 20) | Above 80%: `10×(p−80)/13`. Above 93%: `20×(p−80)/20`, issue "Disk Almost Full". |
| SMART | Any disk `failing` caps the score at 44, issue "Disk SMART Failing". |
| Thermal (`cpu_temp`, weight 15) | Only applied if `cpu_temp` > 0. Above 65°C it scales linearly. Above 85°C the full 15, issue "Overheating". |
| Disk IO (read+write MB/s, weight 10) | Above 50 it scales linearly. Above 150 the full 10, issue "Heavy Disk IO". |
| Battery (`batteries[0]`) | danger (cycles > 900 or capacity < 60%) −5, issue "Battery Service Soon". warn (cycles > 800 or capacity < 80%) −2. |
| Uptime | Over 14 days −3, issue "Restart Recommended". Over 7 days −1. |

- The result is clamped to 0–100 and truncated to an int.
- Bands: ≥85 Excellent, ≥65 Good, ≥45 Fair, below that Needs Attention.
- Message format: `"Good"` or `"Fair: High Memory, Restart Recommended"`.
- Zombies and process alerts do not affect the score.

### 1.6 Subprocesses, permissions and timing
- Subprocesses run: `ps -Aceo pid=,ppid=,state=,pcpu=,pmem=,rss=,comm= -r` (falls back to `ps aux`), `sysctl`, `uptime`, `vm_stat`, `memory_pressure`, `diskutil info -plist <mount>`, `system_profiler -json SPDisplaysDataType`/`SPPowerDataType`/Bluetooth/hardware, `pmset -g batt`, `ioreg`, `scutil`, `powermetrics` (fails without root, and nothing escalates), and **`osascript -e 'tell application "Finder" to return {free space of startup disk, capacity of startup disk}'`** (`metrics_disk.go:401-438`, 5 s timeout, result cached 2 minutes).
- macOS will attribute these to the GUI app as the responsible process. Three consequences:
  - **Automation → Finder prompt.** The GUI needs `NSAppleEventsUsageDescription` in its `Info.plist`. Without the grant, the "Finder" tier fails and disk used falls back to diskutil `APFSContainerFree` or raw statfs, and `purgeable` is omitted. Observed in this shell: `Not authorized to send Apple events to Finder. (-1743)`.
  - **`trash_size` needs Full Disk Access.** `~/.Trash` returned `Operation not permitted` here, so it read 0 even though Trash may not be empty. The walk silently reports 0.
  - **`memory.pressure` was `""` on macOS 26.6.2.** `memory_pressure` no longer prints the words normal/warn/critical, and the parser (`metrics_memory.go:93-114`) matches those words. If the GUI needs the level it can read `sysctl kern.memorystatus_vm_pressure_level` itself (observed value `2`; values are 1 = normal, 2 = warn, 4 = critical).
- Timing: `mo status --json` took 2.9 s wall time (2.5 s on a second run).
- Prefs file (TUI only): `~/.config/mole/status_prefs`, one `key=value` per line, `#` comments allowed, keys `cat_hidden=true|false` and `cpu_cores=2|4|8|0`, written atomically with a `.lock` file (`prefs.go:23-95`). There is no status log or history file.

---

## 2. `mo analyze` (`analyze-go`)

### 2.1 Invocation (`cmd/analyze/main.go`)
- Usage is `mo analyze [--json] [PATH]`. The only flags are `--json` and `-h`/`--help` (`:21-40`). Unknown flag: `flag provided but not defined: -bogus` then `Use 'mo analyze --help' for usage information`, exit 1.
- Target resolution (`resolveScanTarget`, `:89-106`):
  1. The environment variable **`MO_ANALYZE_PATH` overrides the positional argument** (checked: with it set to `.../pip`, a positional `~/Library/Caches` was ignored).
  2. Otherwise the first positional argument is used, passed through `filepath.Abs`. Extra positional arguments are ignored.
  3. With no path, the machine-wide overview runs (`path:"/"`, `overview:true`). Passing `/` explicitly gives a directory scan of `/`, not the overview.
- Other environment: `MOLE_ANALYZE_LIVE_SORT=continuous` only affects the TUI (`live_config.go:10-19`). `HOME` sets the overview roots, the insights, and the cache location.
- **`--json` is the only non-TTY mode.** Without it, Bubble Tea opens `/dev/tty`. A GUI process has no controlling terminal, so this fails: `analyzer error: could not open a new TTY: open /dev/tty: device not configured`, exit 1. There is no automatic JSON fallback.
- In JSON mode nothing reads stdin, nothing prompts, and **nothing is written to stderr during the scan** (all observed `.stderr` files contain only `time` output). There is no progress stream at all; the whole JSON document appears at the end. A GUI can only show an indeterminate spinner.
  - The TUI's live counters (files, dirs, bytes, current path) are not exposed in JSON.
  - A rough ETA is possible because the analyzer cache stores `TotalFiles` per path.
- Errors print to stderr and exit 1, for example `failed to scan directory: open /nonexistent: no such file or directory` and `failed to scan directory: open /Users/.../.zshrc: not a directory`. JSON encode failure: `failed to encode JSON: ...`.
- Every run starts a background goroutine, `pruneAnalyzerCache()`, which evicts old cache files under `~/.cache/mole/analyzer`.
- sudo is never used. Unreadable directories are skipped silently.

### 2.2 JSON schema (`json.go:16-39`)
```
path          string   absolute scan root ("/" for overview)
overview      bool
entries       []Entry  (always present, can be [])
large_files   []File   OMITTED when empty (omitempty); never present in overview mode
total_size    int64    bytes
total_files   int64    OMITTED when 0; never present in overview mode

Entry:
  name        string   basename; symlinks get a " →" suffix (e.g. "symtest_link →")
  path        string   absolute path
  size        int64    bytes (see size semantics below); overview may produce -1 = measurement failed
  is_dir      bool     for a symlink, true if its target is a directory
  insight     bool     OMITTED unless true; overview only (a "hidden space" insight row)
  cleanable   bool     OMITTED unless true; dir with a valid CACHEDIR.TAG, or a name in
                       projectDependencyDirs (node_modules, build, dist, target, DerivedData, Pods,
                       .venv, venv, __pycache__, .gradle, vendor, .next, ...), and NOT under
                       /Library/Caches/, /Library/Logs/, /Library/Saved Application State/, /.Trash/,
                       /Library/DiagnosticReports/ (cleanable.go:18-144)
  last_access string   RFC3339 UTC ("2026-09-17T09:15:46Z"), OMITTED for directories (only
                       files and symlinks carry atime)

File (large_files):
  name string, path string, size int64 bytes
```

**Directory mode** (`performDirectoryScanForJSON`, `json.go:59-78`)
- **Every** immediate child is returned (no 30-entry cap; `entryLimit=0`), sorted by size descending.
- Zero-size entries are included: 25 of 116 in `~/Library/Caches`. The TUI hides them.
- **There is no depth or nesting and no children array.** To drill down, call `mo analyze --json <child path>` again. Warm subtrees come back in 0.2–0.4 s from the cache.
- `large_files` holds the top 20 files by size **from anywhere in the subtree**, deepest paths included. Files with source or text extensions are skipped (`.go .js .ts .json .md .txt .yml .xml .html .css .py .swift .c ...`, `constants.go:251+`). Files inside folded directories such as `node_modules` and `.git` are skipped.
  - Spotlight (`mdfind kMDItemFSSize >= 104857600`, 5 s timeout) replaces the walk-based list if it returns more results.
- `total_files` counts files in the subtree, including counts reused from cache.
- Entries are dropped if the internal channel stays blocked for more than 100 ms (`trySend`). In practice this is rare.
- Skipped names: `defaultSkipDirs` (`nfs`, `PHD`, `Permissions`, `OrbStack`, `Colima`, `VMware Fusion`, `VirtualBox VMs`, `Rancher Desktop`, `.lima`, `.colima`, ...). When scanning `/`, it also skips `dev tmp private cores net home System sbin bin etc var`.
- Folded directories (`.git`, `node_modules`, `.venv`, `.next`, ... `constants.go:77+`) are sized with `du` and not expanded.

**Size semantics**
- Per file, the size is `min(st_blocks*512, st_size)`: actual allocation, capped at logical size, so sparse and cloud-placeholder files count small (`scanner.go:1255-1266`).
- Hardlinks are counted once per scan, the way `du` does (`:1239-1253`).
- Folded directories and overview roots use `du -skPx [-I name] <path>` × 1024 (`scanner.go:1006+`, 30 s timeout).
- Symlinks count only the size of the link itself.

**Overview mode** (`json.go:80-162`, `main.go:179-213`, `insights.go:17-94`)
- Fixed rows: `Home` ($HOME, **excluding ~/Library**), `User Library` (~/Library), `Applications` (/Applications), `System Library` (/Library).
- Insight rows (`insight:true`), included only if the directory exists:

| Row | Path |
|---|---|
| iOS Backups | `~/Library/Application Support/MobileSync/Backup` |
| Old Downloads (90d+) | `~/Downloads`; **size counts only top-level items modified more than 90 days ago** |
| System Logs | `~/Library/Logs` |
| Homebrew Cache | `~/Library/Caches/Homebrew` |
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData` |
| Xcode Simulators | `~/Library/Developer/CoreSimulator/Devices` |
| Xcode Archives | `~/Library/Developer/Xcode/Archives` |
| Spotify Cache | `~/Library/Application Support/Spotify/PersistentCache` |
| JetBrains Cache | `~/Library/Caches/JetBrains` |
| Docker Data | `~/Library/Containers/com.docker.docker/Data` |
| pip Cache | `~/Library/Caches/pip` |
| uv Cache | `~/.cache/uv` |
| Gradle Cache | `~/.gradle/caches` |
| CocoaPods Cache | `~/Library/Caches/CocoaPods` |
| OrbStack Data | `~/Library/Group Containers/*dev.orbstack/data` |

- Up to 8 rows are measured concurrently. Each row first tries the overview cache (`overview_sizes.json`, 7-day TTL), then `du`.
- Rows with `size == 0` are dropped. The rest are sorted by size descending.
- **`total_size` is a plain sum of rows and double-counts.** Insight rows overlap User Library and Home.
- A failed measurement leaves `size:-1`. That row is kept, and −1 is added into `total_size`.
- iCloud `Mobile Documents` is skipped with `du -I`.
- External volumes are not included.
- The TUI's APFS local-snapshot probe (`tmutil listlocalsnapshotdates /`) does not run in JSON mode.

Real overview sample (`analyze_machine.json`):
```json
{"path":"/","overview":true,"entries":[
 {"name":"Home","path":"/Users/you","size":123184507557,"is_dir":true},
 {"name":"User Library","path":"/Users/you/Library","size":41171853312,"is_dir":true},
 {"name":"Applications","path":"/Applications","size":33298685952,"is_dir":true},
 {"name":"Xcode Simulators","path":".../Library/Developer/CoreSimulator/Devices","size":5498748928,"is_dir":true,"insight":true},
 ...],"total_size":209830812325}
```

Directory sample (`analyze_caches.json`): `total_size` 6851472093, `total_files` 51405, 116 entries, 20 large_files. One file entry:
`{"name":"com.apple.nsservicescache.plist","path":".../Caches/com.apple.nsservicescache.plist","size":15725,"is_dir":false,"last_access":"2026-09-30T15:22:02Z"}`.
A cleanable example: `{"name":"build","path":".../mole-gui/build","size":2277376,"is_dir":true,"cleanable":true}`.

### 2.3 Scan timing and caching

| Run | Wall time |
|---|---|
| Machine-wide overview, first run (partly warm: `/Applications` and `/Library` were already cached) | 159 s |
| Machine-wide overview, repeat | 0.16 s (every row from `overview_sizes.json`) |
| `~/Library/Caches` | 0.91 s, then 0.22 s |
| `/opt/homebrew` (2.6 GB, 43k files) | 1.03 s, then 0.38 s |

- **JSON mode always reuses the cache and has no bypass flag.**
  - Subdirectory cache files are trusted for 7 days (`analyzerCacheTTL`), or 24 hours if the directory's mtime changed.
  - Overview sizes are trusted for 7 days.
- To force a fresh result, do what the TUI's `r` key does (`invalidateCacheTree`, `cache.go:727-750`):
  - Delete `~/.cache/mole/analyzer/<hex(xxhash64(path))>.cache` for the path and its direct child directories. The hash is `cespare/xxhash/v2` `Sum64String(absPath)`, formatted as lowercase hex with no zero padding (`cache.go:319-335`).
  - Remove the matching keys from `~/.cache/mole/analyzer/overview_sizes.json`.
  - Or delete the whole `~/.cache/mole/analyzer/` directory, which is heavier.
- Cache formats:
  - `overview_sizes.json` is `{"<abs path>": {"size": int64, "updated": RFC3339, "schema_version": 3}, ...}`, rewritten atomically, capped at 1000 entries.
  - `*.cache` files are Go `gob` encodings of `cacheEntry{Entries, LargeFiles, TotalSize, TotalFiles, ModTime, ScanTime, NeedsRefresh, SchemaVersion}`. Treat them as opaque.
  - The directory is capped at 5000 files / 50 MB. A subtree is only cached if it has at least 100 files or at least 10 MB.
- Other state in `~/.cache/mole/` (for example `purge_stats` and `installed_apps_cache`) belongs to the bash commands. Do not sweep that directory wholesale.
- **Concurrency caveat.** Other processes, such as the TUI or other GUI scans, share the cache. Two concurrent scans of one tree will both write it, which is safe because writes are atomic.

### 2.4 Delete in the analyze TUI (reimplement it in the GUI)
- Delete exists only in the TUI:
  - `delete`/`backspace` opens a confirmation. `enter` confirms. `esc`/`q` cancels.
  - `space` toggles multi-select. `t` toggles the large-files view. `o` opens, `f` reveals in Finder (at most 20 items), `p` previews with `open`.
  - `r` rescans without the cache. `/` filters. `s` changes live sort. `b`/`←` goes back.
  - Delete is blocked while scanning and in overview mode (`update.go:527-960`).
  - Deleting Old Downloads or other overview rows is not possible.
- **It moves items to Trash; it never uses rm** (`delete.go:127-154`). Order of attempts:
  1. `/usr/bin/trash <abs>` (macOS 15+ `trash(8)`, 30 s timeout).
  2. `renameatx_np(RENAME_EXCL)` into `~/.Trash` (same volume as HOME) or `<mount>/.Trashes/<uid>`, adding a `name.<nanos>.<pid>.<n>` suffix on collision.
  3. `osascript -e 'tell application "Finder" to delete POSIX file "<path>"'`.
- Deeper paths are handled first when multiple items are selected.
- Paths the TUI refuses to delete (`validateTrashTarget`, `delete.go:301-550`). A GUI using `NSWorkspace.recycle` / `FileManager.trashItem` should mirror these rules:
  - Empty, relative, NUL-containing, or `..`-containing paths.
  - These exact roots, also matched by identity through `SameFile`:
    ```
    / /Applications /Applications/Finder.app /Applications/Safari.app /Library /Library/Apple
    /Library/Application Support /Library/Extensions /Library/Keychains /System /Users /Volumes
    /Network /cores /dev /etc /home /net /tmp /var /private /private/etc /private/tmp /private/var
    /private/var/{audit,db,root,tmp,folders} /bin /sbin /usr /opt /opt/homebrew
    ```
  - Any direct child of `/Users`, which is an account home.
  - Anything under `/System /bin /sbin /usr /private/etc /private/var/{audit,db,root} /Library/{Apple,Extensions,Keychains} /Applications/{Finder,Safari}.app /dev`.
  - $HOME itself, including its symlink-resolved form.
  - Anything under `~/Library/Containers/com.docker.docker`, `~/.orbstack`, or `~/Library/Group Containers/*dev.orbstack*`.
  - Endpoint-security caches: paths under `/private/var/folders/` or `/var/folders/` that contain `com.crowdstrike.`, `com.sentinelone.`, `com.sentinel-labs.`, `com.eset.`, `com.jamf.`, `com.jamfsoftware.`, `com.paloaltonetworks.`, `com.cisco.anyconnect` or `com.cisco.secureclient`.
  - Symlink targets are checked as well.
- After a delete, the TUI calls `invalidateCache(removedPath)` and `invalidateCache(currentDir)`, then rescans. The GUI should do the same using the file/key removal described in 2.3.
- **Analyze deletes are not written to any log or history file.** `mo history` does not record them.

---

## 3. `lib/check/health_json.sh`
- It is a library, not a subcommand. `bin/optimize.sh:29` sources it and calls `generate_health_json` (`optimize.sh:253`) to print the header line. There is no `mo` flag that exposes it.
- It can be run standalone: `bash /opt/homebrew/opt/mole/libexec/lib/check/health_json.sh` (main guard at `:170-173`). It is read-only, has no sudo and no prompts, and does not read stdin. It took 0.8 s and exited 0.
- It sources `lib/core/file_ops.sh` and `lib/optimize/catalog.sh`.
- Output is pretty JSON built from heredocs (`:111-167`):
```
memory_used_gb     number (2 dp)  (active+wired+compressed pages × vm_stat page size) / 2^30
memory_total_gb    number (2 dp)  hw.memsize / 2^30
disk_used_gb       number (2 dp)  df -k $HOME used / 2^20   (raw statfs; differs from status's Finder-corrected value)
disk_total_gb      number (2 dp)
disk_used_percent  number (1 dp)  0-100
uptime_days        number (1 dp)
optimizations      []{category:"system", name:string, description:string, action:string, safe:bool}
```
- Observed: `{"memory_used_gb":12.52,"memory_total_gb":16.00,"disk_used_gb":344.91,"disk_total_gb":460.43,"disk_used_percent":74.9,"uptime_days":8.3,...}`. The number literals keep trailing zeros such as `16.00`, which is still valid JSON.
- The 20 optimization actions come from `MOLE_OPTIMIZE_*` in `lib/optimize/catalog.sh`, and all are `safe:true`:
  `system_maintenance, cache_refresh, saved_state_cleanup, fix_broken_configs, network_optimization, sqlite_vacuum, prevent_network_dsstore, legacy_overrides_audit, network_stack_optimize, disk_permissions_repair, spotlight_index_optimize, spotlight_orphan_rules_cleanup, periodic_maintenance, shared_file_list_repair, disk_verify, login_items_audit, quarantine_cleanup, launch_agents_cleanup, notification_cleanup, coreduet_cleanup`
  - Names and descriptions are listed in `health.json`.
- In `mo optimize`, the JSON is rendered as `${ICON_ADMIN} System  %s/%s GB RAM | %s/%s GB Disk | Uptime %sd` with values rounded to integers (`optimize.sh:128-152`).
- `json_escape` escapes only `\`, `"` and tab, and replaces newlines with spaces.

---

## 4. Upstream docs and issues
- README "JSON, NDJSON, and process alerts" (`README.md:277-326`) documents exactly the interfaces above:
  - `mo analyze --json`, `mo status --json`, `mo status | jq` (automatic JSON), `mo status --watch --interval 2s`
  - the omitted process fields before the first sample
  - `zombie_parents_complete` semantics (at most 3 parents; false means incomplete or truncated)
  - the `--proc-cpu-*` flags
- No other machine interface is documented: no progress protocol, no `NO_COLOR` handling, and no `MOLE_*` variables for these two commands besides `MO_ANALYZE_PATH` and `MOLE_ANALYZE_LIVE_SORT`, which are only in source.
- Relevant issues:
  - #528 added `mo status --json`.
  - #1288: `top_processes` was always null on macOS 26 (fixed before this version).
  - #1278: `r` refresh reused stale caches (the reason for `invalidateCacheTree`).
  - **#1647 (closed 2026-09-30, after V1.56.0): network rates are wrong when traffic goes through utun interfaces.** Expect the `network` values to be unreliable when a VPN or TUN is active in 1.56.0. This machine reports `proxy.type:"TUN"`.