import Foundation

/// One row of Mole's "◎ Matched N app(s):" list: `1. LinearMouse  12.9MB  |  Last: 1w ago`.
struct UninstallMatchRow: Equatable, Sendable {
    var index: Int
    /// Everything between "N. " and "  |  Last:" (name, two spaces, size).
    var body: String
    var lastUsed: String
}

struct UninstallPreviewFile: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case remove, system, reviewOnly }
    var id: String { kind == .remove ? path : "\(kind)-\(path)" }
    var path: String
    var size: String?
    var kind: Kind
    var sizeBytes: Int64? { size.flatMap(ByteFormat.parse) }
}

struct UninstallPreviewApp: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var isBrew: Bool
    var size: String
    var files: [UninstallPreviewFile] = []
    var notes: [String] = []
    var removable: [UninstallPreviewFile] { files.filter { $0.kind == .remove } }
    var reviewOnly: [UninstallPreviewFile] { files.filter { $0.kind != .remove } }
}

struct UninstallSummary: Equatable, Sendable {
    var heading = ""
    var details: [String] = []
    var removedCount: Int?
    var freed: String?
    var failures: [String] = []
    var hints: [String] = []
    var nothingRemoved = false

    var isIncomplete: Bool { heading.localizedCaseInsensitiveContains("incomplete") || !failures.isEmpty }
    var isDryRun: Bool { heading.localizedCaseInsensitiveContains("dry run") }
}

/// Pure, incremental parser for the transcript of `mo uninstall <names>` in pipe mode.
struct UninstallParser {
    enum Section: Equatable { case preamble, matched, preview, confirmed, summary, done }

    private(set) var section: Section = .preamble
    private(set) var matchedCount: Int?
    private(set) var matched: [UninstallMatchRow] = []
    private(set) var apps: [UninstallPreviewApp] = []
    /// Notes shown above the per-app list (e.g. the Homebrew --zap note).
    private(set) var globalNotes: [String] = []
    /// Warnings Mole printed while scanning (official uninstaller required, unreadable paths…).
    private(set) var warnings: [String] = []
    /// Errors from stderr (`☻ …`).
    private(set) var errors: [String] = []
    /// Lines printed after confirmation and before the summary (brew output, "Could not remove").
    private(set) var executionNotes: [String] = []
    private(set) var summary: UninstallSummary?
    private(set) var noMatch = false
    private(set) var aborted = false
    private var dividerCount = 0

    static let proceedPrompt = "Proceed with uninstallation? [y/N]"
    static let confirmPrompt = "Enter confirm, ESC cancel:"

    static func isProceedPrompt(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasSuffix(proceedPrompt)
    }

    static func isConfirmPrompt(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasSuffix(confirmPrompt)
    }

    /// Parses `➤ Remove 2 apps, 168.1MB [Running]  Enter confirm, ESC cancel: `.
    static func parseConfirmPrompt(_ text: String) -> (count: Int, size: String?, running: Bool)? {
        guard let m = text.firstMatch(of: /Remove (\d+) apps?(?:, ([^\s\[]+))?(.*?)\s+Enter confirm/) else { return nil }
        return (Int(m.1) ?? 0, m.2.map(String.init), m.3.contains("[Running]"))
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}\u{200B}\u{FEFF}").union(.whitespaces))
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
    }

    /// Splits `path , size` on the last " , " when the tail looks like a size.
    static func splitSize(_ text: String) -> (String, String?) {
        if let range = text.range(of: " , ", options: .backwards) {
            let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if ByteFormat.parse(tail) != nil || tail.hasPrefix("N/A") {
                return (String(text[..<range.lowerBound]), tail)
            }
        }
        return (text, nil)
    }

