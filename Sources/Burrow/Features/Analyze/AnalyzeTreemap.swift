import SwiftUI

/// One rectangle in the treemap: an entry, or the aggregate of the many small ones.
struct AnalyzeTile: Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int64
    let kind: AnalyzeKind
    let entry: AnalyzeReport.Entry?
    /// For the aggregate tile.
    var count = 0

    var isFolder: Bool { entry?.isDir == true && entry?.isSymlink == false }

    /// Largest entries get their own tile; the long tail becomes one "smaller items" tile so every
    /// rectangle stays large enough to see and click.
    static func build(from entries: [AnalyzeReport.Entry], maxTiles: Int = 70, minFraction: Double = 0.0025) -> [AnalyzeTile] {
        let sorted = entries.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let total = Double(sorted.reduce(0) { $0 + $1.size })
        guard total > 0 else { return [] }
        var tiles: [AnalyzeTile] = []
        var restSize: Int64 = 0, restCount = 0
        for (i, entry) in sorted.enumerated() {
            let fraction = Double(entry.size) / total
            if tiles.count < maxTiles && (i < 12 || fraction >= minFraction) {
                tiles.append(AnalyzeTile(id: entry.path, name: entry.displayName, size: entry.size, kind: .of(entry), entry: entry))
            } else {
                restSize += entry.size
                restCount += 1
            }
        }
        if restCount == 1, let last = sorted.last {
            tiles.append(AnalyzeTile(id: last.path, name: last.displayName, size: last.size, kind: .of(last), entry: last))
        } else if restCount > 1 {
            tiles.append(AnalyzeTile(id: "__rest__", name: "+\(restCount) more", size: restSize, kind: .group, entry: nil, count: restCount))
        }
        return tiles
    }
}

/// A squarified treemap of one folder's immediate children.
struct AnalyzeTreemap<Menu: View>: View {
    let tiles: [AnalyzeTile]
    let total: Int64
    let selection: String?
    let onSelect: (AnalyzeTile) -> Void
    /// Folders: drill in (single click). Files: open (double click).
    let onOpen: (AnalyzeTile) -> Void
    @ViewBuilder let menu: (AnalyzeTile) -> Menu

