import Foundation

/// One redraw of Mole's installer selector (drawn to stdout even without a TTY).
struct InstallerMenuFrame: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var isCursor: Bool
        var isSelected: Bool
        /// Possibly truncated with "..." to fit 20–40 columns.
        var name: String
        var size: String
        var source: String

        /// True when this (maybe truncated) row shows `displayName` with `size`.
        func matches(displayName: String, size other: String) -> Bool {
            guard size == other else { return false }
            if name.hasSuffix("...") { return displayName.hasPrefix(String(name.dropLast(3))) }
            return name == displayName
        }
    }

    var rows: [Row] = []
    /// From "[pos/total]" when the list scrolls.
    var position: Int?
    var total: Int?
    var selectedCount = 0
    var selectedSize = ""

    var cursorRow: Row? { rows.first { $0.isCursor } }
    var itemCount: Int { total ?? rows.count }
}

struct InstallerSummary: Equatable, Sendable {
    var heading = ""
    var details: [String] = []
    var count: Int?
    /// Mole's summary "MB" is KiB/1024 (binary); kept verbatim.
    var freedMB: Double?
    var failures: [String] = []
    var isDryRun: Bool { heading.localizedCaseInsensitiveContains("dry run") }
    var isIncomplete: Bool { heading.localizedCaseInsensitiveContains("incomplete") || !failures.isEmpty }
}

/// Pure, incremental parser for `mo installer` output in pipe mode.
struct InstallerParser {
    private(set) var frames: [InstallerMenuFrame] = []
    private(set) var completedFrames = 0
    private(set) var files: [(name: String, size: String)] = []
    private(set) var nothingFound = false
    private(set) var summary: InstallerSummary?
    private(set) var errors: [String] = []
    private var current: InstallerMenuFrame?
    private var inFiles = false
    private var dividers = 0

    static let confirmPrompt = "Enter confirm, ESC cancel:"

    var lastFrame: InstallerMenuFrame? { completedFrames > 0 ? frames.last : nil }

    static func isConfirmPrompt(_ text: String) -> Bool {
        text.contains(confirmPrompt)
    }

    /// `➤ Delete 3 installers, 1.2GB  Enter confirm, ESC cancel: `
    static func parseConfirm(_ text: String) -> (count: Int, size: String)? {
        guard let m = text.firstMatch(of: /Delete (\d+) installers?, (\S+)\s+Enter confirm/) else { return nil }
        return (Int(m.1) ?? 0, String(m.2))
    }

    mutating func feed(_ line: OutputLine) {
        let text = line.text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if line.stream == .stderr {
            if !trimmed.isEmpty && !trimmed.hasPrefix("[DEBUG]") { errors.append(trimmed) }
            return
        }
        if trimmed.count >= 20 && trimmed.allSatisfy({ $0 == "=" }) {
            dividers += 1
            if dividers == 1 { summary = InstallerSummary() }
            return
        }
        if dividers == 1 {
            guard !trimmed.isEmpty else { return }
            if summary?.heading.isEmpty ?? true { summary?.heading = trimmed } else { parseSummary(trimmed) }
            return
        }
        if trimmed.contains("No installer files to clean") { nothingFound = true; return }

        if let m = trimmed.firstMatch(of: /Select Installers to Remove(?:\s*\[(\d+)\/(\d+)\])?\s*,\s*(\S+),\s*(\d+) selected/) {
            var frame = InstallerMenuFrame()
            frame.position = m.1.flatMap { Int($0) }
            frame.total = m.2.flatMap { Int($0) }
            frame.selectedSize = String(m.3)
            frame.selectedCount = Int(m.4) ?? 0
            current = frame
            inFiles = false
            return
        }
        if trimmed.contains("Space Select") && trimmed.contains("Enter Confirm") {
            if let current { frames.append(current); completedFrames += 1 }
            current = nil
            return
        }
        if current != nil {
            if let m = text.firstMatch(of: /^\s*(➤\s*)?([○●]) (.+?)\s+([0-9.]+[KMGT]?B) \| (.*?)\s*$/) {
                current?.rows.append(.init(isCursor: m.1 != nil, isSelected: m.2 == "●", name: String(m.3),
                                           size: String(m.4), source: String(m.5)))
            }
            return
        }
        if trimmed == "Files to be removed:" { inFiles = true; files = []; return }
        if inFiles, trimmed.hasPrefix("✓ ") {
            let body = String(trimmed.dropFirst(2))
            if let range = body.range(of: " , ", options: .backwards) {
                files.append((String(body[..<range.lowerBound]), String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)))
            } else {
                files.append((body, ""))
            }
            return
        }
        if inFiles, trimmed.isEmpty { return }
        if inFiles, Self.isConfirmPrompt(trimmed) { inFiles = false }
    }

    private mutating func parseSummary(_ line: String) {
        summary?.details.append(line)
        if let m = line.firstMatch(of: /^(?:Would remove|Removed) (\d+) installers?, (?:free|freed) ([0-9.]+)MB/) {
            summary?.count = Int(m.1)
            summary?.freedMB = Double(m.2)
        } else if line.hasPrefix("◎ ") {
            summary?.failures.append(String(line.dropFirst(2)))
        }
    }
}

/// Mole's `bytes_to_human` (decimal units), used to match sizes shown in the menu.
enum MoleBytes {
    static func human(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            let scaled = (bytes * 100 + 500_000_000) / 1_000_000_000
            return String(format: "%lld.%02lldGB", scaled / 100, scaled % 100)
        } else if bytes >= 1_000_000 {
            let scaled = (bytes * 10 + 500_000) / 1_000_000
            return String(format: "%lld.%01lldMB", scaled / 10, scaled % 10)
        } else if bytes >= 1000 {
            return "\((bytes + 500) / 1000)KB"
        }
        return "\(bytes)B"
    }
}
