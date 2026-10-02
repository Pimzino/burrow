# Credits

## Mole

Burrow is a graphical front end for **[Mole](https://github.com/tw93/mole)**, the open-source Mac cleaning and optimization CLI (`mo`) by **[tw93](https://github.com/tw93) and contributors**. Mole is licensed under the [GNU General Public License v3.0](https://github.com/tw93/mole/blob/main/LICENSE).

Every clean, uninstall, purge, installer removal, optimization, analysis, update and Mole removal in Burrow is performed by the `mo` command you have installed. Burrow starts it as a subprocess, reads its output and answers its prompts. Mole's safety checks, whitelists, logs and history therefore apply exactly as they do in Terminal.

Mole asks forks and derived products to use a different name and to credit Mole as the source. Burrow is not a fork: it contains no copy of Mole's scripts or binaries. It uses its own name, and this file is its credit to Mole.

### Parts of Burrow that port or read Mole logic

A few features cannot go through `mo` because Mole only offers them inside its interactive terminal UI. For these, Burrow reimplements Mole's own rules in Swift, closely following Mole v1.56.0, so that Burrow behaves exactly as Mole would:

| Burrow source | Mole source | What it does |
|---|---|---|
| `Sources/Burrow/Features/Analyze/AnalyzeTrashGuard.swift` | `cmd/analyze/delete.go` (`validateTrashTarget`) | The analyzer's safety rules for moving items to the Trash: the same critical system roots, protected trees and path checks (empty, relative, null byte, `..`). |
| `Sources/Burrow/Features/Analyze/AnalyzerCache.swift`, `XXHash64.swift` | `cmd/analyze/cache.go` (`invalidateCacheTree`) | The analyzer cache-key scheme: `~/.cache/mole/analyzer/<hex(xxh64(path))>.cache`, and the refresh that clears a folder and its direct children, plus `overview_sizes.json`. XXH64 is implemented in Swift from the public xxHash specification, bit-compatible with `cespare/xxhash/v2`, the Go package Mole uses. |
| `Sources/Burrow/Features/Analyze/AnalyzeKinds.swift` | `cmd/analyze/insights.go` | The "hidden space" categories shown in the analyzer overview. |
| `Sources/Burrow/Features/Protection/MoleConfigFiles.swift` | `lib/core/base.sh`, `lib/manage/whitelist.sh`, `lib/clean/project.sh` | Reading and writing Mole's plain-text config files (`~/.config/mole/whitelist`, `whitelist_optimize`, `purge_paths`) in the formats Mole expects. |
| `Sources/Burrow/Features/Protection/MoleInventory.swift` | Mole's shell libraries (`get_all_cache_items` and default whitelists) | The protection inventory is read **from your installed Mole at runtime** by sourcing its libraries. A small built-in subset is used only if that fails. |
| `Sources/Burrow/Features/Optimize/OptimizeCatalog.swift` | `lib/optimize/catalog.sh` | The optimize task catalog, likewise read from Mole at runtime where possible. |
| `Sources/Burrow/Features/Settings/SettingsUpdatesPane.swift`, `MoleRemoval.swift`, `SettingsTouchIDPane.swift` | `lib/manage/update.sh`, `lib/manage/remove.sh`, `mo touchid` | Predicting when an update needs administrator rights, parsing `mo remove`, and describing what `mo touchid` changes. |

The command-by-command behaviour Burrow relies on is documented in [`docs/mole-cli-research.md`](docs/mole-cli-research.md).

## Apple frameworks

Burrow uses only Apple's SDKs:

- **SwiftUI** (with Liquid Glass on macOS 26) for the whole interface
- **Swift Charts** for charts
- **AppKit** for the menu bar, windows, alerts and Finder integration
- **Foundation**, **Darwin** (`posix_spawn`, pseudo-terminals) and **Observation**
- **ServiceManagement** for "Open at login"
- **QuickLook** for installer previews
- **CoreGraphics** for the build-time icon and DMG background scripts
- **SF Symbols** and **SF Pro**

## Third-party packages

None. Burrow has no Swift packages, CocoaPods or other third-party dependencies. The build and packaging scripts use only tools that ship with macOS and Xcode (`swift`, `codesign`, `hdiutil`, `tiffutil`, `iconutil`, `osascript`).

## Not affiliated

Burrow is an independent project by Jose Freitas ([Pimzino](https://github.com/Pimzino)). It is **not affiliated with, sponsored by or endorsed by** Mole, tw93 or the Mole contributors. It is also unrelated to **Mole for Mac**, the separate paid app available from mole.fit. "Mole" is used here only to describe the CLI that Burrow works with.

## License

Burrow is free software, licensed under the [GNU General Public License v3.0](LICENSE).
