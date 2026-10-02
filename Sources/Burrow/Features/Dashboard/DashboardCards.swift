import AppKit
import SwiftUI

// MARK: - Shared pieces

struct StatusCardHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            StatusIconBadge(symbol: symbol, tint: tint, size: 28)
            Text(title).font(.headline)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension StatusCardHeader where Trailing == EmptyView {
    init(title: String, symbol: String, tint: Color) {
        self.init(title: title, symbol: symbol, tint: tint) { EmptyView() }
    }
}

/// Subtle lift on hover for interactive-feeling cards.
struct StatusHoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.012 : 1)
            .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 14, y: 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func statusHoverLift() -> some View { modifier(StatusHoverLift()) }
}

// MARK: - Hero

struct StatusHealthHero: View {
    let snapshot: StatusSnapshot
    let hardware: StatusSnapshot.Hardware?

    var body: some View {
        let score = snapshot.healthScore ?? 0
        let message = StatusHealthMessage(snapshot.healthScoreMsg)
        GlassCard(padding: 26, tint: Color.health(score)) {
            HStack(alignment: .center, spacing: 30) {
                RingGauge(value: Double(score) / 100, colors: [Color.health(score).opacity(0.65), Color.health(score)], lineWidth: 16) {
                    VStack(spacing: 0) {
                        Text("\(score)")
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(score)))
                            .foregroundStyle(Color.health(score))
                        Text("HEALTH")
                            .font(.caption2.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 164, height: 164)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Health score")
                .accessibilityValue("\(score) out of 100, \(message.band)")

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.band.isEmpty ? "Checking…" : message.band)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .contentTransition(.opacity)
                        Text(StatusHealthMessage.blurb(for: score))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    if message.issues.isEmpty {
                        Label("No issues detected", systemImage: "checkmark.seal.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.moleGood)
                    } else {
                        StatusFlowLayout(spacing: 6) {
                            ForEach(message.issues, id: \.self) { issue in
                                Pill(text: issue, symbol: StatusHealthMessage.symbol(for: issue), tint: .moleWarn)
                            }
                        }
                    }
                    Divider().opacity(0.5)
                    hardwareGrid
                }
            }
        }
    }

    private var hardwareGrid: some View {
        let hw = hardware
        let items: [(String, String, String)] = [
            ("laptopcomputer", "Model", hw?.model.statusNonEmpty ?? "—"),
            ("cpu", "Chip", hw?.cpuModel.statusNonEmpty ?? "—"),
            ("memorychip", "Memory", hw?.totalRam.statusNonEmpty ?? "—"),
            ("internaldrive", "Disk", hw?.diskSize.statusNonEmpty ?? "—"),
            ("apple.logo", "System", hw?.osVersion.statusNonEmpty ?? snapshot.platform ?? "—"),
            ("clock", "Uptime", snapshot.uptime ?? "—"),
            ("display", "Display", hw?.refreshRate.statusNonEmpty ?? "—"),
            ("square.stack.3d.up", "Processes", snapshot.procs.map { "\($0)" } ?? "—"),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            ForEach(0..<(items.count / 2), id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { col in
                        let item = items[row * 2 + col]
                        HStack(spacing: 8) {
                            Image(systemName: item.0)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(FeatureTheme.dashboard.accent)
                                .frame(width: 18)
                            Text(item.1).foregroundStyle(.secondary)
                            Text(item.2)
                                .fontWeight(.medium)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

extension Optional where Wrapped == String {
    var statusNonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}

// MARK: - Metric tile with sparkline

struct StatusMetricTile: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let tint: Color
    var fraction: Double? = nil
    var spark: [(Date, Double)] = []
    var sparkDomain: ClosedRange<Double>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusIconBadge(symbol: symbol, tint: tint)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if spark.count > 1 {
                StatusSparkline(values: spark, tint: tint, domain: sparkDomain)
                    .frame(height: 30)
            } else if let fraction {
                CapsuleBar(fraction: fraction, tint: tint)
                    .padding(.vertical, 12)
            } else {
                Spacer().frame(height: 30)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.tileRadius))
        .statusHoverLift()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - CPU

struct StatusCPUCard: View {
    let cpu: StatusSnapshot.CPU
    let tint: Color

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                StatusCardHeader(title: "Processor", symbol: "cpu", tint: tint) {
                    Text(StatusFormat.percent(cpu.usage, digits: 1))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                HStack(spacing: 10) {
                    loadBox("1 min", cpu.load1)
                    loadBox("5 min", cpu.load5)
                    loadBox("15 min", cpu.load15)
                }
                if let cores = cpu.perCore, !cores.isEmpty {
                    coreBars(cores)
                }
                HStack(spacing: 8) {
                    if let p = cpu.pCoreCount, p > 0 { Pill(text: "\(p) Performance", symbol: "hare.fill", tint: tint) }
                    if let e = cpu.eCoreCount, e > 0 { Pill(text: "\(e) Efficiency", symbol: "leaf.fill", tint: .teal) }
                    if (cpu.pCoreCount ?? 0) == 0, let n = cpu.logicalCpu ?? cpu.coreCount {
                        Pill(text: "\(n) cores", symbol: "square.grid.3x3", tint: tint)
                    }
                    Spacer()
                    if cpu.perCoreEstimated == true {
                        Text("Per-core estimated").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func loadBox(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(StatusFormat.load(value))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("Load \(title)").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    /// Apple Silicon lists efficiency cores first.
    private func coreBars(_ cores: [Double]) -> some View {
        let eCount = cpu.eCoreCount ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                    let isE = index < eCount
                    let color: Color = isE ? .teal : tint
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary.opacity(0.6))
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .bottom, endPoint: .top))
                                    .frame(height: max(3, geo.size.height * min(1, value / 100)))
                            }
                        }
                        .frame(height: 54)
                        Text(isE ? "E" : (eCount > 0 ? "P" : "\(index + 1)"))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(String(format: "Core %d: %.0f%%", index + 1, value))
                    .accessibilityElement()
                    .accessibilityLabel("Core \(index + 1)\(isE ? ", efficiency" : "")")
                    .accessibilityValue(String(format: "%.0f percent", value))
                }
            }
            .animation(.smooth(duration: 0.5), value: cores)
        }
    }
}

