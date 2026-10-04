import Charts
import SwiftUI

struct CleanView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @State private var vm = CleanModel.shared
    @State private var confirming = false
    @State private var detail: CleanDetailRequest?

    private let theme = FeatureTheme.clean

    var body: some View {
        FeaturePage(theme: theme) {
            PageHeader(theme: theme, subtitle: subtitle) { headerActions }
        } content: {
            content
                .animation(.smooth(duration: 0.35), value: vm.phase)
        }
        .sheet(isPresented: $confirming) {
            CleanConfirmSheet(vm: vm, theme: theme) {
                confirming = false
                vm.clean(service: service)
            } onCancel: { confirming = false }
        }
        .sheet(item: $detail) { request in
            CleanSectionDetailSheet(vm: vm, request: request)
        }
        .onAppear { vm.onAppear(model: model, service: service) }
        .tidyAutomationScroll(ready: vm.phase == .scanned)
        .onChange(of: vm.phase) { _, phase in
            // Automation aid for screenshots: presents (never confirms) a sheet after the scan.
            guard phase == .scanned, model.automation.autorun,
                  let sheet = UserDefaults.standard.string(forKey: "MoleE2ESheet") else { return }
            if sheet == "clean.confirm" { confirming = true }
            if sheet.hasPrefix("clean.detail:") { detail = CleanDetailRequest(section: String(sheet.dropFirst("clean.detail:".count))) }
        }
    }

    private var subtitle: String {
        switch vm.phase {
        case .scanning: vm.isExternalMode ? "Previewing \(vm.externalVolume?.name ?? "external drive")…" : "Looking for caches, logs and leftovers…"
        case .cleaning: "Cleaning up…"
        case .cleaned: "Cleanup finished"
        default: theme.subtitle
        }
    }

    // MARK: Header actions

    @ViewBuilder private var headerActions: some View {
        HStack(spacing: 10) {
            if vm.isBusy {
                Button("Stop", systemImage: "stop.fill") { vm.cancel() }
                    .buttonStyle(.soft)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop Mole (⌘.)")
            } else {
                if vm.phase == .scanned || vm.phase == .cleaned {
                    Button("Rescan", systemImage: "arrow.clockwise") { vm.scan(service: service) }
                        .buttonStyle(.soft)
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Scan again (⌘R)")
                }
                if vm.phase == .scanned {
                    Button {
                        confirming = true
                    } label: {
                        Label("Clean…", systemImage: "sparkles")
                    }
                    .buttonStyle(.hero(theme))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!vm.canClean)
                    .help(vm.cleanBlocker ?? "Review and clean (⌘↩)")
                } else if case .failed = vm.phase {
                    Button {
                        vm.scan(service: service)
                    } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.hero(theme))
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Preview what Mole would clean (⌘R)")
                }
            }
        }
    }

    // MARK: Phases

    @ViewBuilder private var content: some View {
        if let banner = vm.banner {
            InfoBanner(symbol: "exclamationmark.bubble.fill", title: "Heads up", message: banner, tint: .moleWarn,
                       actionTitle: "Dismiss") { withAnimation { vm.banner = nil } }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        switch vm.phase {
        case .idle:
            CleanIdleHero(vm: vm, theme: theme) { vm.scan(service: service) }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            CleanOptionsCard(vm: vm)
        case .failed(let message):
            ErrorBanner(message: message) { vm.scan(service: service) }
            CleanOptionsCard(vm: vm)
        case .scanning, .cleaning:
            CleanProgressHero(vm: vm, theme: theme)
            CleanSectionsList(report: vm.report, live: true, vm: vm) { detail = $0 }
        case .scanned:
            let report = vm.scanReport ?? vm.report
            CleanResultsHero(vm: vm, report: report, theme: theme)
            if let blocker = vm.cleanBlocker, report.summary?.alreadyClean != true {
                InfoBanner(symbol: "eye.trianglebadge.exclamationmark", title: "Preview only", message: blocker, tint: .moleWarn,
                           actionTitle: "Scan Again") { vm.scan(service: service) }
            }
            CleanNotices(report: report) { model.route = .protection }
            CleanSectionsList(report: report, live: false, vm: vm,
                              protection: report.whitelistStatus,
                              systemSkipped: report.systemSkipped && !(vm.scannedConfig?.includesSystem ?? vm.includeSystem),
                              openProtection: { model.route = .protection }) { detail = $0 }
                .id("clean.sections")
            if !report.reviewRows.isEmpty { CleanReviewCard(rows: report.reviewRows) }
            CleanOptionsCard(vm: vm)
        case .cleaned:
            CleanSuccessCard(vm: vm, report: vm.report, theme: theme) { vm.startOver() }
            CleanSectionsList(report: vm.report, live: false, vm: vm) { detail = $0 }
        }
    }
}

