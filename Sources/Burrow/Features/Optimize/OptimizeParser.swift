import Foundation

/// Live state of `mo optimize [--dry-run]`, built line by line from its piped output.
struct OptimizeReport: Sendable, Equatable {
    struct ResultLine: Sendable, Equatable, Hashable, Identifiable {
        enum Kind: Sendable, Equatable { case applied, attention, neutral, info, detail }
        let id: Int
        let kind: Kind
        let text: String
    }

    enum TaskState: Sendable, Equatable {
        case pending, running, applied, attention, unavailable, excluded

        var isFinished: Bool { self != .pending && self != .running }
    }

    struct TaskProgress: Sendable, Equatable {
        var state: TaskState = .pending
        var lines: [ResultLine] = []
    }

    struct SystemStats: Sendable, Equatable {
        var ramUsed: Double, ramTotal: Double, diskUsed: Double, diskTotal: Double, uptimeDays: Int
    }

    struct Summary: Sendable, Equatable {
        var heading: String
        var isDryRun: Bool
        /// "Would apply N" / "Applied N".
        var applied: Int?
        /// Extra stat after "Applied N optimizations, …".
        var keyStat: String?
        var outcomes: [String: Int] = [:]
        var details: [String] = []

        var attentionCount: Int { (outcomes["need attention"] ?? 0) + (outcomes["failed"] ?? 0) }
    }

    var headerSeen = false
    var isDryRun = false
    var system: SystemStats?
    var activeWhitelist: [String] = []
    /// Lines under "Performance diagnosis".
    var diagnosis: [ResultLine] = []
    /// Notes printed before the first task (sudo notices and the like).
    var notes: [ResultLine] = []
    var tasks: [String: TaskProgress] = [:]
    var currentTaskID: String?
    var summary: Summary?

    var completedCount: Int { tasks.values.filter { $0.state.isFinished }.count }
}

/// Pure line parser. Unknown `➤` headers (e.g. Mole's sudo prompt line) are ignored.
struct OptimizeParser {
    private(set) var report = OptimizeReport()
    private let taskIDByDisplayName: [String: String]
    private var lineCounter = 0
    private enum Block { case preamble, diagnosis, task, summary }
    private var block: Block = .preamble
    private var summaryLines: [String] = []

    init(tasks: [OptimizeTask]) {
        var map: [String: String] = [:]
        for t in tasks {
            map[t.displayName] = t.id
            map[t.whitelistName] = map[t.whitelistName] ?? t.id
        }
        taskIDByDisplayName = map
    }

    static let divider = String(repeating: "=", count: 20)

    mutating func consume(_ rawLine: String) {
        let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Summary block delimited by `=` rules.
        if trimmed.hasPrefix(Self.divider) && trimmed.allSatisfy({ $0 == "=" }) {
            if block == .summary {
                finishSummary()
                block = .preamble
            } else {
                finishCurrentTask()
                block = .summary
                summaryLines = []
            }
            return
        }
        if block == .summary {
            if !trimmed.isEmpty { summaryLines.append(trimmed) }
            return
        }

        if trimmed.isEmpty { return }

        if trimmed == "Optimize" { report.headerSeen = true; return }
        if trimmed.hasPrefix("→ DRY RUN MODE") { report.isDryRun = true; return }

        if trimmed.hasPrefix("⚙ System"), let stats = Self.parseSystem(trimmed) {
            report.system = stats
            return
        }
        if trimmed.hasPrefix("⚙ Active Whitelist:") {
            report.activeWhitelist = trimmed.dropFirst("⚙ Active Whitelist:".count)
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return
        }
        if trimmed == "Performance diagnosis" {
            block = .diagnosis
            return
        }
        if trimmed.hasPrefix("➤ ") {
            let name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if let id = taskIDByDisplayName[name] {
                finishCurrentTask()
                report.currentTaskID = id
                report.tasks[id, default: .init()].state = .running
                block = .task
            }
            return
        }

        let entry = makeLine(line)
        switch block {
        case .diagnosis:
            if line.hasPrefix(" ") { report.diagnosis.append(entry) } else { report.notes.append(entry) }
        case .task:
            if let id = report.currentTaskID { report.tasks[id, default: .init()].lines.append(entry) }
        case .preamble, .summary:
            report.notes.append(entry)
        }
    }

    /// Call when the process exits so the last task is marked finished.
    mutating func finish() {
        finishCurrentTask()
        if block == .summary { finishSummary() }
    }

    private mutating func makeLine(_ line: String) -> OptimizeReport.ResultLine {
        lineCounter += 1
        let indent = line.prefix { $0 == " " }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let first = trimmed.first.map(String.init) ?? ""
        let kind: OptimizeReport.ResultLine.Kind
        var text = trimmed
        switch first {
        case "→", "✓": kind = .applied
        case "◎", "☻", "!": kind = .attention
        case "-", "○": kind = .neutral
        case "⊙", "ℹ", "•": kind = .info
        default: kind = indent >= 4 ? .detail : .info
        }
        if kind != .detail, ["→", "✓", "◎", "☻", "!", "-", "○", "⊙", "ℹ", "•"].contains(first) {
            text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return .init(id: lineCounter, kind: kind, text: text)
    }

    private mutating func finishCurrentTask() {
        guard let id = report.currentTaskID, var progress = report.tasks[id] else { return }
        progress.state = Self.derive(progress.lines)
        report.tasks[id] = progress
        report.currentTaskID = nil
    }

    static func derive(_ lines: [OptimizeReport.ResultLine]) -> OptimizeReport.TaskState {
        if lines.contains(where: { $0.text.hasPrefix("Skipped (whitelisted)") }) { return .excluded }
        if lines.contains(where: { $0.kind == .attention }) { return .attention }
        let meaningful = lines.filter { $0.kind != .detail && $0.kind != .info }
        if !meaningful.isEmpty && meaningful.allSatisfy({ $0.kind == .neutral }) { return .unavailable }
        return .applied
    }

    private mutating func finishSummary() {
        guard let heading = summaryLines.first else { return }
        var summary = OptimizeReport.Summary(heading: heading, isDryRun: heading.hasPrefix("Dry Run"))
        for line in summaryLines.dropFirst() {
            if let m = line.firstMatch(of: /^(?:Would apply|Applied) (\d+) optimizations?(?:, (.+))?$/) {
                summary.applied = Int(m.1)
                summary.keyStat = m.2.map(String.init)
            } else if line.contains("|") || line.firstMatch(of: /^\d+ (unchanged|skipped|unavailable|need attention|failed)$/) != nil {
                for part in line.split(separator: "|") {
                    let p = part.trimmingCharacters(in: .whitespaces)
                    if let m = p.firstMatch(of: /^(\d+) (.+)$/), let n = Int(m.1) { summary.outcomes[String(m.2)] = n }
                }
            } else {
                summary.details.append(line)
            }
        }
        report.summary = summary
    }

    static func parseSystem(_ line: String) -> OptimizeReport.SystemStats? {
        guard let m = line.firstMatch(of: /(\d+(?:\.\d+)?)\/(\d+(?:\.\d+)?) GB RAM \| (\d+(?:\.\d+)?)\/(\d+(?:\.\d+)?) GB Disk \| Uptime (\d+)d/) else { return nil }
        return .init(ramUsed: Double(m.1) ?? 0, ramTotal: Double(m.2) ?? 0, diskUsed: Double(m.3) ?? 0,
                     diskTotal: Double(m.4) ?? 0, uptimeDays: Int(m.5) ?? 0)
    }
}
