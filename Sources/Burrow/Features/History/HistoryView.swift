import AppKit
import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(MoleService.self) private var service
    @State private var model = HistoryModel()
    @State private var showAllSessions = false

    private let theme = FeatureTheme.history

    var body: some View {
        FeaturePage(theme: theme) {
            PageHeader(theme: theme) { headerActions }
        } content: {
            if model.report == nil, case .failed(let message) = model.phase {
                ErrorBanner(message: message) { reload() }
                EmptyStateView(symbol: "doc.text.magnifyingglass", title: "History unavailable",
                               message: "Mole's history could not be read. The raw logs are still in the logs folder.")
            } else if model.report == nil {
                ScanningView(theme: theme, title: "Reading Mole's logs…", detail: "mo history --json")
                    .padding(.top, 40)
            } else {
                if case .failed(let message) = model.phase { ErrorBanner(message: message) { reload() } }
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: Metrics.spacing) { loadedContent }
                        .task {
                            // E2E screenshots: `-MoleE2EScrollAnchor audit` scrolls to a section.
                            guard let anchor = UserDefaults.standard.string(forKey: "MoleE2EScrollAnchor") else { return }
                            try? await Task.sleep(for: .seconds(2))
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                }
            }
        }
        .task { await initialLoad() }
    }

    // MARK: Header

    private var headerActions: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Open Logs Folder", systemImage: "folder") { Finder.open(logsFolder) }
                Button("Open operations.log", systemImage: "doc.text") { openLog(model.report?.logs?.operations ?? MolePaths.operationsLog) }
                Button("Open deletions.log", systemImage: "doc.text") { openLog(model.report?.logs?.deletions ?? MolePaths.deletionsLog) }
                Divider()
                Button("Reveal operations.log in Finder", systemImage: "magnifyingglass") {
                    Finder.reveal(model.report?.logs?.operations ?? MolePaths.operationsLog)
                }
            } label: {
                Label("Logs", systemImage: "doc.text")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Open Mole's log files")

            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, value: model.loadedAt)
            }
            .buttonStyle(.glass)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isLoading)
            .help("Reload history (⌘R)")
        }
    }

    private var logsFolder: String {
        if let ops = model.report?.logs?.operations { return (ops as NSString).deletingLastPathComponent }
        return MolePaths.logs
    }

    private func openLog(_ path: String) {
        if FileManager.default.fileExists(atPath: path) {
            Finder.open(path)
        } else {
            Finder.open(logsFolder)
        }
    }

    // MARK: Content

    @ViewBuilder private var loadedContent: some View {
        let summary = model.summary
        if summary.entries.isEmpty && model.rows.isEmpty {
            GlassCard {
                EmptyStateView(symbol: "clock.badge.checkmark", title: "No history yet",
                               message: "Every clean, uninstall, optimize and purge Mole runs will be listed here, with what it removed.",
                               tint: theme.accent)
            }
        } else {
            SummaryHero(summary: summary, theme: theme)
            if summary.previewSessions > 0 {
                InfoBanner(symbol: "eye", title: "Previews are logged like real runs",
                           message: "Mole records dry runs in the same log. \(summary.previewSessions) session\(summary.previewSessions == 1 ? " looks" : "s look") like a preview (no files were changed) and \(summary.previewSessions == 1 ? "is" : "are") marked and left out of the total.",
                           tint: .secondary)
            }
            sessionsSection(summary.entries).id("sessions")
            DeletionAuditSection(rows: model.rows, theme: theme).id("audit")
        }
    }

    private func sessionsSection(_ entries: [HistoryEntry]) -> some View {
        let visible = showAllSessions ? entries : Array(entries.prefix(25))
        let groups = Dictionary(grouping: visible) { entry in
            entry.start.map { Calendar.current.startOfDay(for: $0) } ?? .distantPast
        }
        let days = groups.keys.sorted(by: >)
        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Sessions", symbol: "list.bullet.below.rectangle", detail: "\(entries.count) recorded")
            if entries.isEmpty {
                GlassCard { Text("No sessions recorded.").foregroundStyle(.secondary) }
            }
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: 8) {
                    Text(dayTitle(day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    GlassCard(padding: 6) {
                        VStack(spacing: 0) {
                            let rows = groups[day] ?? []
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                                SessionRow(entry: entry)
                                if index < rows.count - 1 {
                                    Divider().padding(.leading, 62).opacity(0.5)
                                }
                            }
                        }
                    }
                }
            }
            if entries.count > 25 {
                Button(showAllSessions ? "Show Fewer" : "Show All \(entries.count) Sessions") {
                    withAnimation(.smooth) { showAllSessions.toggle() }
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if day == .distantPast { return "Unknown date" }
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    // MARK: Loading

    private func initialLoad() async {
        guard model.phase == .idle else { return }
        await load()
    }

    private func reload() {
        Task { await load() }
    }

    private func load() async {
        let ok = await model.load(service: service)
        let s = model.summary
        var detail = "Loaded \(s.sessions) sessions and \(model.rows.count) deletion records"
        if case .failed(let message) = model.phase { detail = message }
        app.automation.record("history", passed: ok, detail: detail, metrics: [
            "sessions": "\(s.sessions)",
            "deletions": "\(model.rows.count)",
            "freed": ByteFormat.string(s.freedBytes),
            "previewed": ByteFormat.string(s.previewBytes),
            "previewSessions": "\(s.previewSessions)",
            "commands": s.byCommand.map { "\($0.command)=\($0.count)" }.joined(separator: ","),
        ])
    }
}

// MARK: - Summary hero

private struct SummaryHero: View {
    let summary: HistorySummary
    let theme: FeatureTheme
    @State private var selectedCount: Int?

    var body: some View {
        GlassCard(padding: 24) {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Space reclaimed")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(ByteFormat.string(summary.freedBytes))
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(summary.freedBytes > 0 ? AnyShapeStyle(FeatureTheme.clean.gradient) : AnyShapeStyle(.primary))
                        if summary.previewBytes > 0 {
                            Text("\(ByteFormat.string(summary.previewBytes)) more found in previews")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        stat("\(summary.sessions)", "Sessions", "clock")
                        stat("\(summary.items)", "Items", "doc.on.doc")
                        stat("\(summary.failedTasks)", "Failed tasks", "exclamationmark.triangle",
                             tint: summary.failedTasks > 0 ? .moleWarn : nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !summary.byCommand.isEmpty {
                    breakdown
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ symbol: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol).font(.caption).foregroundStyle(tint ?? theme.accent)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var breakdown: some View {
        let data = summary.byCommand
        let total = data.reduce(0) { $0 + $1.count }
        let highlighted = highlightedCommand
        return HStack(spacing: 20) {
            Chart(data, id: \.command) { item in
                SectorMark(angle: .value("Sessions", item.count), innerRadius: .ratio(0.64), angularInset: 2)
                    .cornerRadius(5)
                    .foregroundStyle(HistoryCommand.theme(for: item.command).gradient)
                    .opacity(highlighted == nil || highlighted == item.command ? 1 : 0.35)
            }
            .chartAngleSelection(value: $selectedCount)
            .chartBackground { _ in
                VStack(spacing: 0) {
                    let focus = data.first { $0.command == highlighted }
                    Text("\(focus?.count ?? total)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(focus.map { HistoryCommand.title(for: $0.command) } ?? "sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 150, height: 150)
            .animation(.smooth, value: highlighted)
            .accessibilityLabel("Sessions by command")

            VStack(alignment: .leading, spacing: 8) {
                ForEach(data, id: \.command) { item in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(HistoryCommand.theme(for: item.command).gradient)
                            .frame(width: 10, height: 10)
                        Text(HistoryCommand.title(for: item.command)).font(.callout)
                        Spacer(minLength: 12)
                        Text("\(item.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(width: 170)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Maps the cumulative angle selection back to a command.
    private var highlightedCommand: String? {
        guard let selectedCount else { return nil }
        var running = 0
        for item in summary.byCommand {
            running += item.count
            if selectedCount <= running { return item.command }
        }
        return nil
    }
}

// MARK: - Session row

private struct SessionRow: View {
    let entry: HistoryEntry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            FeatureIcon(theme: entry.theme, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.title).font(.headline)
                    if entry.isLikelyPreview {
                        Pill(text: "Preview", symbol: "eye", tint: .secondary)
                            .help("No files were changed in this session. Dry runs are logged like real runs.")
                    }
                    if entry.end == nil {
                        if let start = entry.start, Date().timeIntervalSince(start) < 3 * 3600 {
                            Pill(text: "Running or interrupted", symbol: "hourglass", tint: .blue)
                                .help("No end marker yet: the run is still going, or it stopped early.")
                        } else {
                            Pill(text: "Interrupted", symbol: "exclamationmark.circle", tint: .moleWarn)
                                .help("Mole never logged the end of this session.")
                        }
                    }
                    if let failed = entry.session.failedTasks, failed > 0 {
                        Pill(text: "\(failed) task\(failed == 1 ? "" : "s") failed", symbol: "xmark.octagon", tint: .moleBad)
                    }
                }
                Text(timeLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                chips
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.sizeBytes > 0 ? ByteFormat.string(entry.sizeBytes) : "0 KB")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.isLikelyPreview || entry.sizeBytes == 0 ? .secondary : .primary)
                Text("\(entry.session.items ?? 0) item\((entry.session.items ?? 0) == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovering ? entry.theme.accent.opacity(0.08) : .clear, in: .rect(cornerRadius: 14))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button("Copy Summary", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(entry.session.command) \(entry.session.startedAt), \(entry.session.items ?? 0) items, \(entry.session.size ?? "0B")", forType: .string)
            }
            Button("Reveal operations.log", systemImage: "folder") { Finder.reveal(MolePaths.operationsLog) }
        }
        .accessibilityElement(children: .combine)
    }

    private var timeLine: String {
        guard let start = entry.start else { return entry.session.startedAt }
        var text = start.formatted(date: .omitted, time: .shortened)
        if let end = entry.end {
            text += " – " + end.formatted(date: .omitted, time: .shortened)
        }
        if let duration = entry.duration {
            text += " · " + Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        }
        return text
    }

    @ViewBuilder private var chips: some View {
        let a = entry.session.actions
        let items: [(Int, String, String, Color)] = [
            (a?.removed ?? 0, "removed", "trash", .moleBad),
            (a?.trashed ?? 0, "trashed", "trash.circle", .orange),
            (a?.rebuilt ?? 0, "rebuilt", "arrow.triangle.2.circlepath", .blue),
            (a?.skipped ?? 0, "skipped", "forward", .secondary),
            (a?.failed ?? 0, "failed", "xmark.circle", .moleWarn),
            (a?.other ?? 0, "other", "ellipsis.circle", .secondary),
        ].filter { $0.0 > 0 }
        let deletions = entry.deletions.count
        if !items.isEmpty || deletions > 0 {
            HStack(spacing: 6) {
                ForEach(items, id: \.1) { item in
                    Pill(text: "\(item.0) \(item.1)", symbol: item.2, tint: item.3)
                }
                if deletions > 0 {
                    Pill(text: "\(deletions) audited", symbol: "checklist", tint: .indigo)
                }
            }
        }
    }
}

// MARK: - Deletion audit

private struct DeletionAuditSection: View {
    let rows: [DeletionRow]
    let theme: FeatureTheme
    @State private var search = ""
    @State private var status: String = "all"
    @State private var mode: String = "all"
    @State private var selection = Set<DeletionRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\DeletionRow.dateSort, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Deletion Audit", symbol: "checklist", detail: "\(filtered.count) of \(rows.count)")
            GlassCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search paths", text: $search)
                                .textFieldStyle(.plain)
                            if !search.isEmpty {
                                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Clear search")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                        .frame(maxWidth: 320)

                        Picker("Status", selection: $status) {
                            Text("All statuses").tag("all")
                            Divider()
                            ForEach(statuses, id: \.self) { s in
                                Text(DeletionRow.titleFor(status: s)).tag(s)
                            }
                        }
                        .fixedSize()
                        Picker("Mode", selection: $mode) {
                            Text("Any mode").tag("all")
                            Divider()
                            ForEach(modes, id: \.self) { m in Text(m.capitalized).tag(m) }
                        }
                        .fixedSize()
                        Spacer()
                    }
                    if rows.isEmpty {
                        EmptyStateView(symbol: "checklist", title: "No deletions recorded",
                                       message: "Mole audits every file it removes for uninstalls. Nothing has been logged yet.")
                    } else if filtered.isEmpty {
                        EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "No matches",
                                       message: "Try a different search or filter.")
                    } else {
                        table
                    }
                }
            }
        }
    }

    private var statuses: [String] { Array(Set(rows.map(\.status))).sorted() }
    private var modes: [String] { Array(Set(rows.map(\.mode))).sorted() }

    private var filtered: [DeletionRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            (status == "all" || row.status == status) &&
            (mode == "all" || row.mode == mode) &&
            (q.isEmpty || row.path.lowercased().contains(q))
        }
        .sorted(using: sortOrder)
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Status", value: \.status) { row in
                Pill(text: row.statusTitle, symbol: row.status == "ok" ? "checkmark" : row.status == "dry-run" ? "eye" : "exclamationmark.triangle",
                     tint: row.statusTint)
                    .fixedSize()
            }
            .width(min: 96, ideal: 104, max: 140)
            TableColumn("Mode", value: \.mode) { row in
                Label(row.mode.capitalized, systemImage: row.mode == "permanent" ? "flame" : "trash")
                    .foregroundStyle(row.mode == "permanent" ? Color.moleBad : .secondary)
            }
            .width(min: 84, ideal: 96, max: 120)
            TableColumn("Size", value: \.size) { row in
                Text(row.size > 0 ? ByteFormat.string(row.size) : row.size == 0 ? "0 KB" : "—")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 72, max: 100)
            TableColumn("Time", value: \.dateSort) { row in
                Text(row.date.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()) } ?? row.timestamp)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 136, max: 180)
            TableColumn("Path", value: \.path) { row in
                HStack(spacing: 6) {
                    Image(nsImage: Finder.icon(for: row.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(row.path.abbreviatingHome)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.path)
                }
            }
            .width(min: 200)
        }
        .contextMenu(forSelectionType: DeletionRow.ID.self) { ids in
            let paths = rows.filter { ids.contains($0.id) }.map(\.path)
            if !paths.isEmpty {
                Button("Reveal in Finder", systemImage: "folder") {
                    let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                    if urls.isEmpty {
                        // Deleted items are gone; show the nearest folder that still exists.
                        Finder.open(nearestExistingFolder(paths[0]))
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                    }
                }
                Button(paths.count == 1 ? "Copy Path" : "Copy \(paths.count) Paths", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                }
            }
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                Finder.open(nearestExistingFolder(row.path))
            }
        }
        .frame(height: min(460, CGFloat(filtered.count) * 28 + 36))
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .animation(.smooth, value: filtered.count)
    }

    private func nearestExistingFolder(_ path: String) -> String {
        var current = path
        let fm = FileManager.default
        while !current.isEmpty && current != "/" {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: current, isDirectory: &isDir), isDir.boolValue { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return NSHomeDirectory()
    }
}

extension DeletionRow {
    static func titleFor(status: String) -> String {
        DeletionRow(HistoryReport.Deletion(timestamp: "", mode: nil, status: status, sizeKb: nil, path: "")).statusTitle
    }
}
