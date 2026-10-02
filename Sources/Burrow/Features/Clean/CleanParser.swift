import Foundation

/// Live state of `mo clean [--dry-run]`, built line by line from its piped output.
struct CleanReport: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable, Hashable {
        enum Kind: Sendable, Equatable, Hashable {
            /// `→` would clean (dry run).
            case wouldClean
            /// `✓` cleaned (real run) or a skipped-by-whitelist notice.
            case cleaned
            /// `◎` skipped / warning.
            case warning
            /// `⊙` review-only large file.
            case review
            /// `!` alert (Time Machine rows).
            case alert
        }
        let id: Int
        let kind: Kind
        let label: String
        let detail: String?
        let isDry: Bool
        let sizeBytes: Int64?
        let sizeText: String?
        let items: Int?
        /// Path for review-only rows.
        let path: String?
        var sublines: [String] = []

        var isSkip: Bool {
            let d = (detail ?? "") + label
            return d.contains("skip") || d.contains("stopped")
        }
    }

    struct Section: Sendable, Equatable, Identifiable {
        let id: Int
        let title: String
        var rows: [Row] = []
        var nothingToClean = false

        var totalBytes: Int64 { rows.filter { $0.kind == .wouldClean || $0.kind == .cleaned }.compactMap(\.sizeBytes).reduce(0, +) }
        var itemCount: Int { rows.compactMap(\.items).reduce(0, +) }
        var actionableRows: [Row] { rows.filter { $0.kind == .wouldClean || $0.kind == .cleaned } }
        var isLargeFiles: Bool { title == "Large files" }
    }

    struct Summary: Sendable, Equatable {
        enum Outcome: Sendable, Equatable { case complete, cancelled, interrupted, incomplete, other }
        var heading: String
        var outcome: Outcome
        var isDryRun: Bool
        /// "7.51GB" or "At least 1.2GB" or "Partially measured".
        var spaceText: String?
        var spaceBytes: Int64?
        var atLeast = false
        var items: Int?
        var categories: Int?
        var freeSpace: String?
        var freeDelta: String?
        var alreadyClean = false
        var previewFile: String?
        var messages: [String] = []
    }

    var isDryRun = false
    var nonInteractive = false
    var architecture: String?
    var freeSpaceBefore: String?
    /// "19 core patterns active".
    var whitelistStatus: String?
    var whitelistPatterns: [String] = []
    /// Admin / sudo notices and whitelist warnings printed before the sections.
    var notices: [String] = []
    var sections: [Section] = []
    var summary: Summary?

    var currentSection: String? { sections.last?.title }
    var allRows: [Row] { sections.flatMap(\.rows) }
    var reviewRows: [Row] { allRows.filter { $0.kind == .review } }
    var rowsTotalBytes: Int64 { sections.map(\.totalBytes).reduce(0, +) }
}

struct CleanParser {
    private(set) var report = CleanReport()
    private var counter = 0
    private var inSummary = false
    private var summaryLines: [String] = []

    static var rowRegex: Regex<(Substring, Substring, Substring, Substring?, Substring?)> { /^  (→|✓|◎|⊙|!) (.+?)(?: · (.*?))?( dry)?$/ }

