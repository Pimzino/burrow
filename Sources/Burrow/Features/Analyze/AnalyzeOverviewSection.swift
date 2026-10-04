import Charts
import SwiftUI

/// The machine-wide overview: where space goes, hidden-space insights, and places to explore.
struct AnalyzeOverviewSection: View {
    let report: AnalyzeReport
    let actions: AnalyzeActions
    @Environment(StatusMonitor.self) private var status

    private static let fixedNames = ["Home", "User Library", "Applications", "System Library"]

    private var locations: [AnalyzeReport.Entry] {
        Self.fixedNames.compactMap { name in report.entries.first { $0.name == name && $0.insight != true } }
    }

    private var insights: [AnalyzeReport.Entry] {
        report.entries.filter { $0.insight == true }.sorted { $0.size > $1.size }
    }

    /// The four fixed rows don't overlap (Home excludes ~/Library), unlike the report's `total_size`.
    private var locationsTotal: Int64 { locations.reduce(0) { $0 + max(0, $1.size) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing + 6) {
            hero
            locationGrid
            if !insights.isEmpty { insightsCard }
            AnalyzePlacesSection(actions: actions)
        }
    }

    // MARK: Hero

    private var hero: some View {
        GlassCard(padding: 24) {
            HStack(alignment: .center, spacing: 32) {
                donut.frame(width: 220, height: 220)
                heroDetails
            }
        }
    }

    private var donut: some View {
        Chart(locations) { entry in
            SectorMark(angle: .value("Size", max(0, entry.size)), innerRadius: .ratio(0.64), angularInset: 1.8)
                .cornerRadius(6)
                .foregroundStyle(AnalyzeLocationStyle.forName(entry.name).color.gradient)
                .accessibilityLabel(entry.name)
                .accessibilityValue(ByteFormat.string(entry.size))
        }
        .chartLegend(.hidden)
        .chartBackground { _ in
            VStack(spacing: 2) {
                Text(ByteFormat.string(locationsTotal))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 130)
                    .contentTransition(.numericText())
                Text("in 4 locations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.smooth(duration: 0.6), value: locationsTotal)
    }

    private var heroDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where your space goes")
                    .font(.title2.weight(.bold))
                Text("Sizes are measured by Mole and cached for a week. Hidden-space insights overlap these totals.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                ForEach(locations) { entry in
                    let style = AnalyzeLocationStyle.forName(entry.name)
                    HStack(spacing: 10) {
                        Circle().fill(style.color.gradient).frame(width: 10, height: 10)
                        Text(entry.name).font(.callout.weight(.medium))
                        Spacer(minLength: 12)
                        Text(ByteFormat.string(entry.size))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                        Text(AnalyzeFormat.percent(max(0, entry.size), of: locationsTotal))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let disk = status.snapshot?.disks?.first(where: { $0.mount == "/" }), let used = disk.used, let total = disk.total, total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Startup disk", systemImage: "internaldrive.fill").font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(ByteFormat.string(used)) of \(ByteFormat.string(total)) used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    CapsuleBar(fraction: Double(used) / Double(total), tint: .usage(Double(used) / Double(total) * 100), height: 7)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Locations

    private var locationGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 14) {
            ForEach(locations) { entry in
                AnalyzeLocationCard(entry: entry, share: locationsTotal > 0 ? Double(max(0, entry.size)) / Double(locationsTotal) : 0,
                                    actions: actions)
            }
        }
    }

    // MARK: Insights

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Hidden space", symbol: "lightbulb.max.fill",
                         detail: ByteFormat.string(insights.reduce(0) { $0 + max(0, $1.size) }))
            GlassCard(padding: 8) {
                VStack(spacing: 2) {
                    ForEach(insights) { entry in
                        AnalyzeInsightRow(entry: entry, largest: insights.first?.size ?? 1, actions: actions)
                        if entry.id != insights.last?.id {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
            }
        }
    }
}

private struct AnalyzeLocationCard: View {
    let entry: AnalyzeReport.Entry
    let share: Double
    let actions: AnalyzeActions
    @State private var hovering = false

    var body: some View {
        let style = AnalyzeLocationStyle.forName(entry.name)
        Button { actions.openFolder(entry.path) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: style.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(style.color.gradient, in: .rect(cornerRadius: 11, style: .continuous))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0.4)
                        .offset(x: hovering ? 2 : 0, y: hovering ? -2 : 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                    Text(entry.size < 0 ? "Couldn't measure" : ByteFormat.string(entry.size))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                CapsuleBar(fraction: share, tint: style.color)
                Text(style.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: Metrics.tileRadius))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(style.color.opacity(hovering ? 0.14 : 0.05)).interactive(), in: .rect(cornerRadius: Metrics.tileRadius))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu { AnalyzeItemMenu(path: entry.path, size: entry.size, isDir: true, actions: actions, allowTrash: false) }
        .help("Analyze \(entry.path.abbreviatingHome)")
        .accessibilityLabel("\(entry.name), \(ByteFormat.string(entry.size))")
        .accessibilityHint("Opens the folder in the analyzer")
    }
}

private struct AnalyzeInsightRow: View {
    let entry: AnalyzeReport.Entry
    let largest: Int64
    let actions: AnalyzeActions
    @State private var hovering = false

