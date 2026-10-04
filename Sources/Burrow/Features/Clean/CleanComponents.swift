import SwiftUI

// MARK: - Categories list

/// Every category Mole found, as one ranked list: largest first, aligned columns, details on demand.
struct CleanSectionsList: View {
    let report: CleanReport
    let live: Bool
    let vm: CleanModel
    var protection: String? = nil
    var systemSkipped = false
    var openProtection: (() -> Void)? = nil
    let openDetail: (CleanDetailRequest) -> Void
    /// Automation aid for screenshots: `-MoleE2EExpand <name>` opens that row.
    @State private var expanded: Set<String> = Set(UserDefaults.standard.string(forKey: "MoleE2EExpand").map { [$0] } ?? [])

    var body: some View {
        let found = report.sections.filter { !$0.rows.filter { $0.kind != .review }.isEmpty }
        // While Mole is still scanning, rows keep their arrival order so nothing jumps around.
        let sections = live ? found : found.sorted { $0.totalBytes > $1.totalBytes }
        let tidy = report.sections.filter { $0.nothingToClean && $0.rows.isEmpty }
        let total = max(1, sections.map(\.totalBytes).reduce(0, +))
        if !sections.isEmpty || !tidy.isEmpty {
            GlassCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Categories").font(.headline)
                        Spacer()
                        Text(live ? "\(sections.count) so far" : "Largest first")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    ForEach(sections) { section in
                        Divider().opacity(0.5)
                        CleanSectionRow(section: section,
                                        share: Double(section.totalBytes) / Double(total),
                                        isCurrent: live && section.id == report.sections.last?.id,
                                        hasDetail: !(vm.preview?.entries(for: section.title).isEmpty ?? true) && !live,
                                        expanded: expanded.contains(section.title),
                                        toggle: { withAnimation(.snappy) { expanded.formSymmetricDifference([section.title]) } },
                                        openDetail: { openDetail(CleanDetailRequest(section: section.title)) })
                    }
                    if !tidy.isEmpty || protection != nil || systemSkipped {
                        Divider().opacity(0.5)
                        VStack(alignment: .leading, spacing: 8) {
                            if !tidy.isEmpty {
                                footnote("checkmark.circle.fill", .moleGood,
                                         "Already tidy: " + tidy.map(\.title).joined(separator: ", "))
                            }
                            if systemSkipped {
                                footnote("lock.shield.fill", .orange,
                                         "System caches were not scanned. Turn on “Include system caches” below to add them.")
                            }
                            if let protection {
                                HStack(spacing: 8) {
                                    footnote("checkmark.shield.fill", .moleGood, "Protection: \(protection)")
                                    if let openProtection {
                                        Button("Manage", action: openProtection).buttonStyle(.link).font(.caption)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                }
                .animation(.smooth(duration: 0.3), value: sections.map(\.id))
            }
        }
    }

    private func footnote(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption)
    }
}

struct CleanSectionRow: View {
    let section: CleanReport.Section
    /// This category's part of everything found, 0–1.
    let share: Double
    let isCurrent: Bool
    let hasDetail: Bool
    let expanded: Bool
    let toggle: () -> Void
    let openDetail: () -> Void

    private var tint: Color { CleanStyle.color(for: section.title) }

    var body: some View {
        let rows = section.rows.filter { $0.kind != .review }
            .sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        let maxBytes = max(1, rows.compactMap(\.sizeBytes).max() ?? 1)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    TidyGlyph(symbol: CleanStyle.symbol(for: section.title), tint: tint, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.title).font(.callout.weight(.semibold))
                        Text(subtitle(rows)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isCurrent { ProgressView().controlSize(.small) }
                    CapsuleBar(fraction: share, tint: tint, height: 6)
                        .frame(width: 180)
                        .opacity(section.totalBytes > 0 ? 1 : 0)
                    Text(section.totalBytes > 0 ? ByteFormat.string(section.totalBytes) : "—")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(section.totalBytes)))
                        .frame(width: 92, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .tidyHover(radius: 0)
            .accessibilityLabel("\(section.title), \(ByteFormat.string(section.totalBytes))")
            .accessibilityHint(expanded ? "Hides what is inside" : "Shows what is inside")
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        CleanRowView(row: row, tint: tint, maxBytes: maxBytes)
                    }
                    if hasDetail {
                        Button("Show Every File…", action: openDetail)
                            .buttonStyle(.link)
                            .font(.caption.weight(.semibold))
                            .padding(.leading, 8)
                            .padding(.top, 4)
                            .help("See every path Mole found in \(section.title)")
                    }
                }
                .padding(.leading, 58)
                .padding(.trailing, 46)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
    }

    private func subtitle(_ rows: [CleanReport.Row]) -> String {
        let items = section.itemCount
        let groups = rows.filter { $0.kind == .wouldClean || $0.kind == .cleaned }.count
        var parts: [String] = []
        if groups > 0 { parts.append("\(groups) group\(groups == 1 ? "" : "s")") }
        if items > 0 { parts.append("\(items.formatted()) item\(items == 1 ? "" : "s")") }
        let skipped = rows.filter { $0.kind == .warning || $0.kind == .alert }.count
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }
}

struct CleanRowView: View {
    let row: CleanReport.Row
    let tint: Color
    let maxBytes: Int64

