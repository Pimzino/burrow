import Foundation
import Observation
import SwiftUI

// MARK: - Pure parsing

/// Mole's two timestamp formats: sessions use local "YYYY-MM-DD HH:MM:SS"; deletions use "%Y-%m-%dT%H:%M:%S%z".
enum HistoryTimestamp {
    static func parseLocal(_ text: String, calendar: Calendar = .current) -> Date? {
        guard let m = text.firstMatch(of: /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$/) else { return nil }
        var c = DateComponents()
        c.year = Int(m.1); c.month = Int(m.2); c.day = Int(m.3)
        c.hour = Int(m.4); c.minute = Int(m.5); c.second = Int(m.6)
        return calendar.date(from: c)
    }

    static func parseISO(_ text: String) -> Date? {
        guard let m = text.firstMatch(of: /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|[+-]\d{2}:?\d{2})?$/) else {
            return parseLocal(text)
        }
        var c = DateComponents()
        c.year = Int(m.1); c.month = Int(m.2); c.day = Int(m.3)
        c.hour = Int(m.4); c.minute = Int(m.5); c.second = Int(m.6)
        if let zone = m.7 {
            let z = String(zone)
            if z == "Z" {
                c.timeZone = TimeZone(secondsFromGMT: 0)
            } else {
                let sign = z.hasPrefix("-") ? -1 : 1
                let digits = z.dropFirst().replacingOccurrences(of: ":", with: "")
                let hours = Int(digits.prefix(2)) ?? 0, minutes = Int(digits.suffix(2)) ?? 0
                c.timeZone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = c.timeZone ?? .current
        return cal.date(from: c)
    }
}

/// A command from the operations log mapped onto the app's areas.
enum HistoryCommand {
    static func theme(for command: String) -> FeatureTheme {
        switch command.lowercased() {
        case "clean": .clean
        case "uninstall": .uninstall
        case "optimize": .optimize
        case "purge": .purge
        case "installer", "installers": .installers
        default: .history
        }
    }

    static func title(for command: String) -> String {
        switch command.lowercased() {
        case "clean": "Clean"
        case "uninstall": "Uninstall"
        case "optimize": "Optimize"
        case "purge": "Project Purge"
        case "installer", "installers": "Installers"
        default: command.capitalized
        }
    }
}

/// One session plus everything derived from it.
struct HistoryEntry: Identifiable, Hashable {
    let session: HistoryReport.Session
    let start: Date?
    let end: Date?
    let sizeBytes: Int64
    /// Deletion audit rows logged inside this session's time window.
    let deletions: [HistoryReport.Deletion]
    /// Dry runs are logged exactly like real runs; this is the best available signal.
    let isLikelyPreview: Bool

    var id: String { session.id }
    var theme: FeatureTheme { HistoryCommand.theme(for: session.command) }
    var title: String { HistoryCommand.title(for: session.command) }
    var duration: TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
    var fileActionCount: Int {
        let a = session.actions
        return (a?.removed ?? 0) + (a?.trashed ?? 0) + (a?.rebuilt ?? 0)
    }
}

struct DeletionRow: Identifiable, Hashable {
    let id: String
    let date: Date?
    let timestamp: String
    let mode: String
    let status: String
    /// Bytes, or -1 when unknown.
    let size: Int64
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var dateSort: Date { date ?? .distantPast }

    init(_ d: HistoryReport.Deletion) {
        id = d.id
        timestamp = d.timestamp
        date = HistoryTimestamp.parseISO(d.timestamp)
        mode = d.mode ?? "—"
        status = d.status ?? "—"
        size = d.sizeKb.map { Int64($0) * 1024 } ?? -1
        path = d.path
    }

    var statusTint: Color {
        switch status {
        case "ok": .moleGood
        case "dry-run": .secondary
        case "rejected", "identity-changed", "mutable-parent", "privacy-denied", "sudo-blocked-test-mode", "invalid-mode": .moleWarn
        default: .moleBad
        }
    }

    var statusTitle: String {
        switch status {
        case "ok": "Deleted"
        case "dry-run": "Dry run"
        case "rejected": "Rejected"
        case "identity-changed": "Identity changed"
        case "mutable-parent": "Unsafe parent"
        case "privacy-denied": "Privacy denied"
        case "trash-failed": "Trash failed"
        case "timed-out": "Timed out"
        case "interrupted": "Interrupted"
        case "error": "Error"
        default: status.capitalized
        }
    }
}

struct HistorySummary: Equatable {
    var entries: [HistoryEntry] = []
    var freedBytes: Int64 = 0
    var previewBytes: Int64 = 0
    var items = 0
    var sessions = 0
    var previewSessions = 0
    var failedTasks = 0
    var byCommand: [(command: String, count: Int, bytes: Int64)] = []

