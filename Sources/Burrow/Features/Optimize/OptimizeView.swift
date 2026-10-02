import Charts
import SwiftUI

struct OptimizeView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @State private var vm = OptimizeModel.shared
    @State private var confirming = false
    @State private var expandedTask: String?

    private let theme = FeatureTheme.optimize

    var body: some View {
        FeaturePage(theme: theme) {
            PageHeader(theme: theme, subtitle: subtitle) { headerActions }
        } content: {
            content
                .animation(.smooth(duration: 0.35), value: vm.phase)
        }
        .overlay(alignment: .bottom) { savedToast }
        .sheet(isPresented: $confirming) {
            OptimizeConfirmSheet(vm: vm, theme: theme) {
                confirming = false
                vm.start(.optimize, service: service)
            } onCancel: { confirming = false }
        }
        .task { await vm.onAppear(model: model, service: service) }
        .tidyAutomationScroll(ready: vm.resultMode != nil)
        .onChange(of: vm.phase) { _, phase in
            // Automation aid for screenshots: presents (never confirms) the sheet after the preview.
            if case .finished = phase, model.automation.autorun,
               UserDefaults.standard.string(forKey: "MoleE2ESheet") == "optimize.confirm" { confirming = true }
        }
    }

    private var subtitle: String {
        switch vm.phase {
        case .running(.preview): "Previewing \(vm.includedTasks.count) maintenance tasks…"
        case .running(.optimize): "Optimizing your Mac…"
        default: theme.subtitle
        }
    }

    @ViewBuilder private var headerActions: some View {
        HStack(spacing: 10) {
            if vm.isRunning {
                Button("Stop", systemImage: "stop.fill") { vm.cancel() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Preview", systemImage: "eye") { vm.start(.preview, service: service) }
                    .buttonStyle(.glass)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("See what Mole would do, without changing anything (⌘R)")
                Button {
                    // Re-read the exclusions so the sheet lists exactly what Mole will read when it starts.
                    vm.reloadWhitelist()
                    confirming = true
                } label: { Label("Optimize…", systemImage: "bolt.fill") }
                    .buttonStyle(.hero(theme))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(vm.includedTasks.isEmpty)
                    .help("Run the included tasks (⌘↩)")
            }
        }
    }

    @ViewBuilder private var content: some View {
        if case .failed(let message) = vm.phase {
            ErrorBanner(message: message) { vm.start(.preview, service: service) }
        }
        if let error = vm.saveError {
            ErrorBanner(message: error)
        }
        if let banner = vm.banner {
            InfoBanner(symbol: "stop.circle.fill", title: "Stopped", message: banner, tint: .moleWarn,
                       actionTitle: "Dismiss") { withAnimation { vm.banner = nil } }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        if let problem = vm.whitelistProblem {
            InfoBanner(symbol: "exclamationmark.lock.fill", title: "Your optimization exclusions can’t be read",
                       message: "\(problem) Task switches are disabled so the file isn’t replaced.", tint: .moleBad)
        } else if vm.whitelistIsLegacy {
            InfoBanner(symbol: "clock.arrow.circlepath", title: "Using your older whitelist_checks file",
                       message: "Mole still reads ~/.config/mole/whitelist_checks. Your next change saves these exclusions to whitelist_optimize, as Mole itself does.",
                       tint: .blue)
        }
        switch vm.phase {
        case .running:
            OptimizeProgressCard(vm: vm, theme: theme)
        case .finished(let mode):
            OptimizeSummaryCard(vm: vm, mode: mode, theme: theme)
        case .incomplete(let mode, let reason):
            OptimizeSummaryCard(vm: vm, mode: mode, theme: theme, incompleteReason: reason)
        default:
            OptimizeIntroCard(vm: vm, theme: theme) { vm.start(.preview, service: service) }
        }
        if let system = vm.report.system {
            OptimizeSystemStrip(system: system, theme: theme)
        }
        if !vm.report.diagnosis.isEmpty || !vm.report.notes.isEmpty {
            OptimizeInsightsCard(report: vm.report)
        }
        if let run = vm.run {
            RunStatusCard(run: run, theme: theme,
                          headline: run.state.isRunning ? (vm.runningMode == .optimize ? "Mole is optimizing" : "Mole is previewing") : "Mole output")
        }
        HStack(alignment: .firstTextBaseline) {
            SectionTitle(title: "Maintenance tasks", symbol: "square.grid.2x2",
                         detail: "\(vm.includedTasks.count) of \(vm.tasks.count) included")
        }
        .padding(.top, 4)
        .id("optimize.tasks")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], spacing: 14) {
            ForEach(vm.tasks) { task in
                OptimizeTaskCard(task: task, vm: vm, theme: theme, expanded: expandedTask == task.id) {
                    withAnimation(.snappy) { expandedTask = expandedTask == task.id ? nil : task.id }
                }
            }
        }
        OptimizeOptionsCard(vm: vm) { model.route = .protection }
    }

    @ViewBuilder private var savedToast: some View {
        if let message = vm.saveMessage {
            Label("Saved · \(message)", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(Color.moleGood.opacity(0.2)), in: .capsule)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

// MARK: - Intro

struct OptimizeIntroCard: View {
    let vm: OptimizeModel
    let theme: FeatureTheme
    let preview: () -> Void

    var body: some View {
        GlassCard(padding: 28) {
            HStack(spacing: 28) {
                ZStack {
                    Circle().fill(theme.gradient.opacity(0.15)).frame(width: 150, height: 150)
                    FeatureIcon(theme: theme, size: 80)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Keep macOS running smoothly")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Mole refreshes caches and services, repairs broken preferences and permissions, tidies databases and checks for performance bottlenecks. Preview first to see exactly what would change.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(action: preview) { Label("Preview Changes", systemImage: "eye") }
                            .buttonStyle(.hero(theme))
                        Pill(text: "\(vm.tasks.filter(\.needsAdmin).count) tasks need admin", symbol: "lock.shield", tint: .orange)
                        if !vm.catalogFromMole && vm.loaded {
                            Pill(text: "Built-in task list", symbol: "info.circle", tint: .secondary)
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Progress

struct OptimizeProgressCard: View {
    let vm: OptimizeModel
    let theme: FeatureTheme

    var body: some View {
        let total = max(1, vm.tasks.count)
        let done = vm.report.completedCount
        let current = vm.report.currentTaskID.flatMap { id in vm.tasks.first { $0.id == id } }
        GlassCard(padding: 26) {
            HStack(spacing: 30) {
                RingGauge(value: Double(done) / Double(total), colors: theme.colors, lineWidth: 16) {
                    VStack(spacing: 0) {
                        Text("\(done)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .contentTransition(.numericText(value: Double(done)))
                            .animation(.snappy, value: done)
                        Text("of \(total)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 140, height: 140)
                VStack(alignment: .leading, spacing: 10) {
                    Text(vm.runningMode == .optimize ? "Optimizing" : "Previewing")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        if let current {
                            Image(systemName: current.symbol)
                                .font(.title)
                                .foregroundStyle(theme.gradient)
                                .symbolEffect(.pulse, options: .repeat(.continuous))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        Text(current?.displayName ?? (vm.report.system == nil ? "Collecting system info…" : "Checking performance…"))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .contentTransition(.opacity)
                            .animation(.smooth, value: current?.id)
                    }
                    Text(current?.summary ?? "Mole samples CPU and memory for a moment before it starts the tasks.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Summary

struct OptimizeSummaryCard: View {
    let vm: OptimizeModel
    let mode: OptimizeModel.Mode
    let theme: FeatureTheme
    /// Set when Mole ended without a summary; the card then reports it as unfinished, never as success.
    var incompleteReason: String? = nil
    @State private var appeared = false

    private struct Slice: Identifiable {
        let id: String
        let count: Int
        let color: Color
    }

    var body: some View {
        let s = vm.report.summary
        let attention = s?.attentionCount ?? 0
        let slices = outcomeSlices(s)
        let warn = attention > 0 || incompleteReason != nil || s == nil
        GlassCard(padding: 26, tint: mode == .optimize && !warn ? theme.accent : nil) {
            HStack(spacing: 28) {
                ZStack {
                    if !slices.isEmpty {
                        Chart(slices) { slice in
                            SectorMark(angle: .value("Tasks", slice.count), innerRadius: .ratio(0.66), angularInset: 2)
                                .cornerRadius(4)
                                .foregroundStyle(slice.color)
                        }
                        .chartLegend(.hidden)
                        .accessibilityLabel("Task outcomes")
                    } else {
                        Circle().stroke(.quaternary, lineWidth: 16)
                    }
                    VStack(spacing: 0) {
                        Text("\(s?.applied ?? 0)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.gradient)
                            .contentTransition(.numericText())
                        Text(mode == .preview ? "would apply" : "applied").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 160, height: 160)
                .scaleEffect(appeared ? 1 : 0.85)
                .opacity(appeared ? 1 : 0)
                VStack(alignment: .leading, spacing: 10) {
                    Label(headline(s, attention: attention), systemImage: warn ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(warn ? Color.moleWarn : Color.moleGood)
                    Text(detail(s, attention: attention))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FlowPills(slices: slices.map { ($0.id, $0.count, $0.color) })
                    if let stat = s?.keyStat {
                        Pill(text: stat, symbol: "sparkles", tint: theme.accent)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true } }
    }

    private func headline(_ s: OptimizeReport.Summary?, attention: Int) -> String {
        if incompleteReason != nil || s == nil { return mode == .preview ? "Preview didn’t finish" : "Optimization didn’t finish" }
        guard let s else { return "" }
        if attention > 0 { return mode == .preview ? "Preview ready · \(attention) need attention" : "Done · \(attention) need attention" }
        return mode == .preview ? "Preview ready" : (s.heading.isEmpty ? "Optimization complete" : s.heading)
    }

    private func detail(_ s: OptimizeReport.Summary?, attention: Int) -> String {
        if let incompleteReason { return incompleteReason }
        guard let s else { return "Mole ended without a summary. Open the output for details." }
        let n = s.applied ?? 0
        var text = mode == .preview
            ? "\(n) optimization\(n == 1 ? "" : "s") would be applied. Nothing has changed yet."
            : "\(n) optimization\(n == 1 ? " was" : "s were") applied."
        if attention > 0 { text += " Tasks marked in orange couldn’t finish; see their notes below." }
        return text
    }

    private func outcomeSlices(_ s: OptimizeReport.Summary?) -> [Slice] {
        guard let s else { return [] }
        var out: [Slice] = []
        if let a = s.applied, a > 0 { out.append(Slice(id: mode == .preview ? "would apply" : "applied", count: a, color: theme.accent)) }
        let colors: [String: Color] = ["unchanged": .moleGood, "skipped": .secondary, "unavailable": .gray,
                                       "need attention": .moleWarn, "failed": .moleBad]
        for key in ["unchanged", "skipped", "unavailable", "need attention", "failed"] {
            if let n = s.outcomes[key], n > 0 { out.append(Slice(id: key, count: n, color: colors[key] ?? .secondary)) }
        }
        return out
    }
}

private struct FlowPills: View {
    let slices: [(String, Int, Color)]
    var body: some View {
        TidyFlowLayout(spacing: 8) {
            ForEach(slices, id: \.0) { s in
                HStack(spacing: 5) {
                    Circle().fill(s.2).frame(width: 7, height: 7)
                    Text("\(s.1) \(s.0)").font(.caption.weight(.semibold)).fixedSize()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(s.2.opacity(0.14), in: .capsule)
            }
        }
    }
}

// MARK: - System + insights

struct OptimizeSystemStrip: View {
    let system: OptimizeReport.SystemStats
    let theme: FeatureTheme

    var body: some View {
        HStack(spacing: 14) {
            StatTile(title: "Memory", value: "\(Int(system.ramUsed)) of \(Int(system.ramTotal)) GB", symbol: "memorychip",
                     tint: .purple, fraction: system.ramTotal > 0 ? system.ramUsed / system.ramTotal : nil)
            StatTile(title: "Disk", value: "\(Int(system.diskUsed)) of \(Int(system.diskTotal)) GB", symbol: "internaldrive",
                     tint: .blue, fraction: system.diskTotal > 0 ? system.diskUsed / system.diskTotal : nil)
            StatTile(title: "Uptime", value: "\(system.uptimeDays) day\(system.uptimeDays == 1 ? "" : "s")",
                     symbol: "clock", tint: system.uptimeDays > 14 ? .moleWarn : theme.accent,
                     fraction: min(1, Double(system.uptimeDays) / 30))
                .help(system.uptimeDays > 14 ? "A restart can help after long uptimes" : "Time since the last restart")
        }
    }
}

struct OptimizeInsightsCard: View {
    let report: OptimizeReport

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Performance diagnosis", symbol: "stethoscope")
                ForEach(report.notes + report.diagnosis) { line in
                    OptimizeLineView(line: line)
                }
            }
        }
    }
}

struct OptimizeLineView: View {
    let line: OptimizeReport.ResultLine

    var body: some View {
        if line.kind == .detail {
            let parts = line.text.split(separator: " ", omittingEmptySubsequences: true)
            let size = parts.last.map(String.init) ?? ""
            let name = ByteFormat.parse(size) != nil ? parts.dropLast().joined(separator: " ") : line.text
            HStack {
                Image(systemName: "memorychip").foregroundStyle(.tertiary).font(.caption)
                Text(name).font(.caption)
                Spacer()
                if ByteFormat.parse(size) != nil { Text(size).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(.leading, 28)
            .frame(maxWidth: 520)
        } else {
            Label {
                Text(line.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
    }

    private var symbol: String {
        switch line.kind {
        case .applied: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .neutral: "minus.circle.fill"
        case .info, .detail: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch line.kind {
        case .applied: .moleGood
        case .attention: .moleWarn
        case .neutral: .secondary
        case .info, .detail: .blue
        }
    }
}
