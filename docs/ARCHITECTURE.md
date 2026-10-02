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
| `Core/Models.swift` | Codable models: `StatusSnapshot`, `AnalyzeReport`, `HistoryReport`, `InstalledApp`, `AppMetadata`; `ByteFormat.string/parse`. |
| `Design/*` | `FeatureTheme` (per-area gradient, symbol, title), `FeaturePage` (scrolling page with ambient background), `PageHeader`, `GlassCard`, `StatTile`, `RingGauge`, `CapsuleBar`, `Pill`, `EmptyStateView`, `ScanningView`, `ErrorBanner`, `InfoBanner`, `.buttonStyle(.hero(theme))`, `ConsoleView`, `RunStatusCard`, `AuthSheet`, `ConfirmSheet`, `Finder.reveal/open/icon`, `String.abbreviatingHome`. |
| `App/*` | `AppModel` (environment object: `service`, `status`, `automation`, `route`, `availableUpdate`, `hasFullDiskAccess`), `StatusMonitor` (environment object streaming `mo status --watch`: `snapshot`, `samples`, `enriched`, `hardware`, `batteries`), `RootView` (sidebar), `Automation`. |
| `Features/<Area>/` | One folder per area. Each owns its views, view models and parsers. |

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
   - Liquid Glass (`.glassEffect`, `.buttonStyle(.glass/.glassProminent)`, `GlassEffectContainer` where shapes merge), SF Symbols, rounded display type for big numbers, `.contentTransition(.numericText())`, smooth spring animations, `Charts` for charts.
   - Every screen needs polished empty, loading, error and success states.
   - No third-party packages.
6. **Concurrency.** Swift 6 language mode. UI state classes are `@MainActor @Observable`.
7. **Files.** Only add or modify files in your own `Features/<Area>` folders unless told otherwise. Replace the placeholder view with the same type name.
