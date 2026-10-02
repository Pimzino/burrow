# Area 0: Core/*, Design/RunViews.swift, App/* (process layer, PTY privileged helper protocol, password prompt handling, status monitor lifecycle, automation)

- **[high] `Core/ProcessRunner.swift:173-176`: exits get lost, so runs hang forever.** `reap()` calls `waitpid(pid, &status, WNOHANG)` from the `DISPATCH_PROC_EXIT` handler. If that returns anything other than `pid`, it returns and never tries again. That event only fires once, so `.exited` is never sent. I tested this with a C program that uses the same pattern (spawn, process source, `waitpid(WNOHANG)`). Over 3000 spawns, `waitpid` returned 0 in 56 and 101 cases (about 2–3%): NOTE_EXIT arrives before the child can be reaped.
  - **What happens:** about one run in 40 stays `.running` for good. `onCompletion` and `waitUntilExit` never fire, and the UI spinner never stops. Any awaiter of `collect`, `json` or `bash` in `Subprocess.run` never returns, because its `for await` never ends. The timeout doesn't help either, since `cancel()` sends `killpg` to a pid that has already exited.
  - **Fix:** the process is known to have exited, so reap it with a blocking call: `var r: pid_t; repeat { r = waitpid(pid, &status, 0) } while r == -1 && errno == EINTR; guard r == pid else { return }`.

