import Foundation
import Observation

struct InstallerItem: Identifiable, Hashable, Sendable {
    /// Position in Mole's list (full paths sorted byte-wise, `sort -u` under `LC_ALL=C`).
    var index: Int
    /// Basename as Mole prints it in "Files to be removed".
    var fileName: String
    /// Name as shown in Mole's menu (Homebrew hash prefix stripped).
    var displayName: String
    /// Mole's human size (`bytes_to_human`).
    var size: String
    /// The file at this list position. Nil when the app cannot tell which file on disk it is
    /// (for example several files with the same name and size); such items cannot be removed here.
    var path: String?
    /// Exact size in bytes, read from disk.
    var byteSize: Int64?
    var source: String
    var modified: Date?

    var id: String { path ?? "\(index)-\(fileName)" }
    var bytes: Int64 { byteSize ?? ByteFormat.parse(size) ?? 0 }
    var isLocated: Bool { path != nil }
    var kind: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "file" : ext
    }

    var kindSymbol: String {
        switch kind {
        case "dmg": "externaldrive.fill"
        case "pkg", "mpkg": "shippingbox.fill"
        case "iso": "opticaldisc.fill"
        case "xip": "archivebox.fill"
        case "zip": "doc.zipper"
        default: "doc.fill"
        }
    }

    /// True when a row of Mole's menu shows this item: name (maybe truncated), size and source.
    func matches(_ row: InstallerMenuFrame.Row) -> Bool {
        if isLocated {
            return row.matches(displayName: displayName, size: size) && row.source == source
        }
        // Unknown location: Mole strips the Homebrew hash only for files in Homebrew's cache.
        return row.matches(displayName: fileName, size: size)
            || row.matches(displayName: InstallerLocations.stripHomebrewHash(fileName), size: size)
    }
}

struct InstallerCandidate: Equatable, Sendable {
    var path: String
    var size: Int64
    var modified: Date?
}

enum InstallerLocations {
    /// Mole's scan locations (`bin/installer.sh`), searched to depth 2.
    static var roots: [String] {
        let h = MoleHomeDir.path
        return [h + "/Downloads", h + "/Desktop", h + "/Documents", h + "/Public", h + "/Library/Downloads",
                "/Users/Shared", "/Users/Shared/Downloads", h + "/Library/Caches/Homebrew",
                h + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads",
                h + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
                h + "/Library/Application Support/Telegram Desktop", h + "/Downloads/Telegram Desktop"]
    }