// MARK: - Memory

struct StatusMemoryCard: View {
    let memory: StatusSnapshot.Memory
    let pressure: StatusMemoryPressure
    let tint: Color

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                StatusCardHeader(title: "Memory", symbol: "memorychip", tint: tint) {
                    Pill(text: "Pressure \(pressure.title)", symbol: "gauge.with.needle", tint: pressure.color)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(StatusFormat.memory(memory.used))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(StatusFormat.memory(memory.total))").foregroundStyle(.secondary)
                    Spacer()
                    Text(StatusFormat.percent(memory.usedPercent))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.usage(memory.usedPercent ?? 0))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                CapsuleBar(fraction: (memory.usedPercent ?? 0) / 100, tint: tint, height: 10)
                VStack(spacing: 8) {
                    StatusDetailRow(label: "Available", value: StatusFormat.memory(memory.available), symbol: "checkmark.circle")
                    StatusDetailRow(label: "Cached files", value: (memory.cached ?? 0) > 0 ? StatusFormat.memory(memory.cached) : "—", symbol: "doc.on.doc")
                    swapRow
                }
            }
        }
    }

    private var swapRow: some View {
        let used = memory.swapUsed ?? 0, total = memory.swapTotal ?? 0
        return VStack(spacing: 6) {
            StatusDetailRow(label: "Swap", value: total > 0 ? "\(StatusFormat.memory(used)) of \(StatusFormat.memory(total))" : "Not in use",
                      symbol: "arrow.left.arrow.right")
            if total > 0 {
                CapsuleBar(fraction: Double(used) / Double(total), tint: .orange, height: 4)
                    .padding(.leading, 24)
            }
        }
    }
}

// MARK: - Disks

struct StatusDisksCard: View {
    let disks: [StatusSnapshot.Disk]
    let io: StatusSnapshot.DiskIO?
    let tint: Color

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                StatusCardHeader(title: "Storage", symbol: "internaldrive", tint: tint) {
                    if let io {
                        HStack(spacing: 10) {
                            Label(StatusFormat.rate(io.readRate ?? 0), systemImage: "arrow.down.doc")
                            Label(StatusFormat.rate(io.writeRate ?? 0), systemImage: "arrow.up.doc")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .help("Disk read / write")
                    }
                }
                if disks.isEmpty {
                    Text("No volumes reported.").foregroundStyle(.secondary)
                }
                ForEach(disks) { disk in
                    StatusDiskRow(disk: disk, tint: tint)
                }
            }
        }
    }
}

