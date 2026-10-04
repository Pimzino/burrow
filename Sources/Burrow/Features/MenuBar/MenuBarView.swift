import AppKit
import SwiftUI

/// What the menu bar label shows next to the glyph. Stored under `menuBarMetric` ("health" | "cpu" | "none").
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case health, cpu, none
    var id: String { rawValue }
    static let storageKey = "menuBarMetric"
}

struct MenuBarLabel: View {
    let status: StatusMonitor
    @AppStorage(MenuBarMetric.storageKey) private var metric: MenuBarMetric = .health

    var body: some View {
        let snap = status.snapshot
        HStack(spacing: 3) {
            if let mark = Self.brandMark {
                Image(nsImage: mark)
            } else {
                Image(systemName: symbol(for: snap?.healthScore))
            }
            switch metric {
            case .health:
                if let score = snap?.healthScore { Text("\(score)").monospacedDigit() }
            case .cpu:
                if let cpu = snap?.cpu?.usage { Text("\(Int(cpu.rounded()))%").monospacedDigit() }
            case .none:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Burrow")
        .accessibilityValue(snap?.healthScore.map { "Health \($0)" } ?? "Starting")
    }

    /// Burrow's arch mark as a template image (tinted by the menu bar). Missing when running unbundled.
    private static let brandMark: NSImage? = {
        guard let image = Bundle.main.image(forResource: "menubar-template") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    /// Fallback glyph: the gauge needle follows the score so the glyph alone says something.
    private func symbol(for score: Int?) -> String {
        guard let score else { return "gauge.with.dots.needle.bottom.50percent" }
        switch score {
        case 85...: return "gauge.with.dots.needle.100percent"
        case 65..<85: return "gauge.with.dots.needle.67percent"
        case 45..<65: return "gauge.with.dots.needle.50percent"
        default: return "gauge.with.dots.needle.0percent"
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(StatusMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snap = monitor.snapshot {
                header(snap)
                metrics(snap)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(monitor.lastError ?? "Reading your Mac's vitals…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            quickActions
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: Header

    private func header(_ snap: StatusSnapshot) -> some View {
        let score = snap.healthScore ?? 0
        let message = StatusHealthMessage(snap.healthScoreMsg)
        return HStack(spacing: 14) {
            RingGauge(value: Double(score) / 100, colors: [Color.health(score).opacity(0.6), Color.health(score)], lineWidth: 7) {
                Text("\(score)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(score)))
                    .foregroundStyle(Color.health(score))
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.band.isEmpty ? "Health" : message.band)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                if message.issues.isEmpty {
                    Text(StatusHealthMessage.blurb(for: score)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(message.issues.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Color.moleWarn)
                        .lineLimit(2)
                }
                Text([monitor.hardware?.model, monitor.hardware?.cpuModel, snap.uptime.map { "up \($0)" }]
                        .compactMap { $0.statusNonEmpty }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Metrics

    private func metrics(_ snap: StatusSnapshot) -> some View {
        let cpu = snap.cpu?.usage ?? 0
        let mem = snap.memory?.usedPercent ?? 0
        let disk = (snap.disks ?? monitor.enriched?.disks)?.first
        let rx = (snap.network ?? []).reduce(0) { $0 + ($1.rxRateMbs ?? 0) }
        let tx = (snap.network ?? []).reduce(0) { $0 + ($1.txRateMbs ?? 0) }
        return VStack(spacing: 11) {
            MenuMetricRow(symbol: "cpu", title: "CPU", value: StatusFormat.percent(cpu), fraction: cpu / 100,
                          tint: Color.usage(cpu) == .moleGood ? FeatureTheme.dashboard.accent : Color.usage(cpu))
            MenuMetricRow(symbol: "memorychip", title: "Memory",
                          value: "\(StatusFormat.memory(snap.memory?.used)) · \(StatusFormat.percent(mem))",
                          fraction: mem / 100, tint: Color.usage(mem) == .moleGood ? .pink : Color.usage(mem))
            if let disk {
                MenuMetricRow(symbol: "internaldrive", title: "Disk", value: "\(StatusFormat.bytes(disk.free)) free",
                              fraction: disk.fraction, tint: Color.usage(disk.fraction * 100) == .moleGood ? .indigo : Color.usage(disk.fraction * 100))
            }
            HStack(spacing: 10) {
                StatusIconBadge(symbol: "network", tint: .cyan, size: 24)
                Text("Network").font(.callout)
                Spacer()
                Label(StatusFormat.rate(rx), systemImage: "arrow.down").foregroundStyle(Color.cyan)
                Label(StatusFormat.rate(tx), systemImage: "arrow.up").foregroundStyle(Color.pink)
            }
            .font(.caption.monospacedDigit())
            .labelStyle(StatusTightLabelStyle())
            .contentTransition(.numericText())
            if let battery = monitor.batteries?.first, let pct = battery.percent {
                MenuMetricRow(symbol: StatusFormat.batterySymbol(percent: pct, status: battery.status), title: "Battery",
                              value: "\(Int(pct))% · \(StatusFormat.batteryStatus(battery.status))",
                              fraction: pct / 100, tint: pct <= 20 ? .moleBad : .moleGood)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: Actions

    private var quickActions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                quickAction(.clean)
                quickAction(.uninstall)
                quickAction(.analyze)
                quickAction(.optimize)
            }
        }
    }

    private func quickAction(_ route: Route) -> some View {
        Button {
            open(route)
        } label: {
            VStack(spacing: 6) {
                FeatureIcon(theme: route.theme, size: 32)
                Text(route.theme.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .help("Open \(route.theme.title)")
        .accessibilityLabel("Open \(route.theme.title)")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                open(nil)
            } label: {
                Label("Open Burrow", systemImage: "macwindow")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.hero(.dashboard))
            .controlSize(.small)
            .keyboardShortcut("o", modifiers: .command)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.soft)
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.soft)
            .help("Quit Burrow")
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func open(_ route: Route?) {
        if let route { model.route = route }
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct MenuMetricRow: View {
    let symbol: String
    let title: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                StatusIconBadge(symbol: symbol, tint: tint, size: 24)
                Text(title).font(.callout)
                Spacer()
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            CapsuleBar(fraction: fraction, tint: tint, height: 4)
                .padding(.leading, 34)
        }
        .accessibilityElement(children: .combine)
    }
}