    static func == (a: HistorySummary, b: HistorySummary) -> Bool { a.entries == b.entries }

    static func build(_ report: HistoryReport) -> HistorySummary {
        let deletionDates = report.deletions.map { ($0, HistoryTimestamp.parseISO($0.timestamp)) }
        var summary = HistorySummary()
        var commandTotals: [String: (Int, Int64)] = [:]
        // Sessions are newest first, so the previous element is the next session to start.
        let starts = report.sessions.map { HistoryTimestamp.parseLocal($0.startedAt) }
        for (index, session) in report.sessions.enumerated() {
            let start = starts[index]
            let nextStart = index > 0 ? starts[index - 1] : nil
            let end = (session.endedAt ?? "").isEmpty ? nil : HistoryTimestamp.parseLocal(session.endedAt!)
            let size = ByteFormat.parse(session.size ?? "") ?? 0
            var inside: [HistoryReport.Deletion] = []
            if let start {
                // Without an end marker, stop at the next session's start (or an hour).
                let fallback = min(nextStart.map { $0.addingTimeInterval(-1) } ?? .distantFuture, start.addingTimeInterval(3600))
                let upper = (end ?? max(start, fallback)).addingTimeInterval(1)
                inside = deletionDates.filter { pair in
                    guard let d = pair.1 else { return false }
                    return d >= start.addingTimeInterval(-1) && d <= upper
                }.map(\.0)
            }
            let a = session.actions
            let fileActions = (a?.removed ?? 0) + (a?.trashed ?? 0) + (a?.rebuilt ?? 0)
            let deletionsSayPreview = !inside.isEmpty && inside.allSatisfy { $0.status == "dry-run" }
            let deletionsSayReal = inside.contains { $0.status == "ok" }
            // A session that reports items but performed no file actions only planned work.
            let preview = deletionsSayPreview || (!deletionsSayReal && (session.items ?? 0) > 0 && fileActions == 0)
            let entry = HistoryEntry(session: session, start: start, end: end, sizeBytes: size,
                                     deletions: inside, isLikelyPreview: preview)
            summary.entries.append(entry)
            summary.sessions += 1
            summary.failedTasks += session.failedTasks ?? 0
            if preview {
                summary.previewSessions += 1
                summary.previewBytes += size
            } else {
                summary.freedBytes += size
                summary.items += session.items ?? 0
            }
            let key = session.command.lowercased()
            let current = commandTotals[key] ?? (0, 0)
            commandTotals[key] = (current.0 + 1, current.1 + size)
        }
        summary.byCommand = commandTotals.map { (command: $0.key, count: $0.value.0, bytes: $0.value.1) }
            .sorted { $0.count == $1.count ? $0.command < $1.command : $0.count > $1.count }
        return summary
    }
}

// MARK: - View model

@MainActor
@Observable
final class HistoryModel {
    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var report: HistoryReport?
    private(set) var summary = HistorySummary()
    private(set) var rows: [DeletionRow] = []
    private(set) var loadedAt: Date?

    var isLoading: Bool { phase == .loading }

    func load(service: MoleService) async -> Bool {
        phase = .loading
        do {
            // `MoleService.json` decodes with a default JSONDecoder, but Mole's keys are snake_case.
            let result = try await service.collect(["history", "--json", "--limit", "200"], timeout: 60)
            guard result.succeeded || !result.stdout.isEmpty else {
                throw MoleError.commandFailed(result.stderrString.isEmpty ? "Exit code \(result.exitCode)" : result.stderrString)
            }
            let report: HistoryReport
            do {
                report = try HistoryReport.decoder.decode(HistoryReport.self, from: MoleService.extractJSON(result.stdout))
            } catch {
                throw MoleError.decodeFailed("\(error)")
            }
            let summary = HistorySummary.build(report)
            withAnimation(.smooth) {
                self.report = report
                self.summary = summary
                self.rows = report.deletions.map(DeletionRow.init)
                self.loadedAt = Date()
                self.phase = .loaded
            }
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }
}
