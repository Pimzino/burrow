import SwiftUI

/// One folder: breadcrumbs, summary, treemap, the sorted contents list and the largest files.
struct AnalyzeDirectorySection: View {
    let report: AnalyzeReport
    let analyzer: AnalyzeModel
    let actions: AnalyzeActions

    enum SortOrder: String, CaseIterable, Identifiable {
        case size = "Size", name = "Name", recent = "Last Opened"
        var id: String { rawValue }
    }

    @State private var sort: SortOrder = .size
    @State private var showAll = false
    @State private var tiles: [AnalyzeTile] = []

    private var cleanableTotal: Int64 { report.entries.filter { $0.cleanable == true }.reduce(0) { $0 + $1.size } }
    private var largestEntry: Int64 { report.entries.map(\.size).max() ?? 0 }

    private var sortedEntries: [AnalyzeReport.Entry] {
        switch sort {
        case .size: report.entries.sorted { $0.size > $1.size }
        case .name: report.entries.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .recent: report.entries.sorted { ($0.lastAccess ?? "") > ($1.lastAccess ?? "") }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            AnalyzeBreadcrumbs(path: report.path, actions: actions)
            stats
            if report.entries.isEmpty {
                GlassCard {
                    EmptyStateView(symbol: "folder", title: "This folder is empty",
                                   message: "Mole found nothing inside it, or macOS didn't let it look.", tint: FeatureTheme.analyze.accent)
                }
            } else {
                treemapCard
                contentsCard
                if let large = report.largeFiles, !large.isEmpty {
                    largestFilesCard(large)
                }
            }
        }
        .onAppear { tiles = AnalyzeTile.build(from: report.entries) }
        .onChange(of: report) { _, new in tiles = AnalyzeTile.build(from: new.entries) }
    }

    // MARK: Summary