    mutating func feed(_ line: OutputLine) {
        let text = line.text
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if line.stream == .stderr {
            if trimmed.hasPrefix("☻") {
                errors.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("[DEBUG]") {
                if section == .confirmed { executionNotes.append(trimmed) }
            }
            return
        }

        // Summary block delimited by "=====" dividers.
        if trimmed.count >= 20 && trimmed.allSatisfy({ $0 == "=" }) {
            dividerCount += 1
            if dividerCount == 1 {
                section = .summary
                summary = UninstallSummary()
            } else if section == .summary {
                section = .done
            }
            return
        }

        switch section {
        case .summary:
            guard !trimmed.isEmpty else { return }
            if summary?.heading.isEmpty ?? true {
                summary?.heading = trimmed
            } else {
                parseSummaryDetail(trimmed)
            }
            return
        case .done:
            return
        default:
            break
        }

        if trimmed == "No matching applications found." { noMatch = true; return }
        if trimmed.hasPrefix("Warning: No application found matching") { warnings.append(trimmed); return }
        if trimmed == "Aborted." { aborted = true; return }

        if let m = trimmed.firstMatch(of: /^◎ Matched (\d+) app\(s\):$/) {
            matchedCount = Int(m.1)
            section = .matched
            return
        }

        if trimmed.hasPrefix(Self.proceedPrompt) {
            // Warnings can be glued onto the prompt line (no newline after the prompt).
            let rest = trimmed.dropFirst(Self.proceedPrompt.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { warnings.append(rest) }
            section = .preamble
            return
        }

        if trimmed == "Files to be removed:" {
            section = .preview
            return
        }

        if trimmed.contains(Self.confirmPrompt) {
            // The prompt line gets terminated once Mole reads the key.
            section = .confirmed
            return
        }

        switch section {
        case .matched:
            if let m = trimmed.firstMatch(of: /^(\d+)\. (.*)  \|  Last: (.*)$/) {
                matched.append(UninstallMatchRow(index: Int(m.1) ?? 0, body: String(m.2), lastUsed: String(m.3)))
            }
        case .preamble:
            if !trimmed.isEmpty && !trimmed.hasPrefix("→ DRY RUN") { warnings.append(trimmed) }
        case .preview:
            parsePreview(text: text, trimmed: trimmed)
        case .confirmed:
            if !trimmed.isEmpty && !trimmed.hasPrefix("[DRY RUN]") { executionNotes.append(trimmed) }
        default:
            break
        }
    }

    private mutating func parsePreview(text: String, trimmed: String) {
        guard !trimmed.isEmpty else { return }
        let indented = text.hasPrefix("  ")
        if !indented, let m = trimmed.firstMatch(of: /^◎ (.+?)( \[Brew\])? , (.+)$/) {
            apps.append(UninstallPreviewApp(name: String(m.1), isBrew: m.2 != nil, size: String(m.3)))
            return
        }
        if !indented {
            let note = trimmed.hasPrefix("◎ ") ? String(trimmed.dropFirst(2)) : trimmed
            if apps.isEmpty { globalNotes.append(note) } else { warnings.append(note) }
            return
        }
        guard !apps.isEmpty else { return }
        if trimmed.hasPrefix("✓ ") {
            let (path, size) = Self.splitSize(String(trimmed.dropFirst(2)))
            apps[apps.count - 1].files.append(UninstallPreviewFile(path: path, size: size, kind: .remove))
        } else if trimmed.hasPrefix("◎ System: ") {
            let (path, size) = Self.splitSize(String(trimmed.dropFirst("◎ System: ".count)))
            apps[apps.count - 1].files.append(UninstallPreviewFile(path: path, size: size, kind: .system))
        } else if trimmed.hasPrefix("◎ Review only: ") {
            let (path, size) = Self.splitSize(String(trimmed.dropFirst("◎ Review only: ".count)))
            apps[apps.count - 1].files.append(UninstallPreviewFile(path: path, size: size, kind: .reviewOnly))
        } else {
            let note = trimmed.hasPrefix("◎ ") ? String(trimmed.dropFirst(2)) : trimmed
            apps[apps.count - 1].notes.append(note)
        }
    }

    private mutating func parseSummaryDetail(_ line: String) {
        summary?.details.append(line)
        if let m = line.firstMatch(of: /^(?:Removed|Would remove) (\d+) apps?(?:\(s\))?, (?:freed|would free) ([^:]+)(?::.*)?$/) {
            summary?.removedCount = Int(m.1)
            summary?.freed = String(m.2).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("• Failed:") {
            summary?.failures.append(String(line.dropFirst("• Failed:".count)).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("⊙") || line.hasPrefix("↳") {
            summary?.hints.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("No applications were uninstalled") {
            summary?.nothingRemoved = true
        }
    }

    /// What the app expects Mole to print for one selected app in its "Matched" list.
    struct ExpectedMatch: Equatable, Sendable {
        /// Mole's display name for the app (`name` from `--list`).
        var name: String
        /// Mole's size string from `--list` (the same `uninstall_normalize_size_display` as the match row).
        var size: String

        /// Mole had not measured the app yet when the list was read, so the match row may show a real size.
        var sizeIsPending: Bool {
            let s = size.trimmingCharacters(in: .whitespaces)
            return s.isEmpty || s == "--" || s == "..."
        }
    }

    enum VerifyProblem: Equatable, Sendable {
        /// Mole matched a different number of apps.
        case count(String)
        /// A row names a different app.
        case wrongApp(String)
        /// Right name, different size: possibly another copy of the app, or a stale list.
        case sizeChanged(String)

        var message: String {
            switch self {
            case .count(let m), .wrongApp(let m), .sizeChanged(let m): m
            }
        }
    }

    /// Checks that Mole matched exactly the apps the user selected, in the order they were passed
    /// (Mole prints one row per search term, in argument order). Every row must show the selected
    /// app's display name exactly and, when the list had one, its exact size string.
    /// - Returns: nil when everything matches, otherwise the reason.
    static func verify(matched: [UninstallMatchRow], expectedCount: Int?, expected: [ExpectedMatch]) -> VerifyProblem? {
        func apps(_ n: Int) -> String { "\(n) app\(n == 1 ? "" : "s")" }
        if let expectedCount, expectedCount != expected.count || matched.count != expectedCount {
            return .count("Mole matched \(apps(expectedCount)) but you selected \(expected.count).")
        }
        guard matched.count == expected.count else {
            return .count("Mole matched \(apps(matched.count)) but you selected \(expected.count).")
        }
        for (i, (row, want)) in zip(matched, expected).enumerated() {
            let body = normalize(row.body)
            let name = normalize(want.name)
            guard row.index == i + 1, body.hasPrefix(name + "  ") else {
                let shown = body.components(separatedBy: "  ").first ?? body
                return .wrongApp("Mole matched “\(shown)” where it should have matched “\(name)”.")
            }
            let shownSize = normalize(String(body.dropFirst(name.count + 2)))
            if !want.sizeIsPending, shownSize != normalize(want.size) {
                return .sizeChanged("Mole reports \(shownSize) for “\(name)”, but the app list said \(normalize(want.size)). It may be a different copy of the app, or the list is out of date.")
            }
        }
        return nil
    }

    /// The removal plan ("◎ Name , size" headers) must list exactly the selected apps.
    static func verifyPreview(_ apps: [UninstallPreviewApp], expected: [ExpectedMatch]) -> String? {
        let shown = apps.map { normalize($0.name) }.sorted()
        let wanted = expected.map { normalize($0.name) }.sorted()
        guard shown == wanted else {
            let list = shown.isEmpty ? "no apps" : shown.joined(separator: ", ")
            return "Mole's removal plan lists \(list) instead of \(wanted.joined(separator: ", "))."
        }
        return nil
    }

    /// Why Mole's name matching cannot single out `app` among `all`, or nil when it can.
    ///
    /// `mo uninstall <term>` (uninstall.sh `match_apps_by_name`) takes the first app, in its own
    /// last-used order, whose display name or `.app` basename equals the term case-insensitively.
    /// The CLI has no way to match by path, so any other app with that name makes the choice Mole's.
    static func ambiguity(for app: InstalledApp, among all: [InstalledApp]) -> String? {
        let term = app.matchName
        if term.hasPrefix("-") {
            return "“\(term).app” starts with a dash, which Mole would read as an option."
        }
        func same(_ a: String, _ b: String) -> Bool {
            let x = normalize(a), y = normalize(b)
            return x.caseInsensitiveCompare(y) == .orderedSame || x.lowercased() == y.lowercased()
        }
        let clashes = all.filter { other in
            other.path != app.path && (same(other.name, term) || same(other.matchName, term))
        }
        guard let first = clashes.first else { return nil }
        let where_ = MoleHomeDir.abbreviate((first.path as NSString).deletingLastPathComponent)
        let more = clashes.count > 1 ? " and \(clashes.count - 1) more" : ""
        return "Another app is also called “\(term)” (in \(where_)\(more)). Mole matches apps by name only, so it can't tell them apart and might remove the wrong one. Uninstall one of them in Finder, or rename it, then refresh."
    }
}