struct StatusDiskRow: View {
    let disk: StatusSnapshot.Disk
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: Finder.icon(for: disk.mount))
                    .resizable()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(disk.displayName).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text("\(StatusFormat.bytes(disk.used)) used of \(StatusFormat.bytes(disk.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    HStack(spacing: 6) {
                        if disk.external == true { Pill(text: "External", symbol: "externaldrive", tint: .indigo).fixedSize() }
                        if let smart = disk.smartTitle {
                            Pill(text: smart, symbol: smart.contains("failing") ? "exclamationmark.triangle.fill" : "checkmark.shield",
                                 tint: smart.contains("failing") ? .moleBad : .moleGood)
                                .fixedSize()
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(StatusFormat.bytes(disk.free))
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("free").font(.caption2).foregroundStyle(.secondary)
                }
            }
            CapsuleBar(fraction: disk.fraction, tint: Color.usage(disk.fraction * 100) == .moleGood ? tint : Color.usage(disk.fraction * 100), height: 8)
            if let purgeable = disk.purgeable, purgeable > 0 {
                Label("\(ByteFormat.string(purgeable)) purgeable by macOS", systemImage: "leaf.arrow.triangle.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(disk.mount) }
            Button("Copy Path", systemImage: "doc.on.doc") { StatusClipboard.copy(disk.mount) }
            if let device = disk.device {
                Button("Copy Device (\(device))", systemImage: "doc.on.doc") { StatusClipboard.copy(device) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum StatusClipboard {
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Network

struct StatusNetworkCard: View {
    let interfaces: [StatusSnapshot.NetworkInterface]
    let proxy: StatusSnapshot.Proxy?
    let tint: Color

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                StatusCardHeader(title: "Network", symbol: "network", tint: tint)
                ForEach(interfaces) { iface in
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: iface))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(active(iface) ? tint : .secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(iface.name).font(.callout.weight(.semibold).monospaced())
                            Text((iface.ip ?? "").isEmpty ? "No address" : iface.ip!)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Label(StatusFormat.rate(iface.rxRateMbs ?? 0), systemImage: "arrow.down")
                                .foregroundStyle(Color.cyan)
                            Label(StatusFormat.rate(iface.txRateMbs ?? 0), systemImage: "arrow.up")
                                .foregroundStyle(Color.pink)
                        }
                        .font(.caption.monospacedDigit())
                        .labelStyle(StatusTightLabelStyle())
                        .contentTransition(.numericText())
                    }
                    .opacity(active(iface) ? 1 : 0.6)
                    .contextMenu {
                        if let ip = iface.ip, !ip.isEmpty {
                            Button("Copy IP Address", systemImage: "doc.on.doc") { StatusClipboard.copy(ip) }
                        }
                        Button("Copy Interface Name", systemImage: "doc.on.doc") { StatusClipboard.copy(iface.name) }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let note = StatusFormat.proxyNote(proxy) {
                    Label(note, systemImage: proxy?.type == "TUN" ? "lock.shield" : "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func active(_ iface: StatusSnapshot.NetworkInterface) -> Bool {
        !(iface.ip ?? "").isEmpty || (iface.rxRateMbs ?? 0) + (iface.txRateMbs ?? 0) > 0
    }

    private func symbol(for iface: StatusSnapshot.NetworkInterface) -> String {
        if iface.name == "en0" { return "wifi" }
        if iface.name.hasPrefix("utun") { return "lock.shield" }
        if iface.name.hasPrefix("bridge") { return "point.3.connected.trianglepath.dotted" }
        return "cable.connector"
    }
}

struct StatusTightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.caption2.weight(.bold))
            configuration.title
        }
    }
}

// MARK: - Battery

struct StatusBatteryCard: View {
    let battery: StatusSnapshot.Battery
    let thermal: StatusSnapshot.Thermal?

    var body: some View {
        let percent = battery.percent ?? 0
        let tint: Color = percent <= 15 ? .moleBad : percent <= 30 ? .moleWarn : .moleGood
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                StatusCardHeader(title: "Battery", symbol: StatusFormat.batterySymbol(percent: percent, status: battery.status), tint: tint) {
                    if (battery.status ?? "").lowercased() == "charging" {
                        Image(systemName: "bolt.fill").foregroundStyle(.yellow).symbolEffect(.pulse)
                    }
                }
                HStack(spacing: 20) {
                    RingGauge(value: percent / 100, colors: [tint.opacity(0.6), tint], lineWidth: 10) {
                        Text("\(Int(percent))%")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: percent))
                    }
                    .frame(width: 96, height: 96)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Battery")
                    .accessibilityValue("\(Int(percent)) percent")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(StatusFormat.batteryStatus(battery.status)).font(.title3.weight(.semibold))
                        if let left = battery.timeLeft, !left.isEmpty, left != "0:00" {
                            Text("\(left) remaining").font(.callout).foregroundStyle(.secondary)
                        }
                        if let health = battery.health, !health.isEmpty {
                            Label("Condition \(health)", systemImage: "heart.fill")
                                .font(.callout)
                                .foregroundStyle(health.lowercased() == "good" || health.lowercased() == "normal" ? Color.moleGood : Color.moleWarn)
                        }
                    }
                }
                VStack(spacing: 8) {
                    if let cycles = battery.cycleCount { StatusDetailRow(label: "Cycle count", value: "\(cycles)", symbol: "arrow.triangle.2.circlepath") }
                    if let capacity = battery.capacity { StatusDetailRow(label: "Maximum capacity", value: "\(capacity)%", symbol: "battery.100percent") }
                    if let temp = StatusFormat.celsius(thermal?.batteryTemp) { StatusDetailRow(label: "Temperature", value: temp, symbol: "thermometer.medium") }
                    if let draw = StatusFormat.watts(thermal?.batteryPower) { StatusDetailRow(label: "Battery draw", value: draw, symbol: "bolt") }
                }
            }
        }
    }
}