    mutating func consume(_ rawLine: String) {
        let line = rawLine
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.count >= 20 && trimmed.allSatisfy({ $0 == "=" }) {
            if inSummary { finishSummary(); inSummary = false } else { inSummary = true; summaryLines = [] }
            return
        }
        if inSummary {
            if !trimmed.isEmpty { summaryLines.append(trimmed) }
            return
        }
        if trimmed.isEmpty { return }

        if trimmed.hasPrefix("Dry Run Mode") { report.isDryRun = true; return }
        if trimmed == "Running in non-interactive mode" { report.nonInteractive = true; return }
        if trimmed == "Clean Your Mac" { return }

        if trimmed.hasPrefix("➤ ") {
            let title = String(trimmed.dropFirst(2))
            counter += 1
            report.sections.append(.init(id: counter, title: title))
            return
        }

        if trimmed.hasPrefix("⚙ "), trimmed.contains("Free space:") {
            let parts = trimmed.dropFirst(2).components(separatedBy: " | ")
            report.architecture = parts.first
            report.freeSpaceBefore = parts.first { $0.hasPrefix("Free space:") }?
                .replacingOccurrences(of: "Free space:", with: "").trimmingCharacters(in: .whitespaces)
            return
        }
        if trimmed.hasPrefix("✓ Whitelist:") {
            report.whitelistStatus = String(trimmed.dropFirst("✓ Whitelist:".count)).trimmingCharacters(in: .whitespaces)
            return
        }
        if trimmed.hasPrefix("↳ ") {
            let text = String(trimmed.dropFirst(2))
            if report.sections.isEmpty {
                report.whitelistPatterns.append(text)
            } else if let s = report.sections.indices.last, let r = report.sections[s].rows.indices.last {
                report.sections[s].rows[r].sublines.append(text)
            }
            return
        }

        if report.sections.isEmpty || !line.hasPrefix("  ") {
            // Preamble: sudo notices, "• …" non-interactive notes, whitelist warnings.
            let note = trimmed.hasPrefix("• ") ? String(trimmed.dropFirst(2)) : trimmed
            report.notices.append(note)
            return
        }

        if trimmed == "✓ Nothing to clean" {
            report.sections[report.sections.count - 1].nothingToClean = true
            return
        }

        if let row = parseRow(line) {
            report.sections[report.sections.count - 1].rows.append(row)
        }
    }

    mutating func finish() {
        if inSummary { finishSummary(); inSummary = false }
    }

    private mutating func parseRow(_ line: String) -> CleanReport.Row? {
        guard let m = line.firstMatch(of: Self.rowRegex) else { return nil }
        counter += 1
        let kind: CleanReport.Row.Kind = switch m.1 {
        case "→": .wouldClean
        case "✓": .cleaned
        case "◎": .warning
        case "⊙": .review
        default: .alert
        }
        var label = String(m.2)
        var detail = m.3.map(String.init)
        // "Chrome Service Worker, would clean 81.4MB, 0 protected" has no " · " separator.
        if detail == nil, let r = label.range(of: ", would ") {
            detail = String(label[label.index(r.lowerBound, offsetBy: 2)...])
            label = String(label[..<r.lowerBound])
        }
        var path: String?
        var sizeSource = detail ?? label
        if kind == .review, let detail {
            let parts = detail.components(separatedBy: " · ")
            path = parts.last { $0.hasPrefix("~") || $0.hasPrefix("/") }
            sizeSource = parts.first ?? detail
        }
        let sizeMatch = sizeSource.firstMatch(of: /(\d+(?:\.\d+)?)(TB|GB|MB|KB|B)\b/)
        let sizeText = sizeMatch.map { String($0.0) }
        let items = sizeSource.firstMatch(of: /(\d+) (?:items|dirs|entries)/).flatMap { Int($0.1) }
        return .init(id: counter, kind: kind, label: label, detail: detail, isDry: m.4 != nil,
                     sizeBytes: sizeText.flatMap(ByteFormat.parse), sizeText: sizeText, items: items, path: path)
    }