extension CleanReport {
    /// Mole said it left system-level caches alone because it had no administrator access.
    var systemSkipped: Bool {
        notices.contains { $0.contains("need sudo") || $0.contains("System-level cleanup skipped") }
    }
}

struct CleanDetailRequest: Identifiable, Hashable {
    let section: String
    var id: String { section }
}

// MARK: - Idle

struct CleanIdleHero: View {
    let vm: CleanModel
    let theme: FeatureTheme
    let scan: () -> Void

    var body: some View {
        GlassCard(padding: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Find space you can safely reclaim")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Mole previews caches, logs, browser leftovers and developer junk first. Nothing is deleted until you review the results and confirm. A scan takes a couple of minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
                HStack(spacing: 12) {
                    Button(action: scan) {
                        Label(vm.isExternalMode ? "Scan \(vm.externalVolume?.name ?? "Drive")" : "Scan My Mac", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.hero(theme))
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Preview what Mole would clean (⌘R)")
                    if let date = vm.lastPreviewDate {
                        Text("Last scanned \(CleanStyle.friendlyDate(date))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Options

struct CleanOptionsCard: View {
    @Bindable var vm: CleanModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Options", symbol: "slider.horizontal.3")
                TidyOptionRow(symbol: "lock.shield.fill", tint: .orange, title: "Include system caches",
                              detail: vm.isExternalMode ? "Not used when cleaning an external drive."
                                  : "Also scans and cleans system-level caches and logs. Mole asks for your administrator password.") {
                    Toggle("Include system caches", isOn: $vm.includeSystem).labelsHidden().toggleStyle(.switch)
                        .disabled(vm.isExternalMode)
                }
                Divider().opacity(0.5)
                TidyOptionRow(symbol: "trash.fill", tint: .pink, title: "Keep Trash contents",
                              detail: vm.keepTrash ? "The Trash is left untouched." : "By default Mole also empties your Trash when it cleans.") {
                    Toggle("Keep Trash contents", isOn: $vm.keepTrash).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.5)
                TidyOptionRow(symbol: "externaldrive.fill", tint: .blue, title: "Clean an external drive",
                              detail: vm.volumes.isEmpty
                                  ? "No external drives are mounted."
                                  : "Only removes .Trashes, .TemporaryItems, ._ AppleDouble files and .DS_Store from the drive.") {
                    HStack(spacing: 8) {
                        if vm.externalEnabled && !vm.volumes.isEmpty {
                            Picker("Drive", selection: $vm.externalVolumePath) {
                                ForEach(vm.volumes) { v in
                                    Text(v.name).tag(Optional(v.path))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 180)
                        }
                        Button {
                            vm.refreshVolumes()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Look for drives again")
                        Toggle("Clean an external drive", isOn: $vm.externalEnabled).labelsHidden().toggleStyle(.switch)
                            .disabled(vm.volumes.isEmpty)
                    }
                }
            }
        }
        .disabled(vm.isBusy)
    }
}

// MARK: - Progress

struct CleanProgressHero: View {
    let vm: CleanModel
    let theme: FeatureTheme

    var body: some View {
        let report = vm.report
        let bytes = report.rowsTotalBytes
        GlassCard(padding: 8) {
            HStack(alignment: .center, spacing: 12) {
                ScanningView(theme: theme,
                             title: vm.phase == .cleaning ? "Cleaning" : "Scanning",
                             detail: report.currentSection.map { "Now: \($0)" } ?? "Preparing…")
                    .frame(maxWidth: 360)
                VStack(alignment: .leading, spacing: 14) {
                    Text(vm.phase == .cleaning ? "Cleaned so far" : "Found so far")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(CleanStyle.size(bytes))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .contentTransition(.numericText(value: Double(bytes)))
                        .animation(.snappy, value: bytes)
                        .monospacedDigit()
                    HStack(spacing: 18) {
                        miniStat("\(report.sections.count)", "sections checked", "checklist")
                        miniStat("\(report.allRows.filter { $0.kind == .wouldClean || $0.kind == .cleaned }.count)", "groups found", "square.stack.3d.up")
                        if let free = report.freeSpaceBefore { miniStat(CleanStyle.human(free), "free now", "internaldrive") }
                    }
                    CapsuleBar(fraction: min(1, Double(report.sections.count) / Double(vm.isExternalMode ? 1 : 15)), tint: theme.accent, height: 6)
                        .frame(maxWidth: 360)
                        .animation(.smooth, value: report.sections.count)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
    }

    private func miniStat(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Results hero

struct CleanResultsHero: View {
    let vm: CleanModel
    let report: CleanReport
    let theme: FeatureTheme

    private struct Slice: Identifiable {
        let id: String
        let bytes: Int64
    }

    static func facts(_ s: CleanReport.Summary?, free: String?) -> String {
        var parts: [String] = []
        if let items = s?.items { parts.append("\(items.formatted()) items") }
        if let c = s?.categories { parts.append("\(c) categories") }
        if let free { parts.append("\(CleanStyle.human(free)) free now") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let summary = report.summary
        let bytes = summary?.spaceBytes ?? report.rowsTotalBytes
        let slices = report.sections.filter { $0.totalBytes > 0 && !$0.isLargeFiles }
            .map { Slice(id: $0.title, bytes: $0.totalBytes) }
            .sorted { $0.bytes > $1.bytes }
        GlassCard(padding: 28) {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(summary?.alreadyClean == true ? "Nothing significant to clean" : vm.canClean ? "Ready to clean" : "Partial preview",
                          systemImage: summary?.alreadyClean == true ? "checkmark.seal.fill" : vm.canClean ? "checkmark.circle.fill" : "eye.trianglebadge.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(theme.accent)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if summary?.atLeast == true {
                            Text("at least").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                        }
                        Text(CleanStyle.size(bytes))
                            .font(.system(size: 60, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(theme.accent)
                            .contentTransition(.numericText(value: Double(bytes)))
                            .monospacedDigit()
                    }
                    Text(vm.scannedConfig?.volume.map { "can be reclaimed from \($0.name)" } ?? (vm.canClean ? "can be reclaimed safely" : "found before the scan stopped"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(Self.facts(summary, free: summary?.freeSpace ?? report.freeSpaceBefore))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let file = summary?.previewFile {
                        Button("Open Full List", systemImage: "list.bullet.rectangle") { Finder.open(file) }
                            .buttonStyle(.soft)
                            .help("Open Mole's detailed preview file")
                            .padding(.top, 6)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if !slices.isEmpty {
                    Chart(slices) { slice in
                        SectorMark(angle: .value("Size", slice.bytes), innerRadius: .ratio(0.64), angularInset: 1.5)
                            .cornerRadius(5)
                            .foregroundStyle(CleanStyle.color(for: slice.id))
                    }
                    .chartLegend(.hidden)
                    .frame(width: 160, height: 160)
                    .padding(.trailing, 12)
                    .chartBackground { _ in
                        VStack(spacing: 0) {
                            Text("\(slices.count)").font(.system(size: 30, weight: .bold, design: .rounded))
                            Text(slices.count == 1 ? "category" : "categories").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Reclaimable space by category")
                }
            }
        }
    }
}

// MARK: - Notices

struct CleanNotices: View {
    let report: CleanReport
    let openProtection: () -> Void

    var body: some View {
        let warnings = report.notices.filter { $0.hasPrefix("◎ Whitelist") || $0.hasPrefix("Whitelist:") }
        if !warnings.isEmpty {
            InfoBanner(symbol: "exclamationmark.shield", title: "Some protection rules were ignored",
                       message: warnings.joined(separator: "\n"), tint: .moleWarn, actionTitle: "Protection", action: openProtection)
        }
    }
}