// MARK: - Power & thermal

struct StatusPowerCard: View {
    let thermal: StatusSnapshot.Thermal
    let tint: Color

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                StatusCardHeader(title: "Power & Thermal", symbol: "bolt.heart", tint: tint)
                HStack(spacing: 10) {
                    bigStat(StatusFormat.watts(thermal.systemPower) ?? "—", "System power", "powerplug")
                    bigStat(StatusFormat.watts(thermal.adapterPower) ?? "—", "Adapter", "powercord")
                }
                VStack(spacing: 8) {
                    StatusDetailRow(label: "CPU temperature", value: StatusFormat.celsius(thermal.cpuTemp) ?? "Not reported", symbol: "thermometer.medium")
                    StatusDetailRow(label: "GPU temperature", value: StatusFormat.celsius(thermal.gpuTemp) ?? "Not reported", symbol: "thermometer.medium")
                    if let fans = thermal.fanCount, fans > 0 {
                        StatusDetailRow(label: fans == 1 ? "Fan" : "Fans (\(fans))", value: "\(thermal.fanSpeed ?? 0) rpm", symbol: "fan")
                    } else {
                        StatusDetailRow(label: "Fans", value: "Fanless or idle", symbol: "fan")
                    }
                }
            }
        }
    }

    private func bigStat(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint).font(.callout)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - GPU