- **[high] `Core/MoleService.swift:165-196` with `ProcessRunner.swift:76-77,113-114`: if the app dies, Mole reads EOF, and EOF means "confirm".** For `keepInputOpen` runs, only the GUI holds the write end of the stdin pipe. The child is in its own session (SETSID), so nothing kills it when the GUI dies.
  - **What happens:** the user is on the Uninstall review screen, so Mole is blocked at PROMPT 2 (`batch.sh:1792`, `read -n1 || key=""`). If the app crashes (any Swift trap), is force-quit, is `kill -9`'d, or is killed by the E2E script's "kill the process" step, the pipe closes. `read` returns 1, `key=""`, and the uninstall of the selected apps runs even though the user never confirmed it.
  - I checked this with `/bin/bash` 3.2 using the same `read … || key=""` pattern: EOF gives `CONFIRMED`. Signalling does not help either. In top-level trap context (the `mole` dispatcher's `trap cleanup_temp_files EXIT INT TERM`, which `mo remove`, `completion` and `touchid` run under), SIGINT and then EOF also printed `CONFIRMED`.
  - **Fix:** make sure the child can never see EOF because the parent died. Route every `keepInputOpen` run through the helper (non-admin variant, no `--auth`). The helper owns the child's stdin pipe and relays bytes from the app's pipe. When the app side reaches EOF, or when a kqueue `EVFILT_PROC NOTE_EXIT` on `getppid()` fires, the helper runs `killpg(getpgrp(), SIGKILL)` on Mole before its own write end is closed. A deliberate `closeInput()` should become an explicit helper command rather than a plain EOF.

- **[medium] `Core/MoleService.swift:55-69, 61-63, 299-301`: `cancel()` marks the run finished while Mole is still alive.**
  - **The bug:** `cancel()` sets `state = .cancelled` straight away. After that, `waitUntilExit()` returns -1 immediately, `onCompletion` runs straight away, the Stop button disappears, `runningCount` drops, and `cancelAllRuns()` skips the run.
  - **Why Mole is still alive:** under bash 3.2, a Mole blocked in `read` survives SIGINT and SIGTERM (I tested this: both are deferred while `read` is blocked). Only the SIGKILL at 8 s ends it.
  - **What happens:** the user clicks Stop on a run blocked at a prompt, then quits within 8 s. The `asyncAfter` escalation never runs, and `cancelAllRuns` does not signal this run because it is no longer "running". The app exits, Mole reads EOF, and in top-level trap context that means confirm (see the previous finding). Separately, features that await `waitUntilExit()` after a cancel (for example `UninstallModel.start`) report "cancelled" and allow a new run while the old Mole is still working.
  - **Fix:** add a `cancelRequested` flag and keep `state == .running` until `exited()`, then set `.cancelled`. `cancelAllRuns` should select runs where `process?.isRunning == true`, and on terminate it should send SIGKILL synchronously to runs that are still alive.

- **[medium] `Core/MoleService.swift:122-128, 225-226`, `App/RootView.swift:28`: the password request is not tied to the process or to any window.**
  - **The bug:** the only place the sheet appears is the main `Window`'s RootView. The consume loop `await`s `requestPassword` with no timeout and no cancellation.
  - **Main window closed:** the menu bar keeps the app alive. The user runs Settings → Touch ID enable (`admin: true`). No sheet can appear, so the run hangs as `.running` forever. `sudo` times out after 5 min, the helper exits 77, and that `.exited` stays queued behind the pending await.
  - **Stale request blocks other runs:** while any request is pending (after a cancel, a sudo timeout, or the window closing), every later admin run's `requestPassword` returns `nil` straight away. The app then sends ^C and reports "Administrator access was not granted".
  - **Concurrent runs:** two admin runs at once fail the same way.
  - **Fix:**
    - Race the request against process exit: when `.exited` or a cancel arrives, call `auth.submit(nil)`, or resume that specific request.
    - Queue requests instead of declining them.
    - Present `AuthSheet` from a scene-independent place (its own `Window`/panel opened with `openWindow`, or on whichever window is key), and open it when `request != nil`.

- **[medium] `App/StatusMonitor.swift:59-65, 92-103` with `ProcessRunner.swift:126, 185, 244-245`: every status stream restart leaks a zombie.**
  - **The bug:** `stop()` sets `process = nil` and cancels the task. The `for await` ends and the task's local `process` is released, so the `Subprocess` deinits. The resumed exit source still fires (dispatch retains active sources), but its handler captured `[weak self]`, so nothing calls `waitpid`. The `[weak self]` SIGTERM/SIGKILL escalations are dropped too.
  - **What happens:** each interval or threshold slider change, and each `relocate()`, leaves a `mo`/`status-go` zombie until the app quits.
  - **Fix:** retain `self` strongly in the exit handler and the `drainGroup.notify` closure, and break the cycle after `continuation.finish()`, or reap in a `deinit`-independent way. Also keep the old `Subprocess` alive until `.exited`.

- **[low] `Core/MoleService.swift:94` with `ProcessRunner.swift:122, 191`: the pty master is closed while its dispatch read source may still be registered.**
  - **The bug:** `reader.cancel()` is asynchronous, but `pty.close()` runs on the main actor as soon as `.exited` is handled. libdispatch forbids closing an fd before its cancel handler has run.
  - **What happens:** the fd number can be reused by the next run's pipe, and the stale source can then steal or unregister events on it, so that run's output stalls.
  - **Fix:** close the master in the tty reader's cancel handler (pass `closeOnEOF: true` for the master and drop `pty.close()` of the master from `exited`). Close the slave right after the helper has spawned.

- **[low] `Core/PrivilegedHelper.swift:71, 80, 85`: the helper leaks file descriptors.** `openNull()` opens `/dev/null` three times every 45 s and never closes them. After about an hour the 256-fd limit is reached, `adddup2(-1)` fails, and the keep-alive and the final `sudo -k` run without stdio.
  - **Fix:** open one `/dev/null` fd once and reuse it.

- **[low] `Core/MoleService.swift:173`: the 200-run cap can evict runs that are still running.** `runs.removeFirst(...)` can drop a live run. Once dropped, the user can no longer Stop it from Activity, and `cancelAllRuns` on quit no longer reaches it.
  - **Fix:** evict only finished runs, for example `while runs.count > 200, let i = runs.firstIndex(where: { !$0.state.isRunning }) { runs.remove(at: i) }`.

- **[low] `Core/ProcessRunner.swift:297-303`: line splitting is quadratic.** Every line copies the whole remaining buffer (`buffer = Data(buffer[next...])`). A 64 KB chunk with about 1,600 short lines copies about 50 MB, which matters for large `analyze --json` or `clean` output.
  - **Fix:** scan with a moving start index and compact once per `feed`.

- **[low] `Design/RunViews.swift:199-200`: Return confirms destructive actions.** `ConfirmSheet` gives the destructive confirm button `.keyboardShortcut(.defaultAction)`, so a stray Return confirms an uninstall, purge or clean.
  - **Fix:** when `destructive` is true, put `.defaultAction` on Cancel (or on nothing), not on the destructive button.

I checked these and they are not bugs:
- **Password echo leak into the transcript:** sudo disables ECHO before prompting, and the readers are cancelled before a late answer is written.
- **Uninstall PROMPT 2 with SIGINT then EOF on a normal quit:** the batch trap's `return 130` wins, which I verified.
- **Mole reading `/dev/tty` under the helper:** every such read is gated on `-t 0/1`.
- **Status JSON decoding:** `StatusSnapshot`, `HistoryReport` and `InstalledApp` match real `mo status --json`, `history --json` and `uninstall --list` output.

The race test program is at `<scratch>/race.c`, and the bash EOF/trap scripts (`t.sh`, `t2.sh`) are in the same folder.

---

# Area 1: Features/Uninstall and Features/Installers (prompt-driving protocols, selection verification, key driving, trash/permanent modes, admin decisions)

- **High: the wrong same-name installer can be deleted.** `Sources/Burrow/Features/Installers/InstallersModel.swift:244`, with the scan-side mapping at `:188-196`.
  - **Bug:** the selector walk toggles the first menu row whose name and size match an item the user picked. It never checks that the row is at `item.index` and never compares `row.source`. The safety check at `:276-278` only compares basenames. So two files with the same basename and size, in two scanned folders, can't be told apart.
  - **Second layer:** the scan gives paths to duplicates in scan-root order (Downloads before Desktop). Mole numbers its list by sorted full path (`sort -u`, installer.sh:241), where `/Users/x/Desktop/…` comes first. So the path shown on an item can belong to a different Mole index.
  - **Scenario:** `~/Desktop/X.dmg` and `~/Downloads/X.dmg`, same size. The user picks the one the confirm sheet shows as `~/Downloads/X.dmg`. Row 0 (the Desktop copy) matches first and gets toggled. The basename check passes and Mole deletes `~/Desktop/X.dmg`.
  - **Side effect:** a Homebrew cache copy `<sha>--X.dmg` can never be removed when a plain `X.dmg` of the same size sorts before it. The walk toggles the wrong row and the run aborts with "did not match".
  - **Fix:**
    - In the walk, toggle only when `parser.lastFrame.position` (or the row counter) equals an `item.index` in the selection. Require `row.matches(displayName:size:) && row.source == item.source` as a check on that row; abort otherwise.
    - In `scan`, give same-name candidates their paths in byte-sorted full-path order, which is Mole's order.
    - Before removing, refuse (or warn) when another item has the same `fileName` and size.

- **High: `mo uninstall` can remove a different app with the same name.** `Sources/Burrow/Features/Uninstall/UninstallParser.swift:235-250` and `UninstallModel.swift:185`.
  - **Bug:** the app passes the `.app` basename to Mole. Mole's `match_apps_by_name` (uninstall.sh:1462-1487) takes the first exact hit on either the display name or the basename, in its list order (last-used order). `verify` only checks that the row's text starts with the selected app's display name or basename. It ignores size and path, and it lets a display name match a basename.
  - **Scenario:** `~/Applications/Chrome Apps.localized/Gmail.app` and `~/Applications/Edge Apps.localized/Gmail.app` have different bundle IDs, so both are listed. The user selects the Edge one. Mole matches the Chrome one because it comes first. The row `Gmail  1.2MB` passes `verify`, the review sheet shows Gmail, and the wrong app is uninstalled. The same happens when app B's display name equals app A's basename.
  - **Fix:** before starting, check `store.apps` for any other entry whose `name` or `matchName` equals, case-insensitively, the selected app's `matchName` or `name`. If one exists, refuse with "Mole can't tell these apps apart", because Mole's CLI has no way to match by path. Also make `verify` compare the row's size with the selected entry's `--list` size string (both come from the same `uninstall_normalize_size_display`) as a second check.

- **High: leaving the Uninstall page mid-run leaves a stranded Mole run that confirms on crash.** `Sources/Burrow/Features/Uninstall/UninstallView.swift:14,400-408`, with `RootView.swift:22` (`.id(model.route)`).
  - **Bug:** `UninstallSession` lives only in the view's `@State`. Changing route destroys the view, but the `Task` keeps `session.start` running. When Mole reaches PROMPT 2, `phase = .review` and the code waits forever on a continuation that no view can resume. Mole sits at `read -n1` indefinitely with stdin open. Coming back shows `session == nil`, so the grid is enabled again and a second uninstall can start.
  - **Why it's dangerous:** that prompt treats EOF as "confirm". If the app is later killed (SIGKILL, crash, Xcode Stop, `kill -9`), stdin closes and Mole confirms an uninstall the user never reviewed.
  - **Scenario:** start an uninstall, switch to Clean during the "Finding leftovers" step (which can take minutes), then quit via a crash or debugger stop. The apps are uninstalled.
  - **Fix:** keep the active session in `UninstallStore.shared`, not `@State`, so the review sheet reappears when the user comes back. At minimum, add `.onDisappear { session?.cancel() }`.

- **Medium: if the app dies at any EOF-means-confirm prompt, Mole confirms.** `Sources/Burrow/Core/ProcessRunner.swift:76-77,114` as used by `UninstallModel.swift:196` and `InstallersModel.swift:215`.
  - **Bug:** stdin is a pipe straight from the app, and Mole runs in its own session (setsid), so no SIGHUP reaches it when the app dies. Three prompts treat EOF as Enter: uninstall PROMPT 2 (batch.sh:1792), the installer menu (installer.sh:483, 519) and the installer confirm (installer.sh:729). Admin runs have the same problem: the helper passes its stdin through to Mole, ignores SIGHUP and SIGTERM, and never stops Mole when the app dies.
  - **Scenario:** a force-quit, crash or `kill -9` of the app while the review sheet is up, or mid-walk in the installer selector. Mole reads EOF and deletes.
  - **Fix:** run prompt-driven runs through a small supervisor, for example the existing `--mole-helper` mode without `--auth`. It gives Mole a separate pipe and forwards bytes from the app. On EOF from the app, it sends `killpg(SIGTERM)` to Mole instead of closing Mole's stdin. On a graceful quit, `cancelAllRuns` already sends SIGINT, and Mole's traps handle that safely.

- **Medium: Installers timeout paths wait forever while Mole waits for a key.** `Sources/Burrow/Features/Installers/InstallersModel.swift:230-235` and `:268-274`.
  - **Bug:** when the menu or the confirm prompt isn't seen within 600 s or 60 s but Mole is still running, the code calls `run.waitUntilExit()` without sending `q`/ESC or cancelling. Mole is blocked on `read -n1` with stdin open, so this never returns. `phase` stays `.removing`, `isBusy` blocks Rescan, and the page has no cancel button (`cancelTitle: nil`).
  - **How it can trigger:** `CommandRun.append` (`MoleService.swift:75`) clears `pendingPrompt` on any stdout *or stderr* line. stdout and stderr are read by separate dispatch sources, so a stderr line (such as `[DEBUG]` output with debug logging on) can arrive after the prompt and wipe it. The prompt is then never detected.
  - **Fix:**
    - In both guards, when `run.state.isRunning`, reuse `abort(...)`: send `q` (or ESC at the confirm prompt), wait about 5 s, then `run.cancel()`.
    - In `CommandRun.append`, only clear `pendingPrompt` for a line on the same stream as the pending partial; track the partial's stream in `setPartial`.
  - **Uninstall is only partly affected:** its 900 s and 1800 s timeouts do fall through to `finishEarly`, which cancels, but a wiped prompt still makes it fail after a long wait.

- **Low: `CommandRun.cancel()` makes waits return before the process has exited.** `Sources/Burrow/Core/MoleService.swift:55-58,67`, used by `UninstallModel.swift:231,305-311` and `InstallersModel.swift:223-225`.
  - **Bug:** `cancel()` sets `state = .cancelled` immediately, so `waitUntilExit()` returns -1 right away. The session is marked failed or cancelled and the UI re-enables while Mole is still unwinding (the SIGTERM and SIGKILL follow-ups come 3 s and 8 s later).
  - **Scenario:** cancel during the leftover scan, then start a new uninstall at once. Two `mo uninstall` runs overlap.
  - **Fix:** track "cancel requested" separately from "exited". Have `waitUntilExit` wait for the real `.exited` event, and keep `isRunning` true until then.

Checked and found OK:
- PROMPT 1 is answered with `y\n` or `n\n`, never EOF.
- PROMPT 2 is answered with `\n` or `q` after at least 250 ms, which clears Mole's input drain.
- Cancelling before or during PROMPT 2 sends SIGINT, which Mole's trap turns into `return 130` with nothing removed (batch.sh:2580).
- The installer selector's key handling and output formats match 1.56.0 (checked against a real `mo installer --dry-run` capture).
- Trash and permanent modes map correctly to `MOLE_DELETE_MODE` and `--permanent`.
- The admin password only ever goes to the pty.

---

# Area 2: Features/Clean, Features/Optimize, Features/Purge and Features/Protection (parsers, whitelist/purge_paths/whitelist_optimize file read/write fidelity vs Mole format — a bug here could remove the user default protections, confirm flows, env vars)

- **High: Clean can run on a different target from the one the user previewed and confirmed.** `Features/Clean/CleanModel.swift:88-93, 114-126, 198-203`, `CleanView.swift:88-91, 235`.
  - **Bug:** `clean()` builds its arguments from the current options (`externalEnabled`, `externalVolumePath`, `includeSystem`) and not from the ones the scan used. The options card is only disabled while busy, so every option can still be changed while the screen shows a finished scan. Separately, `onAppear` → `refreshVolumes()` quietly moves `externalVolumePath` to `volumes.first`, or leaves no volume when none is mounted.
  - **Scenario 1:** The user previews external drive A (tiny result). They switch screens, eject A, then come back. `externalVolume` is now nil, so `isExternalMode` is false and the phase is still `.scanned`. The user clicks "Clean…" and the sheet shows drive A's preview numbers. Confirming runs a full `mo clean` on the Mac, which the user never previewed. That also empties the Trash, and runs as admin if "Include system caches" is on.
  - **Scenario 2:** If drive B is mounted when they come back, `mo clean --external /Volumes/B` runs against an unpreviewed drive.
  - **Scenario 3:** Turning the external toggle on after an internal scan cleans a drive using the Mac's preview.
  - **Fix:** Store the argument list and environment in `scanReport` when the scan starts. In `clean()`, refuse to run (or reset the phase to `.idle`) if the current `arguments(dryRun:false)`, environment or `wantsAdmin` differs from the scanned ones. Clear `scanReport` in `didSet` of `includeSystem`, `keepTrash`, `externalEnabled` and `externalVolumePath`, and when `refreshVolumes` changes the selected path.

- **High: "Purge All Eligible" deletes whatever is eligible now, not the list the user confirmed.** `Features/Purge/PurgeModel.swift:166-184, 196-204`, `PurgeView.swift:19-23, 138-141, 325-331`.
  - **Bug:** `mo purge --yes` re-scans and removes every eligible artifact. The confirm sheet lists `store.artifacts` from an earlier dry run, which can be stale. `PurgeStore.shared` keeps phase `.ready` for the whole session, and `onAppear` only scans when idle. Unprotect, the `includeEmpty` toggle (enabled after a scan) and edits to purge paths or the whitelist in Protection do not invalidate the scan.
  - **Scenario 1:** The user clicks "Unprotect" on a protected `node_modules`. It is not shown in the current list, and the view only says "Rescan to see the change". They then confirm "Purge 3 Artifacts". The now-unprotected folder is deleted too, permanently, because purge uses `rm -rf`.
  - **Scenario 2:** The user scans in the morning and confirms in the evening. Projects that passed the 7-day age limit since the scan, or new roots added in Protection, are removed without ever being listed.
  - **Minor:** `[cloud]` rows are counted in the sheet, but the real run skips them.
  - **Fix:** When the user clicks Purge, run a fresh `purge --dry-run` with the same flags and compare it with the confirmed set. Abort and show the new list if anything was added. Also set phase to `.idle` (require a rescan) after `protect`, `unprotect`, an `includeEmpty` change, or edits to `whitelist` or `purge_paths`.

- **Medium: Clean is allowed after a partial, cancelled or incomplete scan, and then cleans categories the user never saw.** `Features/Clean/CleanModel.swift:146-163`, `CleanView.swift:88-91`.
  - **Bug:** A cancelled scan sets phase `.scanned` with partial results. So does a "Dry run incomplete" result, where Mole says "Remaining cleanup was skipped". `canClean` is still true because `alreadyClean` is false.
  - **Scenario:** The scan is stopped after "User essentials". The user sees about 3 GB and confirms "Mole removes what it found in the preview". The real `mo clean` then runs all 16 sections, including Developer tools, App leftovers and the Trash.
  - **Fix:** Disable "Clean…" unless `scanReport.summary?.outcome == .complete`, or show an explicit extra warning that sections after the stop point were not previewed.

- **Medium: A whitelist file that exists but cannot be read is treated as missing, and the next save overwrites it, silently dropping the user's custom protections.** `Features/Protection/MoleConfigFiles.swift:155-159, 197-199`, `ProtectionModel.swift:67-76`, `Features/Purge/PurgeModel.swift:36-44`.
  - **Bug:** `MoleConfigIO.read` returns nil both for a missing file and for a read failure (permission denied, or a file that is not valid UTF-8). `effectivePatterns` then falls back to `inventory.defaults`. Any toggle, or Clean's or Purge's "Protect", writes defaults plus one entry through `rename` into place, and that succeeds because the directory is writable. The optimize and purge files have the same path: they are read as empty, then saved.
  - **Scenario:** `~/.config/mole/whitelist` is root-owned or saved as Latin-1 and contains `~/Library/Caches/MyApp`. The user protects another item. The file is replaced, `MyApp` loses its protection, and the next `mo clean` deletes it.
  - **Fix:** Tell a missing file apart from an unreadable one: check `fileExists` first, then `try` the read and surface the error. Refuse to write when the file exists but could not be read or decoded, and show an error instead.

- **Low: The legacy optimize whitelist `~/.config/mole/whitelist_checks` is ignored.** `Features/Optimize/OptimizeModel.swift:60-87`, `ProtectionModel.swift:67-71`.
  - **Bug:** Mole's `load_whitelist optimize` falls back to `whitelist_checks` when `whitelist_optimize` does not exist (`lib/manage/whitelist.sh:215-218`).
  - **Scenario:** A user with only the legacy file sees every task as included. Toggling one task creates `whitelist_optimize` with just that entry. Mole then stops reading the legacy file, so the earlier exclusions are lost and those tasks run.
  - **Fix:** When `whitelist_optimize` is absent, parse `MolePaths.config + "/whitelist_checks"`, and seed the first write from it.

- **Low: A cancelled or summary-less optimize run is shown as success.** `Features/Optimize/OptimizeModel.swift:125-136`, `OptimizeView.swift:266-268`.
  - **Bug:** `.cancelled`, and exits without a summary but with tasks seen (for example "Optimize task outcomes are incomplete", exit 1), fall through to `.finished(mode)`. The card then shows a green "Mole finished" seal.
  - **Fix:** Handle `.cancelled` explicitly (idle phase plus a banner). Treat `summary == nil` as incomplete or failed and show the stderr text.

- **Low: The clean preview parser splits paths that contain a newline, and Protect then targets the wrong path.** `Features/Clean/CleanParser.swift:262-284`.
  - **Scenario:** This happens on this machine. `~/Library/Logs` has a directory named `mole\n[`, and `clean-list.txt` contains `/Users/…/Logs/mole` followed by `[  # 0B`. The GUI lists the real `~/Library/Logs/mole` as cleanable and offers to protect it, which writes the wrong path. It also lists a bogus `[` entry. Protecting `[` would write a relative glob, which Mole rejects.
  - **Fix:** When a line does not match `lineRegex` and the next line does, join them with `\n`. At minimum, drop entries that do not start with `/`, and never offer Protect for entries without a size.
  - **Also:** Something created that `mole\n[` directory at 17:06 today. That is worth checking separately.

- **Low: "Protect" writes paths without Mole's validation.** `Features/Clean/CleanModel.swift:268-280`, `MoleConfigFiles.swift:180-184`, `PurgeModel.swift:35-48`.
  - **Bug:** `load_mole_whitelist` drops any line containing `..`, `//` or control characters.
  - **Scenario:** Protecting a real path such as `~/Library/Caches/com.foo..bar` is written and shown as "Protected", but Mole ignores it with a warning and deletes the folder.
  - **Fix:** Run `WhitelistPattern.validationError` before writing and show the error. Also escape `[`, `*` and `?` in literal paths, or refuse them.

- **Low: Saving replaces a symlinked config file with a regular file.** `Features/Protection/MoleConfigFiles.swift:204-221`.
  - **Bug:** `rename(tmp, path)` replaces a symlinked `~/.config/mole/whitelist` (dotfiles setups) instead of writing through the link, as Mole's `echo >` does. The comment also says new files get 0600, but the code uses 0644.
  - **Fix:** Resolve the symlink first with `resolvingSymlinksInPath` and write to its target. Use 0600 as documented.

- **Low: The purge automation leaves a permanent change in the user's real whitelist.** `Features/Purge/PurgeView.swift:~383-392`.
  - **Bug:** With `MoleE2EDryRunProtocol`, `store.protect(target)` writes to the real whitelist and never reverts it. If the file did not exist, it also freezes today's defaults into it, so future Mole default changes stop applying.
  - **Fix:** Record the original file contents (or its absence) and restore them after the check.

Checked and found no problem:
- The piped formats of `mo clean`, `optimize` and `purge` match the parsers.
- The whitelist header, `~` form and safety-entry omission match Mole's `save_whitelist_patterns`.
- The inventory loader runs cleanly against 1.56.0: 73 rows, 14 defaults, 6 safety entries.
- `MOLE_SKIP_TRASH_CLEANUP` and `MOLE_ENABLE_DISK_VERIFY` are the correct variable names.
- None of these flows leave stdin open or answer a prompt with EOF.
- Admin runs give Mole `/dev/null` as stdin through the helper.

---

# Area 3: Features/Analyze (trash guard port, xxhash cache invalidation, treemap), Features/Settings (touchid/completion/update/remove flows — EOF/confirm hazards), Features/Dashboard, Features/History, Features/MenuBar

- **Medium** `Features/Settings/SettingsUninstallPane.swift:122`. **Bug:** `mo remove` always runs without admin. If Mole was installed by hand into a folder the user can't write to (such as `/usr/local/bin`), `remove.sh:232-235` runs `sudo rm -f` with no terminal. That fails, but the script keeps going. It still moves `~/.config/mole` to the Trash and runs `rm -rf` on `~/.cache/mole` and `~/Library/Logs/mole`. Then it exits 0 (`remove.sh:295`).
  - **Scenario:** Mole was installed by script into `/usr/local/bin` (owned by root). The dry-run lists "Would remove: /usr/local/bin/mole". The user types REMOVE. The binaries stay, but the whitelists and settings go to the Trash and the logs are deleted. The card shows "Succeeded", and `relocate()` finds `mo` again.
  - **Fix:** Take the "Would remove: <path>" rows from the dry-run. If any parent folder fails `FileManager.default.isWritableFile(atPath:)`, start with `admin: true` and keep `keepInputOpen: true` (the helper passes stdin through). Also scan the transcript for "uninstalled with some errors" and show it as a warning, because the exit code is always 0.

- **Medium** `Features/Settings/SettingsUpdatesPane.swift:141`. **Bug:** `mo update` also always runs without admin. On a manual install in a folder the user can't write to, `update_install_requires_sudo` is true (`update.sh:190-196`). `request_sudo_access` then fails, because the child has no controlling terminal and `-r /dev/tty` passes `access()` but opening it fails. The result is "Update aborted, admin access denied", exit 1.
  - **Scenario:** A manual `/usr/local/bin` install shows "Update Now" but can never update.
  - **Fix:** Resolve the launcher's folder (`resolveLibexec`/`destinationOfSymbolicLink`). If it isn't writable and the install isn't Homebrew, pass `admin: true`.

- **Medium** `Features/Analyze/AnalyzeModel.swift:107-109`. **Bug:** Rescanning the overview only removes the 4 fixed keys from `overview_sizes.json`. The TUI's `r` (`update.go:671-674`) runs `invalidateCache(entry.Path)` for every overview entry, which removes the `.cache` file and the key, including insight rows.
  - In JSON mode, `measureOverviewEntriesForJSON` uses `loadOverviewCachedSize`. That checks the snapshot first, then falls back to `loadCacheFromDisk(path)` (`cache.go:251-262`).
  - Insight rows such as Xcode Simulators, Homebrew Cache and pip do sit in `overview_sizes.json`; I checked the real file.
  - **Scenario:** The user deletes DerivedData or simulators, then clicks Rescan ("measure everything again"). Every insight row comes back with the old size for up to 7 days. The fixed rows can also come back stale: if the user has browsed `$HOME` or `/Applications` in the analyzer, their `<xxh64>.cache` file restores the old total. For `$HOME` that total is the directory-scan figure, which includes `~/Library`.
  - **Fix:** `case .overview: AnalyzerCache.invalidate((overview?.entries.map(\.path) ?? []) + fixedRoots, overviewKeys: true)`

- **Medium** `Features/MenuBar/MenuBarView.swift:198-199`. **Bug:** Quit (the menu-bar ⌘Q) calls `NSApp.terminate(nil)` straight away, even when `service.runningCount > 0`. `willTerminate` then calls `cancelAllRuns()`. That sends only SIGINT, because the SIGTERM/SIGKILL escalation is scheduled with `asyncAfter` and the app is already gone.
  - **Scenario:** An uninstall or admin clean is halfway through deleting. One click in the menu-bar panel interrupts it with no warning.
  - **Fix:** If `service.runningCount > 0`, show a confirmation ("N Mole tasks are running. Stop them and quit?"). Better still, add `applicationShouldTerminate` that returns `.terminateLater` while runs are active.

- **Low** `Features/Settings/SettingsTouchIDPane.swift:14-17`. **Bug:** `TouchIDStatus.read()` ignores commented lines. Mole's `is_touchid_configured` (`touchid.sh:38-50`) and `enable_touchid` (`:117`) use a plain `grep -q pam_tid.so`, so a commented `#auth sufficient pam_tid.so` counts as enabled.
  - **Scenario:** `/etc/pam.d/sudo_local` was copied from Apple's `sudo_local.template` without uncommenting. The app shows "Off". "Turn On…" previews "already enabled, no changes needed". The user still has to enter the admin password, Mole changes nothing, and the pill stays "Off" for good.
  - **Fix:** Show on/off from `mo touchid status` output ("Touch ID is enabled for sudo"). Or detect the commented-only case, explain it, and disable the button.

- **Low** `Features/Analyze/AnalyzeDirectorySection.swift:73` (with `AnalyzeTreemap.swift:117`). **Bug:** Clicking the "+N more" treemap tile calls `actions.select("__rest__")`, so `analyzer.selection` becomes `"__rest__"`. The selection bar (`AnalyzeView.swift:161`) then shows "__rest__" with Reveal, Quick Look, Open and Move to Trash, all acting on a relative path under the current directory. Trash is blocked by the `.relative` rule, so the user just gets a confusing alert.
  - **Fix:** `onSelect: { tile in if let e = tile.entry { actions.select(e.path) } }`

- **Low** `Features/Analyze/AnalyzeModel.swift:148`. **Bug:** The analyze `Subprocess` isn't registered in `service.runs`, so `cancelAllRuns()` at quit never stops it. It runs in its own session, so a first overview scan keeps running `du` for minutes after the app has quit.
  - **Fix:** Add a `willTerminate` observer in `AnalyzeModel` that calls `cancel()`, or send analyze scans through `MoleService`.

- **Low** `Features/Settings/SettingsUninstallPane.swift:15,109-111`. **Bug:** `previewLoaded` becomes true even when the dry-run throws. Exit code and output aren't checked either. So "Uninstall Mole" can be enabled with no preview behind it, which breaks the "always previews first" rule.
  - **Fix:** Add a `previewOK` flag, set only when `result.succeeded && !previewItems.isEmpty`, and require it in `armed`.

- **Low** `Features/Settings/SettingsCompletionPane.swift:14-24`. **Bug:** The parser doesn't recognise the fish dry-run output ("[DRY RUN] Would write Fish completions to:" followed by the two paths). I checked this against real output with `SHELL=.../fish`. Fish users get an empty preview and "Mole will update your shell config", and an existing install isn't detected.
  - **Fix:** Parse that header and the indented paths that follow into a `targets` list, and render it.

- **Low** `Features/Analyze/AnalyzeDirectorySection.swift:79`. **Bug:** The treemap context menu passes `isDir: entry.isDir`, which is true for a symlink to a folder. The list row correctly passes `isDir && !isSymlink`.
  - **Scenario:** Right-clicking a symlink tile offers "Analyze Folder" on the link. The trash sheet also says "The folder and everything inside it go to the Trash", but `trashItem` only moves the link.
  - **Fix:** Pass `isDir: entry.isDir && !entry.isSymlink`.

**Checked and not bugs:**
- **Trash guard:** it matches `validateTrashTarget` / `isProtectedAnalyzeDeletePath` in `delete.go` at V1.56.0, line for line.
- **XXH64:** matches Mole's hashing. I compiled the port and it hit real `~/.cache/mole/analyzer` file names for paths both under and over 32 bytes.
- **Analyzer cache:** `invalidateTree` matches `invalidateCacheTree`.
- **Touch ID stdin:** running with stdin at EOF makes `read -rp "Continue anyway?"` fail under `set -e`, which declines.
- **Completion and remove prompts:** both only send "\n" when their own prompt appears ("Enter confirm" / "Press Enter to confirm"), and `read -n1` treats that as the empty key, which is confirm.
- **`mo update` exit code:** failures do come through as exit 1 because of `set -e`.
- **History:** field names, types and timestamps match real `mo history --json` output, and the IDs had no duplicates.
- **Dashboard force-unwraps:** all are guarded.

**Files (in `/Users/you/Documents/Projects/mole-gui/Sources/Burrow/`):**
- `Features/Settings/SettingsUninstallPane.swift`
- `Features/Settings/SettingsUpdatesPane.swift`
- `Features/Settings/SettingsTouchIDPane.swift`
- `Features/Settings/SettingsCompletionPane.swift`
- `Features/Analyze/AnalyzeModel.swift`
- `Features/Analyze/AnalyzeDirectorySection.swift`
- `Features/Analyze/AnalyzeTreemap.swift`
- `Features/MenuBar/MenuBarView.swift`

**Go source used to check** (fetched at tag V1.56.0): `<scratch>/{delete.go,cache.go,update.go,json.go}`