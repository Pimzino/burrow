# Burrow — architecture and conventions

Burrow is a native SwiftUI (macOS 26, Liquid Glass) front end for the Mole CLI (`mo`, v1.56.0 at the time of writing).
The app never reimplements Mole's cleaning logic: every action goes through `mo`. The exceptions are
reading and writing Mole's own plain-text config files (whitelists, purge paths), and moving
analyzer-selected items to the Trash (Mole's analyzer does this only inside its TUI).

Everything about how each `mo` command behaves without a TTY is in `docs/mole-cli-research.md`.
Read the section for your command before writing a parser.

## Build and run

- `swift build` builds the debug binary at `.build/debug/Burrow`. It runs directly, with no bundle needed.
- `scripts/build-app.sh [debug|release]` produces `build/Burrow.app` (`BURROW_VERSION` overrides its version).
- `scripts/make-dmg.sh [version]` packages it as `build/Burrow-<version>.dmg` (see the script header).
- `scripts/signing-identity.sh` manages the release signing identity, and `scripts/signing-e2e.sh` checks that two builds signed with it share one designated requirement, so macOS keeps privacy permissions across updates (docs/RELEASING.md).
- `scripts/update-e2e.sh` tests in-app updates end to end against a local fake GitHub API (docs/RELEASING.md).
- `scripts/setup-e2e.sh` captures every first-run setup step in dark and light, then walks the flow to the end (report in `e2e-results/setup-<timestamp>/`).
- `scripts/shot.sh <binary> <route> <out.png> [wait] [YES|NO autorun] [reportDir]` launches one screen and captures its window as a PNG.
- Screen recording works here, so check your UI visually. After an automated run, kill the process.
- Routes: `dashboard clean uninstall optimize analyze purge installers history protection`.

## Layers

| Folder | What |
|---|---|
| `Core/ProcessRunner.swift` | `Subprocess` (posix_spawn in a new session; line events `.line/.partial/.exited`; `write`, `closeStdin`, `cancel`, `signal`), `Subprocess.run(...)` for collect-to-completion, `ANSI.strip`. |
| `Core/PrivilegedHelper.swift` | The app re-execs itself in helper mode for (a) admin runs: becomes a PTY session leader, runs `sudo -v`, then Mole, then `sudo -k`; and (b) supervised runs (`keepInputOpen`): the helper owns Mole's stdin and kills Mole if the app's side reaches EOF, because several Mole prompts treat EOF as "confirm". **Do not touch.** |
| `Core/MoleService.swift` | `MoleService` (environment object): `start(title, args, admin:, keepInputOpen:, environment:, onLine:, onPrompt:) -> CommandRun`, `collect(args)`, `json(T.self, args)`, `bash(script)` (runs with Mole's libs sourced). `CommandRun` is observable: `state` (stays `.running` until the process really exits; `.cancelled` if `cancel()` was requested), `cancelRequested`, `lines`, `pendingPrompt` (cleared only by a completed line on the same stream), `send`, `closeInput` (for supervised runs this stops Mole), `cancel`, `waitUntilExit()`, `onCompletion`. `AuthCoordinator` queues password prompts per run and shows them in a floating panel (works without the main window); requests are withdrawn when their run exits. |
| `Core/MoleEnvironment.swift` | Locating `mo` and its `libexec`; the child environment (`NO_COLOR=1`, `TERM=dumb`, full PATH, `EDITOR=/usr/bin/true`); `MolePaths` for all config and log files. |
| `Core/AppUpdate.swift` | Burrow's own updates: `SemanticVersion`, `ReleaseFeed` (GitHub Releases), `UpdateInstaller` (download → Ed25519 + digest verification → mount and validate the new bundle → atomic `RENAME_SWAP` → detached relaunch). Trust model in the file header and `docs/RELEASING.md`. |
| `Core/Models.swift` | Codable models: `StatusSnapshot`, `AnalyzeReport`, `HistoryReport`, `InstalledApp`, `AppMetadata`; `ByteFormat.string/parse`. |
| `Design/*` | `FeatureTheme` (per-area gradient, symbol, title), `FeaturePage` (scrolling page with ambient background), `PageHeader`, `GlassCard`, `StatTile`, `RingGauge`, `CapsuleBar`, `Pill`, `EmptyStateView`, `ScanningView`, `ErrorBanner`, `InfoBanner`, `Footnote`, `RunStatusCard` (status row only: Burrow never shows Mole's raw output), `AuthSheet`, `ConfirmSheet`, `Finder.reveal/open/icon`, `String.abbreviatingHome`. |
| `App/*` | `AppModel` (environment object: `service`, `status`, `automation`, `route`, `availableUpdate`, `hasFullDiskAccess`), `StatusMonitor` (environment object streaming `mo status --watch`: `snapshot`, `samples`, `enriched`, `hardware`, `batteries`), `RootView` (sidebar), `Automation`, `AppUpdater` (`model.updater`: observable update state, daily checks, settings). The Software Update window is `Features/Update/UpdateWindow.swift`. |
| `Features/<Area>/` | One folder per area. Each owns its views, view models and parsers. |
| `Features/Setup/` | First-run setup (`model.setup`, a `SetupModel`): Welcome → Install Mole (only when missing) → Access → Ready, taking over the main window until finished. Rules: nothing but Mole is required; every permission row says why, shows live status and has one action; the step is saved so setup resumes after macOS quits and reopens Burrow for Full Disk Access; live status (which triggers the Finder prompt) starts only after setup. `-BurrowSetup <step>` shows a step without saving or requesting anything. Re-entry: Settings › General › Show Setup Again. Ask for anything else (administrator password, Touch ID) in context, never here. |

Environment objects available in every feature view: `@Environment(AppModel.self)`, `@Environment(MoleService.self)`, `@Environment(StatusMonitor.self)`.

## Rules for feature code

1. **Safety first.**
   - Never start a destructive `mo` command without an explicit in-app confirmation sheet that lists what will happen.
   - Never start one when stdin EOF would mean "confirm". See research: uninstall PROMPT 2, bare `touchid`/`completion`/`remove`. For those, use `keepInputOpen: true` and answer prompts deliberately.
   - Prefer the Trash where Mole offers it.
2. **Admin.** Pass `admin: true` only for work that needs sudo:
   - real `optimize`
   - real `clean` when the user opts into system caches
   - `touchid enable/disable`
   - uninstalling Homebrew casks or root-owned apps

   The password sheet appears automatically. Never ask for passwords yourself.
3. **Automation.**
   - On appear, if `model.automation.autorun && model.automation.route == <your route>`, start your screen's safe action (scan, dry run, list) once.
   - When it finishes, call `model.automation.record("<route>", passed:, detail:, metrics:)`.
   - Never automate a destructive action.
4. **Parsing.**
   - Parse stripped lines (`OutputLine.text`), line by line as they stream, so the UI updates live.
   - Keep parsers as pure `struct`/`enum` types in your folder.
   - Prefer JSON where Mole has it.
5. **Design.** It must look beautiful and native:
   - Collections are lists, not card grids: one `GlassCard(padding: 0)` with a header row, divided rows with aligned columns, ranked (largest first) where size matters, and details that open in place. Cards of different heights in an adaptive grid are not used.
   - One primary action per page, in the `PageHeader`.
   - Two button styles only, both capsules with shared metrics: `.buttonStyle(.soft)` for secondary actions and `.buttonStyle(.hero(theme))` for the primary one. They scale with `controlSize`; `PageHeader` sizes its actions `.large`. Don't use the system `.glass`/`.glassProminent` button styles.
   - No ornament: no coloured glows, no looping or bouncing animation, no confetti, no gradient text. Motion only where it reports progress.
   - Pills are for real per-row states (Homebrew, Protected, Needs attention). Facts go in one secondary text line; standing explanations use `Footnote`, and `InfoBanner` is for things that need attention.
   - Don't repeat a number the page header already shows in a row of `StatTile`s.
   - No terminal: never show Mole's raw output or `mo …` command lines. Report progress and results in plain words.
   - Liquid Glass (`.glassEffect`, `.buttonStyle(.glass/.glassProminent)`, `GlassEffectContainer` where shapes merge), SF Symbols, rounded display type for big numbers, `.contentTransition(.numericText())`, smooth spring animations, `Charts` for charts.
   - Every screen needs polished empty, loading, error and success states.
   - No third-party packages.
6. **Concurrency.** Swift 6 language mode. UI state classes are `@MainActor @Observable`.
7. **Files.** Only add or modify files in your own `Features/<Area>` folders unless told otherwise. Replace the placeholder view with the same type name.