    @State private var hovered: String?
    @State private var pointer: CGPoint = .zero
    @State private var tooltipSize: CGSize = CGSize(width: 200, height: 70)
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let rects = Squarify.layout(tiles.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    let rect = rects[index].insetBy(dx: 1.5, dy: 1.5)
                    if rect.width > 1, rect.height > 1 {
                        tileView(tile, rect: rect)
                    }
                }
                if let hovered, let tile = tiles.first(where: { $0.id == hovered }) {
                    let size = geo.size, p = pointer, ts = tooltipSize
                    let x = max(8, min(p.x + 14, size.width - ts.width - 8))
                    let below = p.y + 18
                    let y = below + ts.height > size.height - 6 ? max(6, p.y - ts.height - 12) : below
                    tooltip(for: tile)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                        .offset(x: x, y: y)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onContinuousHover(coordinateSpace: .local) { phase in
                // The hovered tile is worked out from the pointer and the layout, never from per-tile hover
                // tracking, so exactly one tile is highlighted and it is always the one under the pointer.
                guard case .active(let location) = phase else {
                    if hovered != nil { withAnimation(.snappy(duration: 0.16)) { hovered = nil } }
                    return
                }
                pointer = location
                let hit = tile(at: location, in: rects)?.id
                if hit != hovered { withAnimation(.snappy(duration: 0.16)) { hovered = hit } }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: tiles)
        }
    }

    /// The tile whose rectangle contains a point in the treemap's own coordinates.
    private func tile(at point: CGPoint, in rects: [CGRect]) -> AnalyzeTile? {
        rects.indices.first { rects[$0].contains(point) }.map { tiles[$0] }
    }

    @ViewBuilder
    private func tileView(_ tile: AnalyzeTile, rect: CGRect) -> some View {
        let isHovered = hovered == tile.id
        let isSelected = selection == tile.id
        let radius = min(9, min(rect.width, rect.height) / 3.5)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(AnalyzePalette.gradient(for: tile.kind, name: tile.name, dark: scheme == .dark, highlighted: isHovered))
            .overlay {
                if tile.kind == .cleanable { Stripes().clipShape(shape).opacity(0.22) }
            }
            .overlay(alignment: .topLeading) { label(tile, rect: rect) }
            .overlay {
                shape.strokeBorder(.white.opacity(isSelected ? 0.95 : isHovered ? 0.7 : 0.18),
                                   lineWidth: isSelected ? 2.5 : isHovered ? 1.5 : 0.5)
            }
            .frame(width: rect.width, height: rect.height)
            // The hit area, gestures and menu are attached before the tile is moved into place. `offset` moves only
            // what is drawn inside it: a content shape applied after it stays at the stack's top-left
            // corner, which stacked every tile's hit area on top of the first one.
            .contentShape(shape)
            .onTapGesture(count: 2) { if !tile.isFolder { onOpen(tile) } }
            .simultaneousGesture(TapGesture().onEnded {
                if tile.isFolder { onOpen(tile) } else { onSelect(tile) }
            })
            .contextMenu { menu(tile) }
            .accessibilityElement()
            .accessibilityLabel("\(tile.name), \(ByteFormat.string(tile.size)), \(percent(tile)) of this folder")
            .accessibilityHint(tile.isFolder ? "Opens the folder" : tile.entry == nil ? "Lists every item below" : "Selects the item")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if tile.isFolder { onOpen(tile) } else { onSelect(tile) } }
            .offset(x: rect.minX, y: rect.minY)
            .zIndex(isHovered ? 1 : 0)
    }

    @ViewBuilder
    private func label(_ tile: AnalyzeTile, rect: CGRect) -> some View {
        if rect.width > 54 && rect.height > 26 {
            let big = rect.width > 180 && rect.height > 90
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if rect.width > 90 {
                        Image(systemName: tile.kind.symbol).font(.system(size: big ? 12 : 10, weight: .bold))
                    }
                    Text(tile.name)
                        .font(.system(size: big ? 14 : 11.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if rect.height > 46 {
                    Text(ByteFormat.string(tile.size))
                        .font(.system(size: big ? 12.5 : 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .padding(.horizontal, big ? 10 : 6)
            .padding(.vertical, big ? 9 : 5)
            .frame(maxWidth: rect.width, alignment: .leading)
        }
    }

    private func tooltip(for tile: AnalyzeTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: tile.kind.symbol)
                    .foregroundStyle(AnalyzePalette.color(for: tile.kind, name: tile.name, dark: scheme == .dark))
                Text(tile.name).font(.callout.weight(.semibold)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(ByteFormat.string(tile.size)).font(.callout.monospacedDigit())
                Text("·").foregroundStyle(.tertiary)
                Text(percent(tile)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(hint(for: tile)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 280, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func hint(for tile: AnalyzeTile) -> String {
        if tile.kind == .group { return "Listed below in Contents" }
        if tile.kind == .cleanable { return "Rebuildable: safe to remove · click to open" }
        if tile.isFolder { return "Folder · click to open" }
        if let access = tile.entry?.lastAccess.flatMap(AnalyzeFormat.date) {
            return "\(tile.kind.label) · opened \(access.formatted(.relative(presentation: .named)))"
        }
        return tile.kind.label
    }

    private func percent(_ tile: AnalyzeTile) -> String {
        guard total > 0 else { return "—" }
        return (Double(tile.size) / Double(total)).formatted(.percent.precision(.fractionLength(tile.size * 1000 < total ? 2 : 1)))
    }
}

/// Diagonal hatching that marks rebuildable ("cleanable") folders.
private struct Stripes: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 9
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(path, with: .color(.white), lineWidth: 2.5)
        }
        .allowsHitTesting(false)
    }
}

enum AnalyzeFormat {
    static func date(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }

    static func percent(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return "—" }
        let f = Double(part) / Double(total)
        return f.formatted(.percent.precision(.fractionLength(f < 0.001 ? 2 : f < 0.1 ? 1 : 0)))
    }
}
