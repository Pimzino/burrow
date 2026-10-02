import SwiftUI

// MARK: - Sections grid

struct CleanSectionsGrid: View {
    let report: CleanReport
    let live: Bool
    let vm: CleanModel
    let openDetail: (CleanDetailRequest) -> Void

    var body: some View {
        let sections = report.sections.filter { !$0.rows.filter { $0.kind != .review }.isEmpty }
        let clean = report.sections.filter { $0.nothingToClean && $0.rows.isEmpty }
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if !sections.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: Metrics.spacing, alignment: .top)],
                          alignment: .leading, spacing: Metrics.spacing) {
                    ForEach(sections) { section in
                        CleanSectionCard(section: section,
                                         isCurrent: live && section.id == report.sections.last?.id,
                                         hasDetail: !(vm.preview?.entries(for: section.title).isEmpty ?? true) && !live) {
                            openDetail(CleanDetailRequest(section: section.title))
                        }
                        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: sections.map(\.rows.count))
            }
            if !clean.isEmpty {
                GlassCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Already tidy", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.moleGood)
                        TidyFlowLayout(spacing: 8) {
                            ForEach(clean) { s in
                                Pill(text: s.title, symbol: CleanStyle.symbol(for: s.title), tint: .secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CleanSectionCard: View {
    let section: CleanReport.Section
    let isCurrent: Bool
    let hasDetail: Bool
    let openDetail: () -> Void
    @State private var expanded = false

    private var tint: Color { CleanStyle.color(for: section.title) }

    var body: some View {
        let rows = section.rows.filter { $0.kind != .review }
            .sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        let maxBytes = max(1, rows.compactMap(\.sizeBytes).max() ?? 1)
        let shown = expanded ? rows : Array(rows.prefix(5))
        GlassCard(padding: 18, tint: isCurrent ? tint : nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TidyGlyph(symbol: CleanStyle.symbol(for: section.title), tint: tint, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.title).font(.headline)
                        Text(subtitle(rows)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isCurrent { ProgressView().controlSize(.small) }
                    Text(section.totalBytes > 0 ? ByteFormat.string(section.totalBytes) : "—")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(section.totalBytes)))
                }
                VStack(spacing: 2) {
                    ForEach(shown) { row in
                        CleanRowView(row: row, tint: tint, maxBytes: maxBytes)
                    }
                }
                HStack {
                    if rows.count > 5 {
                        Button(expanded ? "Show Less" : "Show All \(rows.count)") {
                            withAnimation(.snappy) { expanded.toggle() }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                    }
                    Spacer()
                    if hasDetail {
                        Button(action: openDetail) {
                            Label("Files", systemImage: "list.bullet.indent")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("See every path Mole found in \(section.title)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title), \(ByteFormat.string(section.totalBytes))")
    }

    private func subtitle(_ rows: [CleanReport.Row]) -> String {
        let items = section.itemCount
        let groups = rows.filter { $0.kind == .wouldClean || $0.kind == .cleaned }.count
        var parts = ["\(groups) group\(groups == 1 ? "" : "s")"]
        if items > 0 { parts.append("\(items.formatted()) items") }
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
            Image(systemName: symbol).foregroundStyle(color).font(.callout)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label).font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(trailing).font(.callout.monospacedDigit()).foregroundStyle(row.sizeBytes == nil ? .secondary : .primary)
                }
                if let bytes = row.sizeBytes, bytes > 0 {
                    CapsuleBar(fraction: Double(bytes) / Double(maxBytes), tint: tint, height: 4)
                } else if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .tidyHover()
        .help(row.detail.map { "\(row.label) · \($0)" } ?? row.label)
    }

    private var trailing: String {
        if let bytes = row.sizeBytes { return ByteFormat.string(bytes) }
        return ""
    }

    private var note: String? {
        guard let detail = row.detail else { return nil }
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
                                .buttonStyle(.glass)
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
                        .foregroundStyle(theme.gradient)
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
    @State private var appeared = false

    var body: some View {
        let s = report.summary
        let ok = s?.outcome == .complete
        GlassCard(padding: 32, tint: ok ? theme.accent : .moleWarn) {
            HStack(spacing: 32) {
                ZStack {
                    if ok { TidyBurst(colors: theme.colors + [.yellow, .white]) }
                    Circle().fill((ok ? theme.gradient : LinearGradient(colors: [.moleWarn, .orange], startPoint: .top, endPoint: .bottom)))
                        .frame(width: 110, height: 110)
                        .shadow(color: theme.accent.opacity(0.4), radius: 18, y: 6)
                    Image(systemName: ok ? "checkmark" : "exclamationmark")
                        .font(.system(size: 50, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: appeared)
                }
                .frame(width: 190, height: 190)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
                VStack(alignment: .leading, spacing: 10) {
                    Text(title(s)).font(.system(size: 28, weight: .bold, design: .rounded))
                    if let space = s?.spaceText, !(s?.alreadyClean ?? false) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if s?.atLeast == true && s?.spaceBytes != nil { Text("at least").foregroundStyle(.secondary) }
                            Text(s?.spaceBytes.map(ByteFormat.string) ?? space)
                                .font(.system(size: 54, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.gradient)
                                .contentTransition(.numericText())
                            Text("freed").font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        if let free = s?.freeSpace {
                            Pill(text: "Free space \(CleanStyle.human(free))", symbol: "internaldrive", tint: .blue)
                        }
                        if let delta = s?.freeDelta {
                            Pill(text: delta, symbol: "arrow.up.right", tint: .moleGood)
                        }
                        if let items = s?.items { Pill(text: "\(items.formatted()) items", symbol: "doc.on.doc", tint: theme.accent) }
                    }
                    ForEach(s?.messages ?? [], id: \.self) { m in
                        Text(m).font(.callout).foregroundStyle(.secondary)
                    }
                    if s == nil {
                        Text("Mole finished without a summary. Open the output below for details.").foregroundStyle(.secondary)
                    }
                    Button("Done", systemImage: "checkmark", action: done)
                        .buttonStyle(.hero(theme))
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { appeared = true } }
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