    private mutating func finishSummary() {
        guard let heading = summaryLines.first else { return }
        let lower = heading.lowercased()
        let outcome: CleanReport.Summary.Outcome =
            lower.hasSuffix("cancelled") ? .cancelled :
            lower.hasSuffix("interrupted") ? .interrupted :
            lower.hasSuffix("incomplete") ? .incomplete :
            lower.contains("complete") ? .complete : .other
        var s = CleanReport.Summary(heading: heading, outcome: outcome, isDryRun: lower.hasPrefix("dry run"))
        for line in summaryLines.dropFirst() {
            if line.hasPrefix("Potential space:") || line.hasPrefix("Tracked cleanup:") {
                for part in line.components(separatedBy: " | ") {
                    if part.hasPrefix("Potential space:") || part.hasPrefix("Tracked cleanup:") {
                        let value = part.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        s.spaceText = value
                        s.atLeast = value.hasPrefix("At least") || value == "Partially measured"
                        s.spaceBytes = ByteFormat.parse(value)
                    } else if let m = part.firstMatch(of: /(?:Items|Items cleaned): (\d+)/) {
                        s.items = Int(m.1)
                    } else if let m = part.firstMatch(of: /Categories: (\d+)/) {
                        s.categories = Int(m.1)
                    }
                }
            } else if line.hasPrefix("Free space:") {
                let value = String(line.dropFirst("Free space:".count)).trimmingCharacters(in: .whitespaces)
                if let m = value.firstMatch(of: /^(.*?) \((.+)\)$/) {
                    s.freeSpace = String(m.1)
                    s.freeDelta = String(m.2)
                } else {
                    s.freeSpace = value
                }
            } else if line.hasPrefix("Detailed file list:") {
                s.previewFile = String(line.dropFirst("Detailed file list:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.contains("already clean") || line.hasPrefix("No additional") {
                s.alreadyClean = true
                s.messages.append(line)
            } else if line.hasPrefix("Use mo clean --whitelist") {
                continue
            } else {
                s.messages.append(line.hasPrefix("◎ ") ? String(line.dropFirst(2)) : line)
            }
        }
        report.summary = s
    }
}

// MARK: - ~/.config/mole/clean-list.txt

struct CleanPreviewList: Sendable, Equatable {
    struct Entry: Sendable, Equatable, Identifiable, Hashable {
        let path: String
        let sizeText: String?
        let sizeBytes: Int64?
        let items: Int?
        let countedUnder: String?
        var id: String { path }
        /// The path with line breaks made visible (a file name can contain one).
        var displayPath: String { path.replacingOccurrences(of: "\n", with: "↵") }
    }

    struct Section: Sendable, Equatable {
        var title: String
        var entries: [Entry]
    }

    var generated: String?
    var sections: [Section] = []

    func entries(for section: String) -> [Entry] {
        sections.first { $0.title == section }?.entries ?? []
    }

    static var lineRegex: Regex<(Substring, Substring, Substring, Substring?, Substring?)> { /^(.*)  # (size unknown|[\d.]+(?:TB|GB|MB|KB|B))(?:, (\d+) items)?(?:, counted under (.*))?$/ }

    /// Parses Mole's preview file. Every entry Mole writes ends in `  # <size>…`, so a line without that
    /// suffix is the start of a path that contains a line break: it is joined with the following line(s).
    /// When the join is ambiguous (the next line is itself an absolute path), the file system decides.
    /// Entries that don't resolve to an absolute path are dropped rather than guessed.
    static func parse(_ text: String, pathExists: (String) -> Bool = CleanPreviewList.pathExists) -> CleanPreviewList {
        var list = CleanPreviewList()
        var pending: [String] = []
        // Split on "\n" only: Mole writes one entry per `echo`, and a path may contain "\r".
        for sub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(sub)
            if let m = raw.firstMatch(of: /^=== (.+) ===$/) {
                pending = []
                list.sections.append(Section(title: String(m.1), entries: []))
                continue
            }
            if pending.isEmpty {
                if raw.hasPrefix("# Mole Cleanup Preview - ") {
                    list.generated = String(raw.dropFirst("# Mole Cleanup Preview - ".count))
                    continue
                }
                if raw.hasPrefix("#") || raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            }
            guard !list.sections.isEmpty else { continue }
            guard let m = raw.firstMatch(of: lineRegex) else {
                pending.append(raw)
                continue
            }
            var path = String(m.1)
            if !pending.isEmpty {
                let joined = (pending + [path]).joined(separator: "\n")
                if joined.hasPrefix("/") && (!path.hasPrefix("/") || pathExists(joined)) { path = joined }
                pending = []
            }
            guard path.hasPrefix("/") else { continue }
            let size = m.2 == "size unknown" ? nil : String(m.2)
            list.sections[list.sections.count - 1].entries.append(
                Entry(path: path, sizeText: size, sizeBytes: size.flatMap(ByteFormat.parse),
                      items: m.3.flatMap { Int($0) }, countedUnder: m.4.map(String.init)))
        }
        return list
    }

    static func pathExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}