    var body: some View {
        let insight = AnalyzeInsight.forName(entry.name)
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: insight.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(insight.tint)
                .frame(width: 36, height: 36)
                .background(insight.tint.opacity(0.14), in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.name).font(.callout.weight(.semibold))
                    if insight.cleanable {
                        Pill(text: "Clean can help", tint: .moleGood)
                    }
                }
                Text(insight.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Text(entry.size < 0 ? "—" : ByteFormat.string(entry.size))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                CapsuleBar(fraction: largest > 0 ? Double(max(0, entry.size)) / Double(largest) : 0, tint: insight.tint, height: 4)
                    .frame(width: 90)
            }
            HStack(spacing: 6) {
                Button("Explore", systemImage: "magnifyingglass") { actions.openFolder(entry.path) }
                    .labelStyle(.iconOnly)
                    .help("Analyze \(entry.path.abbreviatingHome)")
                if insight.cleanable {
                    Button("Clean", systemImage: "sparkles") { actions.clean() }
                        .help("Go to Clean")
                }
            }
            .buttonStyle(.soft)
            .frame(width: 128, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu { AnalyzeItemMenu(path: entry.path, size: entry.size, isDir: true, actions: actions, allowTrash: false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name), \(ByteFormat.string(entry.size))")
    }
}

/// Quick picks, external volumes and the folder chooser.
private struct AnalyzePlacesSection: View {
    let actions: AnalyzeActions
    @State private var volumes: [AnalyzeVolume] = []

    private let picks: [(String, String, String)] = [
        ("Home", "house", "~"),
        ("Desktop", "menubar.dock.rectangle", "~/Desktop"),
        ("Documents", "doc.on.doc", "~/Documents"),
        ("Downloads", "arrow.down.circle", "~/Downloads"),
        ("Developer", "hammer", "~/Library/Developer"),
        ("Caches", "internaldrive", "~/Library/Caches"),
        ("Movies", "film", "~/Movies"),
        ("Pictures", "photo", "~/Pictures"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Explore", symbol: "safari")
            GlassCard(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    FlowChips(picks: picks.filter { FileManager.default.fileExists(atPath: $0.2.expandingTilde) }, actions: actions)
                    if !volumes.isEmpty {
                        Divider()
                        Text("External volumes").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                            ForEach(volumes) { volume in
                                AnalyzeVolumeCard(volume: volume, actions: actions)
                            }
                        }
                    }
                }
            }
        }
        .task { volumes = AnalyzeVolume.external() }
    }
}

private struct FlowChips: View {
    let picks: [(String, String, String)]
    let actions: AnalyzeActions

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(picks, id: \.2) { pick in
                Button { actions.openFolder(pick.2.expandingTilde) } label: {
                    Label(pick.0, systemImage: pick.1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.soft)
                .contextMenu { AnalyzeItemMenu(path: pick.2.expandingTilde, size: 0, isDir: true, actions: actions, allowTrash: false) }
                .help(pick.2)
            }
        }
    }
}

struct AnalyzeVolume: Identifiable, Hashable {
    let path: String
    let name: String
    let total: Int64
    let available: Int64
    let removable: Bool
    var id: String { path }

    static func external() -> [AnalyzeVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeIsRootFileSystemKey, .volumeIsRemovableKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false,
                  url.path.hasPrefix("/Volumes/") else { return nil }
            return AnalyzeVolume(path: url.path, name: values.volumeName ?? url.lastPathComponent,
                                 total: Int64(values.volumeTotalCapacity ?? 0), available: Int64(values.volumeAvailableCapacity ?? 0),
                                 removable: values.volumeIsRemovable ?? false)
        }
    }
}

private struct AnalyzeVolumeCard: View {
    let volume: AnalyzeVolume
    let actions: AnalyzeActions
    @State private var hovering = false

    var body: some View {
        let used = max(0, volume.total - volume.available)
        let fraction = volume.total > 0 ? Double(used) / Double(volume.total) : 0
        Button { actions.openFolder(volume.path) } label: {
            HStack(spacing: 12) {
                Image(nsImage: Finder.icon(for: volume.path))
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(volume.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text("\(ByteFormat.string(volume.available)) free")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    CapsuleBar(fraction: fraction, tint: .usage(fraction * 100), height: 5)
                    Text("\(ByteFormat.string(used)) of \(ByteFormat.string(volume.total)) used")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(hovering ? 0.07 : 0.035)))
        .onHover { hovering = $0 }
        .contextMenu { AnalyzeItemMenu(path: volume.path, size: used, isDir: true, actions: actions, allowTrash: false) }
        .help("Analyze \(volume.name)")
    }
}