struct StatusGPUCard: View {
    let gpus: [StatusSnapshot.GPU]
    let tint: Color

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                StatusCardHeader(title: "Graphics", symbol: "cube.transparent", tint: tint)
                ForEach(Array(gpus.enumerated()), id: \.offset) { _, gpu in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(gpu.name ?? "GPU").font(.callout.weight(.semibold))
                            Spacer()
                            if let cores = gpu.coreCount, cores > 0 { Pill(text: "\(cores) cores", symbol: "square.grid.3x3.fill", tint: tint) }
                        }
                        if gpu.usageAvailable {
                            HStack {
                                CapsuleBar(fraction: (gpu.usage ?? 0) / 100, tint: tint, height: 8)
                                Text(StatusFormat.percent(gpu.usage)).font(.caption.monospacedDigit())
                            }
                        } else {
                            Text("Utilisation needs administrator sampling, so it isn't shown.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Bluetooth

struct StatusBluetoothCard: View {
    let devices: [StatusSnapshot.Bluetooth]
    let tint: Color

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                StatusCardHeader(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", tint: tint) {
                    Text("\(devices.filter { $0.connected == true }.count) connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(devices.sorted { ($0.connected == true ? 0 : 1) < ($1.connected == true ? 0 : 1) }) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.symbol)
                            .frame(width: 22)
                            .foregroundStyle(device.connected == true ? tint : .secondary)
                        Text(device.name.trimmingCharacters(in: .whitespaces)).lineLimit(1)
                        Spacer()
                        if let pct = device.batteryPercent {
                            HStack(spacing: 4) {
                                Image(systemName: StatusFormat.batterySymbol(percent: pct, status: nil))
                                Text("\(Int(pct))%").monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(pct <= 20 ? Color.moleBad : .secondary)
                        }
                        Circle()
                            .fill(device.connected == true ? Color.moleGood : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                            .accessibilityLabel(device.connected == true ? "Connected" : "Not connected")
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Trash

struct StatusTrashCard: View {
    let size: UInt64?
    let approximate: Bool
    let fullDiskAccess: Bool
    let action: () -> Void

    var body: some View {
        GlassCard(tint: FeatureTheme.clean.accent) {
            HStack(spacing: 14) {
                Image(systemName: (size ?? 0) > 0 ? "trash.fill" : "trash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(FeatureTheme.clean.gradient, in: .rect(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trash").font(.headline)
                    if !fullDiskAccess && (size ?? 0) == 0 {
                        Text("Size needs Full Disk Access").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text((approximate ? "About " : "") + StatusFormat.bytes(size))
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                Spacer()
                Button("Clean Up…", systemImage: "sparkles", action: action)
                    .buttonStyle(.hero(.clean))
                    .fixedSize()
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .help("Open Clean (⇧⌘K)")
            }
        }
    }
}

// MARK: - Processes

struct StatusProcessesCard: View {
    let snapshot: StatusSnapshot
    let tint: Color

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                StatusCardHeader(title: "Top Processes", symbol: "list.bullet.rectangle", tint: tint) {
                    if snapshot.processStale == true {
                        Pill(text: "Updating", symbol: "clock", tint: .secondary)
                    }
                    if let zombies = snapshot.zombieCount, zombies > 0 {
                        Pill(text: "\(zombies) zombie\(zombies == 1 ? "" : "s")", symbol: "moon.zzz", tint: .purple)
                            .help(zombieHelp)
                    }
                }
                if let alerts = snapshot.processAlerts, !alerts.isEmpty {
                    ForEach(alerts) { alert in
                        HStack(spacing: 10) {
                            Image(systemName: "flame.fill").foregroundStyle(Color.moleBad).symbolEffect(.pulse)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(alert.name ?? "pid \(alert.pid)") is using \(StatusFormat.percent(alert.cpu, digits: 0)) CPU")
                                    .font(.callout.weight(.semibold))
                                Text("Above \(Int(alert.threshold ?? 100))% for \(alert.window ?? "a while") · PID \(alert.pid)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Copy PID") { StatusClipboard.copy("\(alert.pid)") }.buttonStyle(.glass).controlSize(.small)
                        }
                        .padding(12)
                        .glassEffect(.regular.tint(Color.moleBad.opacity(0.14)), in: .rect(cornerRadius: 14))
                    }
                }
                if let processes = snapshot.topProcesses, !processes.isEmpty {
                    table(processes)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Sampling processes…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }
                if let parents = snapshot.zombieParents, !parents.isEmpty {
                    Label("Zombie processes are held by \(parents.map { "\($0.name ?? "pid \($0.pid)") (\($0.count ?? 1))" }.joined(separator: ", ")). Quitting the parent app clears them.",
                          systemImage: "moon.zzz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var zombieHelp: String {
        "Finished processes whose parent has not collected them. They use no CPU or memory."
    }

    private func table(_ processes: [StatusSnapshot.Process]) -> some View {
        let maxCPU = max(100, processes.compactMap(\.cpu).max() ?? 100)
        return VStack(spacing: 0) {
            HStack {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 170, alignment: .leading)
                Text("Memory").frame(width: 90, alignment: .trailing)
                Text("PID").frame(width: 64, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            ForEach(Array(processes.enumerated()), id: \.element.pid) { index, p in
                StatusProcessRow(process: p, maxCPU: maxCPU, tint: tint, alerted: snapshot.processAlerts?.contains { $0.pid == p.pid } == true)
                    .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear, in: .rect(cornerRadius: 8))
            }
        }
        .animation(.smooth, value: processes.map(\.pid))
    }
}

struct StatusProcessRow: View {
    let process: StatusSnapshot.Process
    let maxCPU: Double
    let tint: Color
    let alerted: Bool
    @State private var hovering = false

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Group {
                    if alerted {
                        Image(systemName: "flame.fill").foregroundStyle(Color.moleBad)
                    } else if let icon = NSRunningApplication(processIdentifier: pid_t(process.pid))?.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "gearshape.2").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                Text(process.displayName).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                CapsuleBar(fraction: (process.cpu ?? 0) / maxCPU, tint: (process.cpu ?? 0) >= 100 ? .moleWarn : tint, height: 5)
                Text(StatusFormat.percent(process.cpu, digits: 1))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .frame(width: 170)
            Text(process.memoryBytes.map { StatusFormat.memory($0) } ?? StatusFormat.percent(process.memory, digits: 1))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Text("\(process.pid)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? tint.opacity(0.10) : .clear, in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Name", systemImage: "doc.on.doc") { StatusClipboard.copy(process.displayName) }
            Button("Copy PID", systemImage: "number") { StatusClipboard.copy("\(process.pid)") }
            Button("Open Activity Monitor", systemImage: "waveform.path.ecg") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Flow layout

/// Wraps children onto multiple lines.
struct StatusFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
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
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