    var body: some View {
        let (symbol, color) = CleanStyle.rowSymbol(row.kind)
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.caption)
            Text(row.label).font(.callout).lineLimit(1)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let bytes = row.sizeBytes, bytes > 0 {
                CapsuleBar(fraction: Double(bytes) / Double(maxBytes), tint: tint.opacity(0.7), height: 4)
                    .frame(width: 120)
            }
            Text(trailing)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .tidyHover(radius: 8)
        .help(row.detail.map { "\(row.label) · \($0)" } ?? row.label)
    }

    private var trailing: String {
        if let bytes = row.sizeBytes { return ByteFormat.string(bytes) }
        return ""
    }

    private var note: String? {
        guard row.sizeBytes ?? 0 == 0, let detail = row.detail else { return nil }
        return detail.replacingOccurrences(of: " dry", with: "")
    }
}

// MARK: - Review-only large files

struct CleanReviewCard: View {
    let rows: [CleanReport.Row]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Large files to review", symbol: "eye", detail: "Never deleted by Mole")
                Text("These are big, but only you can decide whether you still need them. Mole lists them for review and leaves them alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        if let path = row.path {
                            Image(nsImage: Finder.icon(for: path)).resizable().frame(width: 28, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label).font(.callout.weight(.medium))
                            if let path = row.path {
                                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Text(row.sizeText.flatMap(ByteFormat.parse).map(ByteFormat.string) ?? "")
                            .font(.callout.monospacedDigit().weight(.semibold))
                        if let path = row.path {
                            Button("Reveal", systemImage: "folder") { Finder.reveal(path) }
                                .buttonStyle(.soft)
                                .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .tidyHover()
                    .tidyFileMenu(row.path ?? "")
                }
            }
        }
    }
}

// MARK: - Confirmation

struct CleanConfirmSheet: View {
    let vm: CleanModel
    let theme: FeatureTheme
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let summary = vm.scanReport?.summary
        // Everything here describes the configuration the scan previewed, which is exactly what runs.
        let config = vm.scannedConfig ?? vm.currentConfig
        ConfirmSheet(theme: theme,
                     title: config.volume.map { "Clean \($0.name)?" } ?? "Clean your Mac?",
                     message: "Mole removes what it found in the preview. This can’t be undone.",
                     confirmTitle: "Clean Now",
                     onConfirm: onConfirm, onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(summary?.spaceBytes.map(ByteFormat.string) ?? summary?.spaceText ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                    Text(detailLine(summary)).foregroundStyle(.secondary)
                }
                Divider()
                if let blocker = vm.cleanBlocker {
                    bullet("exclamationmark.triangle.fill", .moleWarn, blocker)
                }
                if let volume = config.volume {
                    bullet("externaldrive.fill", .blue, "Only \(volume.path) is touched: .Trashes, .TemporaryItems, ._ files and .DS_Store.")
                } else {
                    if config.keepsTrash {
                        bullet("trash.slash.fill", .moleGood, "Your Trash is kept as it is.")
                    } else {
                        bullet("trash.fill", .moleBad, "Your Trash will be emptied, too. Turn on “Keep Trash contents” to skip it.")
                    }
                    if config.includesSystem {
                        bullet("lock.shield.fill", .orange, "System caches are included. You’ll be asked for your administrator password.")
                    } else {
                        bullet("person.fill", .secondary, "User-level only: system caches are skipped.")
                    }
                }
                bullet("checkmark.shield.fill", .moleGood, "Protected paths and large files marked for review are never deleted.")
                bullet("info.circle.fill", .secondary, "Mole re-checks everything as it cleans, so the final amount can differ slightly.")
            }
            .padding(16)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
        }
    }

    private func detailLine(_ s: CleanReport.Summary?) -> String {
        var parts: [String] = []
        if let items = s?.items { parts.append("\(items.formatted()) items") }
        if let c = s?.categories { parts.append("\(c) categories") }
        return parts.joined(separator: " · ")
    }

    private func bullet(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
    }
}

// MARK: - Success

struct CleanSuccessCard: View {
    let vm: CleanModel
    let report: CleanReport
    let theme: FeatureTheme
    let done: () -> Void

    var body: some View {
        let s = report.summary
        let ok = s?.outcome == .complete
        GlassCard(padding: 28) {
            HStack(alignment: .top, spacing: 20) {
                ResultBurst(style: ok ? .success : .warning, theme: theme, size: 48)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title(s)).font(.system(size: 24, weight: .bold, design: .rounded))
                    if let space = s?.spaceText, !(s?.alreadyClean ?? false) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if s?.atLeast == true && s?.spaceBytes != nil { Text("at least").foregroundStyle(.secondary) }
                            Text(s?.spaceBytes.map(ByteFormat.string) ?? space)
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.accent)
                                .contentTransition(.numericText())
                            Text("freed").font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    let facts = facts(s)
                    if !facts.isEmpty {
                        Text(facts).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(s?.messages ?? [], id: \.self) { m in
                        Text(m).font(.callout).foregroundStyle(.secondary)
                    }
                    if s == nil {
                        Text("Mole finished without a summary. Scan again to see what is left.").foregroundStyle(.secondary)
                    }
                    Button("Done", systemImage: "checkmark", action: done)
                        .buttonStyle(.hero(theme))
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func facts(_ s: CleanReport.Summary?) -> String {
        var parts: [String] = []
        if let items = s?.items { parts.append("\(items.formatted()) items removed") }
        if let free = s?.freeSpace { parts.append("\(CleanStyle.human(free)) free now") }
        if let delta = s?.freeDelta { parts.append(delta) }
        return parts.joined(separator: " · ")
    }

    private func title(_ s: CleanReport.Summary?) -> String {
        guard let s else { return "Cleanup finished" }
        switch s.outcome {
        case .complete: return s.alreadyClean ? "Already spotless" : "All clean!"
        case .cancelled: return "Cleanup cancelled"
        case .interrupted: return "Cleanup interrupted"
        case .incomplete: return "Cleanup incomplete"
        case .other: return s.heading
        }
    }
}

// MARK: - Flow layout for chips

struct TidyFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
