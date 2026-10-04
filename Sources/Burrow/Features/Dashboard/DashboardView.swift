import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(StatusMonitor.self) private var monitor
    @State private var pressure: StatusMemoryPressure = .unknown
    @State private var recorded = false

    private let theme = FeatureTheme.dashboard

    var body: some View {
        FeaturePage(theme: theme) {
            PageHeader(theme: theme, subtitle: subtitle) {
                headerTrailing
            }
        } content: {
            if let snapshot = monitor.snapshot {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: Metrics.spacing) {
                        content(snapshot)
                    }
                    .task {
                        // E2E screenshots: `-MoleE2EScrollAnchor processes` scrolls to a section.
                        guard let anchor = UserDefaults.standard.string(forKey: "MoleE2EScrollAnchor") else { return }
                        try? await Task.sleep(for: .seconds(3))
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if let error = monitor.lastError, !monitor.isRunning {
                ErrorBanner(message: error) { monitor.restart() }
                ScanningView(theme: theme, title: "Waiting for Mole…", detail: "Retrying automatically")
            } else {
                ScanningView(theme: theme, title: "Reading your Mac's vitals…")
                    .padding(.top, 60)
            }
        }
        .animation(.smooth(duration: 0.4), value: monitor.snapshot == nil)
        .overlay(alignment: .topTrailing) {
            // E2E screenshots of the menu bar panel: `-MoleE2EMenuPreview YES`.
            if UserDefaults.standard.bool(forKey: "MoleE2EMenuPreview") {
                MenuBarContent()
                    .background(.regularMaterial, in: .rect(cornerRadius: 18))
                    .shadow(radius: 20)
                    .padding(24)
            }
        }
        .onChange(of: monitor.snapshot?.collectedAt, initial: true) {
            pressure = StatusMemoryPressure.resolve(mole: monitor.snapshot?.memory?.pressure)
            recordIfReady()
        }
    }

    private var subtitle: String {
        if let host = monitor.snapshot?.host, !host.isEmpty { return "Live health of \(host)" }
        return theme.subtitle
    }

    @ViewBuilder private var headerTrailing: some View {
        HStack(spacing: 10) {
            if !monitor.isRunning {
                Label("Monitoring paused", systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Restart Monitor", systemImage: "arrow.clockwise") { monitor.restart() }
                .labelStyle(.iconOnly)
                .buttonStyle(.soft)
                .keyboardShortcut("r", modifiers: .command)
                .help("Restart live monitoring (⌘R)")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ snap: StatusSnapshot) -> some View {
        let rich = monitor.enriched
        StatusHealthHero(snapshot: snap, hardware: monitor.hardware)

        tiles(snap)

        if let alerts = snap.processAlerts, !alerts.isEmpty {
            InfoBanner(symbol: "flame.fill", title: "\(alerts.count) process\(alerts.count == 1 ? " is" : "es are") using sustained high CPU",
                       message: alerts.map { "\($0.name ?? "pid \($0.pid)") \(StatusFormat.percent($0.cpu))" }.joined(separator: " · "),
                       tint: .moleBad)
        }

        charts
            .id("charts")

        HStack(alignment: .top, spacing: Metrics.spacing) {
            VStack(spacing: Metrics.spacing) {
                if let cpu = snap.cpu { StatusCPUCard(cpu: mergedCPU(cpu, rich?.cpu), tint: theme.accent) }
                StatusDisksCard(disks: snap.disks ?? rich?.disks ?? [], io: snap.diskIo, tint: .indigo)
                if let gpus = snap.gpu ?? rich?.gpu, !gpus.isEmpty { StatusGPUCard(gpus: gpus, tint: .purple) }
                if let bt = snap.bluetooth ?? rich?.bluetooth, !bt.isEmpty { StatusBluetoothCard(devices: bt, tint: .blue) }
                StatusNetworkCard(interfaces: snap.network ?? [], proxy: snap.proxy ?? rich?.proxy, tint: .cyan)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            VStack(spacing: Metrics.spacing) {
                if let memory = snap.memory { StatusMemoryCard(memory: mergedMemory(memory, rich?.memory), pressure: pressure, tint: .pink) }
                if let battery = monitor.batteries?.first {
                    StatusBatteryCard(battery: battery, thermal: snap.thermal ?? rich?.thermal)
                }
                if let thermal = snap.thermal ?? rich?.thermal, hasPowerData(thermal) {
                    StatusPowerCard(thermal: thermal, tint: .orange)
                }
                StatusTrashCard(size: snap.trashSize ?? rich?.trashSize, approximate: snap.trashApprox == true,
                                fullDiskAccess: model.hasFullDiskAccess) {
                    model.route = .clean
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .id("cards")

        StatusProcessesCard(snapshot: snap, tint: theme.accent)
            .id("processes")

        if !snap.isEnriched && rich == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Collecting hardware details…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func tiles(_ snap: StatusSnapshot) -> some View {
        let samples = monitor.samples
        let cpu = snap.cpu?.usage ?? 0
        let mem = snap.memory?.usedPercent ?? 0
        let disk = (snap.disks ?? monitor.enriched?.disks)?.first
        let rx = (snap.network ?? []).reduce(0) { $0 + ($1.rxRateMbs ?? 0) }
        let tx = (snap.network ?? []).reduce(0) { $0 + ($1.txRateMbs ?? 0) }
        return GlassEffectContainer(spacing: 2) {
          HStack(spacing: 14) {
            StatusMetricTile(title: "CPU", symbol: "cpu", value: StatusFormat.percent(cpu),
                             detail: "Load \(StatusFormat.load(snap.cpu?.load1)) · \(snap.cpu?.logicalCpu ?? 0) cores",
                             tint: Color.usage(cpu) == .moleGood ? theme.accent : Color.usage(cpu),
                             fraction: cpu / 100)
            StatusMetricTile(title: "Memory", symbol: "memorychip", value: StatusFormat.percent(mem),
                             detail: "\(StatusFormat.memory(snap.memory?.used)) of \(StatusFormat.memory(snap.memory?.total))",
                             tint: Color.usage(mem) == .moleGood ? .pink : Color.usage(mem),
                             fraction: mem / 100)
            StatusMetricTile(title: "Disk", symbol: "internaldrive", value: StatusFormat.percent(disk.map { $0.fraction * 100 }),
                             detail: disk.map { "\(StatusFormat.bytes($0.free)) free" } ?? "—",
                             tint: .indigo, fraction: disk?.fraction)
            StatusMetricTile(title: "Network", symbol: "arrow.up.arrow.down", value: StatusFormat.rate(rx),
                             detail: "↑ \(StatusFormat.rate(tx))", tint: .cyan,
                             spark: samples.map { ($0.date, $0.netRx + $0.netTx) })
          }
        }
    }

    @ViewBuilder private var charts: some View {
        let samples = monitor.samples
        let last = samples.last
        Grid(horizontalSpacing: Metrics.spacing, verticalSpacing: Metrics.spacing) {
            GridRow {
                StatusChartCard(title: "CPU", symbol: "cpu", tint: theme.accent, value: StatusFormat.percent(last?.cpu)) {
                    if samples.count > 1 {
                        StatusPercentChart(points: samples.map { ($0.date, $0.cpu) }, tint: theme.accent, label: "CPU")
                    } else { StatusChartWarmup() }
                }
                StatusChartCard(title: "Memory", symbol: "memorychip", tint: .pink, value: StatusFormat.percent(last?.memory)) {
                    if samples.count > 1 {
                        StatusPercentChart(points: samples.map { ($0.date, $0.memory) }, tint: .pink, label: "Memory")
                    } else { StatusChartWarmup() }
                }
            }
            GridRow {
                StatusChartCard(title: "Network", symbol: "network", tint: .cyan,
                                value: StatusFormat.rate((last?.netRx ?? 0) + (last?.netTx ?? 0)),
                                legend: [("Down", .cyan), ("Up", .pink)]) {
                    if samples.count > 1 {
                        StatusRateChart(points: samples.flatMap {
                            [StatusSeriesPoint(id: "d\($0.id)", date: $0.date, value: $0.netRx, series: "Down"),
                             StatusSeriesPoint(id: "u\($0.id)", date: $0.date, value: $0.netTx, series: "Up")]
                        }, colors: ["Down": .cyan, "Up": .pink])
                    } else { StatusChartWarmup() }
                }
                StatusChartCard(title: "Disk Activity", symbol: "internaldrive", tint: .indigo,
                                value: StatusFormat.rate((last?.diskRead ?? 0) + (last?.diskWrite ?? 0)),
                                legend: [("Read", .indigo), ("Write", .orange)]) {
                    if samples.count > 1 {
                        StatusRateChart(points: samples.flatMap {
                            [StatusSeriesPoint(id: "r\($0.id)", date: $0.date, value: $0.diskRead, series: "Read"),
                             StatusSeriesPoint(id: "w\($0.id)", date: $0.date, value: $0.diskWrite, series: "Write")]
                        }, colors: ["Read": .indigo, "Write": .orange])
                    } else { StatusChartWarmup() }
                }
            }
        }
    }

    // MARK: Helpers

    /// The first watch line has 0 P/E cores; borrow from the last enriched snapshot.
    private func mergedCPU(_ cpu: StatusSnapshot.CPU, _ rich: StatusSnapshot.CPU?) -> StatusSnapshot.CPU {
        var c = cpu
        if (c.pCoreCount ?? 0) == 0 { c.pCoreCount = rich?.pCoreCount }
        if (c.eCoreCount ?? 0) == 0 { c.eCoreCount = rich?.eCoreCount }
        return c
    }

    private func mergedMemory(_ memory: StatusSnapshot.Memory, _ rich: StatusSnapshot.Memory?) -> StatusSnapshot.Memory {
        var m = memory
        if (m.cached ?? 0) == 0 { m.cached = rich?.cached }
        return m
    }

    private func hasPowerData(_ t: StatusSnapshot.Thermal) -> Bool {
        (t.systemPower ?? 0) > 0 || (t.adapterPower ?? 0) > 0 || (t.cpuTemp ?? 0) > 0 || (t.fanCount ?? 0) > 0
    }

    private func recordIfReady() {
        guard !recorded, let snap = monitor.snapshot, snap.isEnriched else { return }
        recorded = true
        model.automation.record("dashboard", passed: true, detail: "Enriched status snapshot shown", metrics: [
            "healthScore": "\(snap.healthScore ?? -1)",
            "healthMessage": snap.healthScoreMsg ?? "",
            "model": snap.hardware?.model ?? "",
            "chip": snap.hardware?.cpuModel ?? "",
            "cpuUsage": StatusFormat.percent(snap.cpu?.usage, digits: 1),
            "memoryUsed": StatusFormat.percent(snap.memory?.usedPercent, digits: 1),
            "disks": "\(snap.disks?.count ?? 0)",
            "samples": "\(monitor.samples.count)",
            "memoryPressure": pressure.rawValue,
            "topProcesses": "\(snap.topProcesses?.count ?? 0)",
        ])
    }
}