    private var stats: some View {
        let folders = report.entries.filter(\.isDir).count
        var parts = [ByteFormat.string(report.totalSize),
                     "\(report.entries.count.formatted()) items (\(folders.formatted()) folders)",
                     "\((report.totalFiles ?? 0).formatted()) files inside"]
        if cleanableTotal > 0 { parts.append("\(ByteFormat.string(cleanableTotal)) rebuildable") }
        return Text(parts.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
    }

    // MARK: Treemap

    private var treemapCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                AnalyzeTreemap(tiles: tiles, total: report.totalSize, selection: analyzer.selection,
                               onSelect: { tile in
                                   // The "+N more" aggregate is not a real item: expand the list instead of selecting it.
                                   if let entry = tile.entry {
                                       actions.select(entry.path)
                                   } else {
                                       withAnimation(.smooth) { showAll = true }
                                   }
                               },
                               onOpen: { tile in
                                   guard let entry = tile.entry else { return }
                                   if tile.isFolder { actions.openFolder(entry.path) } else { actions.openItem(entry.path) }
                               }) { tile in
                    if let entry = tile.entry {
                        AnalyzeItemMenu(path: entry.path, size: entry.size, isDir: entry.isDir && !entry.isSymlink, actions: actions)
                    }
                }
                .frame(height: 430)
                legend
                    .padding(.horizontal, 4)
            }
        }
    }

    private var legend: some View {
        let kinds = Array(Set(tiles.map(\.kind))).sorted { $0.rawValue < $1.rawValue }
        return HStack(spacing: 14) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(kind == .folder ? AnyShapeStyle(FeatureTheme.analyze.gradient)
                              : AnyShapeStyle(AnalyzePalette.color(for: kind, name: "", dark: false)))
                        .frame(width: 12, height: 12)
                    Text(kind == .folder ? "Folders" : kind.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Click a folder to open it · hover for details")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Contents

    private var contentsCard: some View {
        let entries = sortedEntries
        let visible = showAll ? entries : Array(entries.prefix(40))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Contents", symbol: "list.bullet.indent", detail: nil)
                Spacer()
                Picker("Sort by", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            GlassCard(padding: 8) {
                LazyVStack(spacing: 1) {
                    ForEach(visible) { entry in
                        AnalyzeEntryRow(entry: entry, total: report.totalSize, largest: largestEntry,
                                        selected: analyzer.selection == entry.path, actions: actions)
                    }
                    if entries.count > visible.count {
                        Button("Show all \(entries.count.formatted()) items") { withAnimation(.smooth) { showAll = true } }
                            .buttonStyle(.soft)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func largestFilesCard(_ files: [AnalyzeReport.LargeFile]) -> some View {
        let largest = files.map(\.size).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Largest files", symbol: "doc.text.magnifyingglass", detail: "Anywhere inside this folder")
            GlassCard(padding: 8) {
                LazyVStack(spacing: 1) {
                    ForEach(files.sorted { $0.size > $1.size }) { file in
                        AnalyzeLargeFileRow(file: file, root: report.path, largest: largest,
                                            selected: analyzer.selection == file.path, actions: actions)
                    }
                }
            }
        }
    }
}

// MARK: - Rows

private struct AnalyzeEntryRow: View {
    let entry: AnalyzeReport.Entry
    let total: Int64
    let largest: Int64
    let selected: Bool
    let actions: AnalyzeActions
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let kind = AnalyzeKind.of(entry)
        let tint = AnalyzePalette.color(for: kind, name: entry.displayName, dark: scheme == .dark)
        HStack(spacing: 12) {
            Image(nsImage: Finder.icon(for: entry.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if entry.cleanable == true { Pill(text: "Rebuildable", symbol: "arrow.triangle.2.circlepath", tint: .moleGood) }
                    if entry.isSymlink { Pill(text: "Alias", symbol: "arrow.turn.up.right", tint: .secondary) }
                }
                Text(subtitle(kind)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            CapsuleBar(fraction: largest > 0 ? Double(entry.size) / Double(largest) : 0, tint: tint, height: 5)
                .frame(width: 130)
            Text(ByteFormat.string(entry.size))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
            Text(AnalyzeFormat.percent(entry.size, of: total))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
            Group {
                if entry.isDir && !entry.isSymlink {
                    Button("Open Folder", systemImage: "chevron.right") { actions.openFolder(entry.path) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Analyze this folder")
                } else {
                    Color.clear
                }
            }
            .frame(width: 20)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? AnyShapeStyle(FeatureTheme.analyze.accent.opacity(0.18)) : AnyShapeStyle(.primary.opacity(hovering ? 0.05 : 0)))
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(FeatureTheme.analyze.accent.opacity(0.5), lineWidth: 1)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if entry.isDir && !entry.isSymlink { actions.openFolder(entry.path) } else { actions.openItem(entry.path) }
        }
        .simultaneousGesture(TapGesture().onEnded { actions.select(entry.path) })
        .contextMenu { AnalyzeItemMenu(path: entry.path, size: entry.size, isDir: entry.isDir && !entry.isSymlink, actions: actions) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.displayName), \(ByteFormat.string(entry.size))")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func subtitle(_ kind: AnalyzeKind) -> String {
        var parts = [entry.isDir ? (entry.cleanable == true ? "Build or dependency folder" : "Folder") : kind.label]
        if let date = entry.lastAccess.flatMap(AnalyzeFormat.date) {
            parts.append("opened " + date.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

private struct AnalyzeLargeFileRow: View {
    let file: AnalyzeReport.LargeFile
    let root: String
    let largest: Int64
    let selected: Bool
    let actions: AnalyzeActions
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let kind = AnalyzeKind.of(fileName: file.name)
        HStack(spacing: 12) {
            Image(nsImage: Finder.icon(for: file.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(relativeFolder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 12)
            CapsuleBar(fraction: largest > 0 ? Double(file.size) / Double(largest) : 0,
                       tint: AnalyzePalette.color(for: kind, name: file.name, dark: scheme == .dark), height: 5)
                .frame(width: 130)
            Text(ByteFormat.string(file.size))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? AnyShapeStyle(FeatureTheme.analyze.accent.opacity(0.18)) : AnyShapeStyle(.primary.opacity(hovering ? 0.05 : 0)))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { actions.openItem(file.path) }
        .simultaneousGesture(TapGesture().onEnded { actions.select(file.path) })
        .contextMenu { AnalyzeItemMenu(path: file.path, size: file.size, isDir: false, actions: actions) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.name), \(ByteFormat.string(file.size)), in \(relativeFolder)")
    }

    private var relativeFolder: String {
        let folder = (file.path as NSString).deletingLastPathComponent
        if folder == root { return "In this folder" }
        if folder.hasPrefix(root + "/") { return "…/" + folder.dropFirst(root.count + 1) }
        return folder.abbreviatingHome
    }
}

// MARK: - Breadcrumbs

private struct AnalyzeBreadcrumbs: View {
    let path: String
    let actions: AnalyzeActions

    private struct Crumb: Identifiable {
        let path: String
        let title: String
        let symbol: String
        var id: String { path }
    }

    private var crumbs: [Crumb] {
        let home = NSHomeDirectory()
        var result: [Crumb] = []
        var base: String
        var rest: String
        if path == home || path.hasPrefix(home + "/") {
            result.append(Crumb(path: home, title: "Home", symbol: "house.fill"))
            base = home
            rest = String(path.dropFirst(home.count))
        } else if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/")
            base = "/Volumes/" + (parts.count > 1 ? parts[1] : "")
            result.append(Crumb(path: base, title: String(parts.count > 1 ? parts[1] : "Volume"), symbol: "externaldrive.fill"))
            rest = String(path.dropFirst(base.count))
        } else {
            result.append(Crumb(path: "/", title: "Macintosh HD", symbol: "internaldrive.fill"))
            base = ""
            rest = path == "/" ? "" : path
        }
        for part in rest.split(separator: "/") {
            base += "/" + part
            result.append(Crumb(path: base, title: String(part), symbol: "folder.fill"))
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        let isLast = index == crumbs.count - 1
                        Button { if !isLast { actions.openFolder(crumb.path) } } label: {
                            Label(crumb.title, systemImage: crumb.symbol)
                                .font(.callout.weight(isLast ? .semibold : .regular))
                                .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(isLast ? AnyShapeStyle(FeatureTheme.analyze.accent.opacity(0.16)) : AnyShapeStyle(.clear), in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .id(crumb.id)
                        .contextMenu { AnalyzeItemMenu(path: crumb.path, size: 0, isDir: true, actions: actions, allowTrash: false) }
                        .help(crumb.path.abbreviatingHome)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(crumbs.last?.id, anchor: .trailing) }
        }
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }
}