    /// Same labels as Mole's `get_source_display`.
    static func source(for path: String) -> String {
        let h = MoleHomeDir.path
        let dir = (path as NSString).deletingLastPathComponent
        let map: [(String, String)] = [(h + "/Downloads", "Downloads"), (h + "/Desktop", "Desktop"), (h + "/Documents", "Documents"),
                                       (h + "/Public", "Public"), (h + "/Library/Downloads", "Library"), ("/Users/Shared", "Shared"),
                                       (h + "/Library/Caches/Homebrew", "Homebrew"),
                                       (h + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads", "iCloud"),
                                       (h + "/Library/Containers/com.apple.mail", "Mail")]
        for (prefix, label) in map where dir.hasPrefix(prefix) { return label }
        if dir.contains("Telegram Desktop") { return "Telegram" }
        return (dir as NSString).lastPathComponent
    }

    static func symbol(forSource source: String) -> String {
        switch source {
        case "Downloads": "arrow.down.circle.fill"
        case "Desktop": "menubar.dock.rectangle"
        case "Documents": "doc.on.doc.fill"
        case "Public": "person.2.fill"
        case "Library": "books.vertical.fill"
        case "Shared": "person.3.fill"
        case "Homebrew": "mug.fill"
        case "iCloud": "icloud.fill"
        case "Mail": "envelope.fill"
        case "Telegram": "paperplane.fill"
        default: "folder.fill"
        }
    }

    /// Finds every regular file (not a symlink) named like one of Mole's basenames, at depth ≤ 2
    /// below each root, without following symlinked folders (like Mole's `find`).
    static func locate(_ names: Set<String>) async -> [String: [InstallerCandidate]] {
        let roots = self.roots
        return await Task.detached(priority: .userInitiated) {
            var found: [String: [InstallerCandidate]] = [:]
            var seen = Set<String>()
            let fm = FileManager.default
            func type(_ path: String) -> FileAttributeType? {
                (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            }
            func consider(_ path: String) {
                let name = (path as NSString).lastPathComponent
                guard names.contains(name), !seen.contains(path),
                      let attrs = try? fm.attributesOfItem(atPath: path),
                      (attrs[.type] as? FileAttributeType) == .typeRegular else { return }
                seen.insert(path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                found[name, default: []].append(InstallerCandidate(path: path, size: size, modified: attrs[.modificationDate] as? Date))
            }
            for root in roots {
                guard let level1 = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for entry in level1 {
                    let p1 = root + "/" + entry
                    consider(p1)
                    if type(p1) == .typeDirectory, let level2 = try? fm.contentsOfDirectory(atPath: p1) {
                        for child in level2 { consider(p1 + "/" + child) }
                    }
                }
            }
            return found
        }.value
    }

    /// Mole's list order: `sort -u` of full paths under `LC_ALL=C`, which compares bytes.
    static func moleOrder(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// Maps each position of Mole's list (`files`, in list order) to a file on disk.
    ///
    /// When the files found on disk, in Mole's order, line up one-to-one with Mole's list (same
    /// basename and size at every position), every position is certain. Otherwise only files whose
    /// name and size occur exactly once, both in Mole's list and on disk, are mapped.
    static func map(_ files: [(name: String, size: String)], candidates: [String: [InstallerCandidate]]) -> (exact: Bool, paths: [InstallerCandidate?]) {
        let names = Set(files.map(\.name))
        let all = candidates.filter { names.contains($0.key) }.values.flatMap { $0 }
            .sorted { moleOrder($0.path, $1.path) }
        if all.count == files.count,
           zip(all, files).allSatisfy({ ($0.path as NSString).lastPathComponent == $1.name && MoleBytes.human($0.size) == $1.size }) {
            return (true, all)
        }
        let paths: [InstallerCandidate?] = files.map { file in
            let inList = files.filter { $0.name == file.name && $0.size == file.size }.count
            let onDisk = (candidates[file.name] ?? []).filter { MoleBytes.human($0.size) == file.size }
            return inList == 1 && onDisk.count == 1 ? onDisk[0] : nil
        }
        return (false, paths)
    }

    /// Builds the items for Mole's list.
    static func items(_ files: [(name: String, size: String)], candidates: [String: [InstallerCandidate]]) -> [InstallerItem] {
        let mapping = map(files, candidates: candidates).paths
        return files.enumerated().map { i, file in
            let match = mapping[i]
            let source = match.map { self.source(for: $0.path) } ?? "Unknown"
            let display = source == "Homebrew" || match == nil ? stripHomebrewHash(file.name) : file.name
            return InstallerItem(index: i, fileName: file.name, displayName: display, size: file.size,
                                 path: match?.path, byteSize: match?.size, source: source, modified: match?.modified)
        }
    }

    static func stripHomebrewHash(_ name: String) -> String {
        if let m = name.firstMatch(of: /^[0-9a-f]{64}--(.*)$/) { return String(m.1) }
        return name
    }
}

/// Scans and removes installers through `mo installer`, driving its key-based selector over stdin.
///
/// Mole's selector and its confirm prompt both treat Enter (and EOF) as "confirm", and Mole removes
/// files by list position. So a removal:
/// - checks that Mole's list still has the scanned length and that the files on disk still map to
///   the same positions;
/// - walks the menu row by row, verifying at every step that the cursor is at the expected position
///   and that the row shows that item's name, size and source, and toggles only selected positions;
/// - checks the selected count and total, then Mole's "Files to be removed" list and prompt, before
///   the final Enter. Any mismatch, timeout or cancel is answered with "q", then a signal.
@MainActor
@Observable
final class InstallersStore {
    static let shared = InstallersStore()

    enum Phase: Equatable {
        case idle, scanning, ready, removing, done, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var items: [InstallerItem] = []
    private(set) var scanRun: CommandRun?
    private(set) var removeRun: CommandRun?
    private(set) var scanStatus = ""
    private(set) var removalStatus = ""
    private(set) var lastSummary: InstallerSummary?
    private(set) var lastRemovalWasDryRun = false
    private(set) var lastRemovalMovedToTrash = true
    private(set) var lastRemovalError: String?
    private(set) var scannedAt: Date?
    /// True once the final confirmation was sent: from then on Mole is deleting and cannot be stopped.
    private(set) var removalCommitted = false
    /// True while a cancel of the removal is being processed.
    private(set) var isCancelling = false
    /// Mole's menu rows the last removal toggled ("position: name | size | source"), for diagnostics.
    private(set) var lastToggledRows: [String] = []

    @ObservationIgnored private var cancelRequested = false

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var isBusy: Bool { phase == .scanning || phase == .removing }
    var canCancelRemoval: Bool { phase == .removing && !removalCommitted && !isCancelling }

    // MARK: Scan (always a dry run)

    func scan(service: MoleService) async {
        guard !isBusy else { return }
        phase = .scanning
        scanStatus = "Looking in Downloads, Desktop, Homebrew, Mail and more…"
        var parser = InstallerParser()
        let run = service.start("Scan installers", ["installer", "--dry-run"], keepInputOpen: true,
                                onLine: { line in parser.feed(line) })
        scanRun = run

        // Wait for the first complete menu frame (or "nothing found").
        let gotMenu = await MoleRunDriver.wait(for: run, timeout: 600) { parser.completedFrames >= 1 }
        if !gotMenu || !run.state.isRunning {
            await MoleRunDriver.stop(run, answering: "q")
            if parser.nothingFound || (run.succeeded && parser.frames.isEmpty) {
                items = []
                scannedAt = Date()
                phase = .ready
            } else {
                phase = .failed(parser.errors.last ?? "Mole could not scan for installers.")
            }
            return
        }
        let total = parser.lastFrame?.itemCount ?? 0
        scanStatus = "Found \(total) installer\(total == 1 ? "" : "s"), reading details…"

        // Dry run: select all, confirm the menu, then confirm the dry-run prompt to learn every full
        // file name. Nothing is deleted in --dry-run mode.
        let framesBefore = parser.completedFrames
        run.send("a")
        _ = await MoleRunDriver.wait(for: run, timeout: 30) { parser.completedFrames > framesBefore }
        run.send("\r")
        let gotPrompt = await MoleRunDriver.wait(for: run, timeout: 60) { InstallerParser.isConfirmPrompt(run.pendingPrompt) }
        if gotPrompt && run.state.isRunning {
            await MoleRunDriver.pause(.milliseconds(150))
            run.send("\r")
        }
        _ = await MoleRunDriver.wait(for: run, timeout: 120) { false }
        await MoleRunDriver.stop(run, answering: "q")

        guard !parser.files.isEmpty else {
            phase = .failed("Mole listed installers but did not report their names.")
            return
        }
        guard parser.files.count == total else {
            phase = .failed("Mole listed \(total) installers but reported \(parser.files.count) names. Try scanning again.")
            return
        }
        let candidates = await InstallerLocations.locate(Set(parser.files.map(\.name)))
        items = InstallerLocations.items(parser.files, candidates: candidates)
        scannedAt = Date()
        phase = .ready
    }

    // MARK: Removal

    /// Removes `selection` with the real selector protocol. With `dryRun` the same keys are sent to `--dry-run`.
    func remove(_ selection: [InstallerItem], trash: Bool, dryRun: Bool, service: MoleService) async {
        guard !isBusy, !selection.isEmpty else { return }
        lastSummary = nil
        lastRemovalError = nil
        lastRemovalWasDryRun = dryRun
        lastRemovalMovedToTrash = trash
        removalCommitted = false
        lastToggledRows = []
        cancelRequested = false
        isCancelling = false

        // Refuse what the app cannot pin to one file before Mole even starts.
        let chosen = selection.compactMap { item in items.first { $0.id == item.id } }.sorted { $0.index < $1.index }
        if let problem = preflight(chosen, requested: selection.count) {
            lastRemovalError = problem + " Nothing was removed."
            phase = .failed(lastRemovalError!)
            return
        }
        phase = .removing
        removalStatus = "Checking that the files have not changed…"
        let now = await InstallerLocations.locate(Set(items.map(\.fileName)))
        let fileList = items.map { (name: $0.fileName, size: $0.size) }
        let remapped = InstallerLocations.map(fileList, candidates: now).paths
        guard remapped.map({ $0?.path }) == items.map(\.path),
              chosen.allSatisfy({ remapped[$0.index]?.size == $0.byteSize }) else {
            lastRemovalError = "Installers were added, moved or changed since the scan. Rescan and try again. Nothing was removed."
            phase = .failed(lastRemovalError!)
            return
        }

        var parser = InstallerParser()
        var args = ["installer"]
        if dryRun { args.append("--dry-run") }
        removalStatus = "Waiting for Mole's list…"
        let run = service.start(dryRun ? "Preview installer removal" : "Remove installers", args, keepInputOpen: true,
                                environment: ["MOLE_DELETE_MODE": trash ? "trash" : "permanent"],
                                onLine: { line in parser.feed(line) })
        removeRun = run

        /// Stops Mole without confirming anything: "q" cancels both the menu and the confirm prompt.
        func abort(_ message: String) async {
            await MoleRunDriver.stop(run, answering: "q")
            isCancelling = false
            if cancelRequested {
                lastRemovalError = nil
                phase = .ready
                return
            }
            lastRemovalError = message + " Nothing was removed."
            phase = .failed(lastRemovalError!)
        }
        /// Waits for a new menu frame after a key.
        func nextFrame(after before: Int) async -> Bool {
            await MoleRunDriver.wait(for: run, timeout: 15) { cancelRequested || parser.completedFrames > before }
                && !cancelRequested && run.state.isRunning
        }

        let gotMenu = await MoleRunDriver.wait(for: run, timeout: 600) { cancelRequested || parser.completedFrames >= 1 }
        guard gotMenu, !cancelRequested, run.state.isRunning else {
            if !run.state.isRunning && parser.nothingFound {
                lastRemovalError = "The installers are already gone."
                phase = .failed(lastRemovalError!)
                return
            }
            return await abort("Mole did not show its installer list.")
        }
        guard parser.lastFrame?.itemCount == items.count else {
            return await abort("Mole now lists \(parser.lastFrame?.itemCount ?? 0) installers instead of \(items.count). Rescan and try again.")
        }

        // Walk the list row by row up to the last selected position, verifying every row.
        removalStatus = "Selecting your files in Mole's list…"
        let wanted = Set(chosen.map(\.index))
        let last = chosen.map(\.index).max() ?? 0
        for i in 0...last {
            guard let frame = parser.lastFrame, let row = frame.cursorRow, Self.cursorIndex(frame) == i else {
                return await abort("Mole's menu was not where expected.")
            }
            guard items[i].matches(row) else {
                return await abort("Mole's list changed: position \(i + 1) shows \(row.name) instead of \(items[i].displayName). Rescan and try again.")
            }
            if wanted.contains(i) {
                lastToggledRows.append("\(i + 1): \(row.name) | \(row.size) | \(row.source)")
                let before = parser.completedFrames
                let count = frame.selectedCount
                run.send(" ")
                guard await nextFrame(after: before), let now = parser.lastFrame, Self.cursorIndex(now) == i,
                      now.cursorRow?.isSelected == true, now.selectedCount == count + 1 else {
                    return await abort("Mole did not confirm the selection of \(items[i].displayName).")
                }
            }
            if i < last {
                let before = parser.completedFrames
                run.send("\u{1B}[B")
                guard await nextFrame(after: before) else {
                    return await abort("Mole's menu stopped responding.")
                }
            }
        }
        let expectedBytes = chosen.compactMap(\.byteSize).reduce(0, +)
        guard let frame = parser.lastFrame, frame.selectedCount == chosen.count,
              frame.selectedSize == MoleBytes.human(expectedBytes) else {
            return await abort("Mole's selection did not match yours.")
        }
        guard !cancelRequested else { return await abort("") }

        // Confirm the menu, then check the exact files Mole is about to delete.
        run.send("\r")
        removalStatus = "Checking Mole's list of files to remove…"
        guard await MoleRunDriver.wait(for: run, timeout: 60, until: { cancelRequested || InstallerParser.isConfirmPrompt(run.pendingPrompt) }),
              !cancelRequested, run.state.isRunning else {
            return await abort("Mole did not ask for confirmation.")
        }
        let listed = parser.files.map { "\($0.name)|\($0.size)" }
        let expected = chosen.map { "\($0.fileName)|\($0.size)" }
        guard listed == expected, let prompt = InstallerParser.parseConfirm(run.pendingPrompt),
              prompt.count == chosen.count, prompt.size == frame.selectedSize else {
            return await abort("Mole's list of files did not match your selection, so it was cancelled.")
        }
        await MoleRunDriver.pause(.milliseconds(150))
        guard !cancelRequested, run.state.isRunning else { return await abort("Mole exited before confirmation.") }
        removalCommitted = true
        removalStatus = dryRun ? "Rehearsing removal…" : trash ? "Moving files to the Trash…" : "Deleting files…"
        run.send("\r")
        _ = await run.waitUntilExit()
        lastSummary = parser.summary
        if parser.summary == nil && !run.succeeded {
            lastRemovalError = parser.errors.last ?? "Mole reported a problem (exit code \(run.exitCode ?? -1))."
            phase = .failed(lastRemovalError!)
        } else {
            phase = .done
        }
    }

    /// Stops a removal before Mole's final confirmation. Nothing is deleted.
    func cancelRemoval() {
        guard canCancelRemoval else { return }
        cancelRequested = true
        isCancelling = true
        removalStatus = "Cancelling…"
    }

    /// Absolute list position of the cursor: "[pos/total]" when the list scrolls, else the row index.
    static func cursorIndex(_ frame: InstallerMenuFrame) -> Int? {
        if let position = frame.position { return position - 1 }
        return frame.rows.firstIndex { $0.isCursor }
    }

    /// Why `chosen` cannot be removed safely, or nil.
    private func preflight(_ chosen: [InstallerItem], requested: Int) -> String? {
        guard chosen.count == requested else { return "The list changed since you selected. Rescan and try again." }
        if let unknown = chosen.first(where: { !$0.isLocated }) {
            return "The app can't tell which file on disk “\(unknown.displayName)” is, so it won't ask Mole to remove it."
        }
        for item in chosen {
            // The same name, size and source can only be told apart by list position; that is only
            // safe when the whole list mapped one-to-one (then every item has a path).
            let twins = items.filter { $0.index != item.index && $0.fileName == item.fileName && $0.size == item.size }
            if twins.contains(where: { !$0.isLocated }) {
                return "Several files are named “\(item.displayName)” with the same size, and the app can't tell them apart."
            }
        }
        return nil
    }

    /// Other scanned files with the same name and size as `item` (shown as a caution when confirming).
    func twins(of item: InstallerItem) -> [InstallerItem] {
        items.filter { $0.index != item.index && $0.fileName == item.fileName && $0.size == item.size }
    }

    /// Shows the last removal summary again after the follow-up rescan.
    func markDone() {
        if phase == .ready, lastSummary != nil { phase = .done }
    }

    func acknowledge() {
        if case .failed = phase { phase = items.isEmpty && scannedAt == nil ? .idle : .ready }
        if phase == .done { phase = .ready }
    }
}
