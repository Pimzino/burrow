import Charts
import SwiftUI

struct CleanView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @State private var vm = CleanModel.shared
    @State private var confirming = false
    @State private var detail: CleanDetailRequest?
    @State private var showConsole = false

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
                    .buttonStyle(.glass)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop Mole (⌘.)")
            } else {
                if vm.phase == .scanned || vm.phase == .cleaned {
                    Button("Rescan", systemImage: "arrow.clockwise") { vm.scan(service: service) }
                        .buttonStyle(.glass)
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
                } else if vm.phase != .cleaned {
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
            if let run = vm.run {
                RunStatusCard(run: run, theme: theme, headline: vm.phase == .cleaning ? "Mole is cleaning" : "Mole is scanning")
            }
            CleanSectionsGrid(report: vm.report, live: true, vm: vm) { detail = $0 }
        case .scanned:
            let report = vm.scanReport ?? vm.report
            CleanResultsHero(vm: vm, report: report, theme: theme) { confirming = true }
            if let blocker = vm.cleanBlocker, report.summary?.alreadyClean != true {
                InfoBanner(symbol: "eye.trianglebadge.exclamationmark", title: "Preview only", message: blocker, tint: .moleWarn,
                           actionTitle: "Scan Again") { vm.scan(service: service) }
            }
            CleanNotices(report: report, includeSystem: vm.scannedConfig?.includesSystem ?? vm.includeSystem) { model.route = .protection }
            CleanSectionsGrid(report: report, live: false, vm: vm) { detail = $0 }
                .id("clean.sections")
            if !report.reviewRows.isEmpty { CleanReviewCard(rows: report.reviewRows) }
            CleanOptionsCard(vm: vm)
        case .cleaned:
            CleanSuccessCard(vm: vm, report: vm.report, theme: theme) { vm.startOver() }
            CleanSectionsGrid(report: vm.report, live: false, vm: vm) { detail = $0 }
            if let run = vm.run { RunStatusCard(run: run, theme: theme, headline: "Mole output") }
        }
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
    @State private var pulse = false

    var body: some View {
        GlassCard(padding: 32) {
            HStack(spacing: 32) {
                ZStack {
                    Circle().fill(theme.gradient.opacity(0.14)).frame(width: 170, height: 170)
                        .scaleEffect(pulse ? 1.05 : 0.96)
                    Circle().strokeBorder(theme.gradient, lineWidth: 2).frame(width: 138, height: 138).opacity(0.5)
                    FeatureIcon(theme: theme, size: 86)
                }
                .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever()) { pulse = true } }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Find space you can safely reclaim")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Mole previews caches, logs, browser leftovers and developer junk first. Nothing is deleted until you review the results and confirm.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(action: scan) {
                            Label(vm.isExternalMode ? "Scan \(vm.externalVolume?.name ?? "Drive")" : "Scan My Mac", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.hero(theme))
                        if let date = vm.lastPreviewDate {
                            Label("Last preview \(date)", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                    HStack(spacing: 8) {
                        Pill(text: "Dry run first", symbol: "eye", tint: theme.accent)
                        Pill(text: "Protected paths honoured", symbol: "checkmark.shield", tint: .blue)
                        Pill(text: "Takes a couple of minutes", symbol: "timer", tint: .secondary)
                    }
                }
                Spacer(minLength: 0)
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
                        .foregroundStyle(theme.gradient)
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
    let clean: () -> Void

    private struct Slice: Identifiable {
        let id: String
        let bytes: Int64
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
                          systemImage: summary?.alreadyClean == true ? "checkmark.seal.fill" : vm.canClean ? "sparkles" : "eye.trianglebadge.exclamationmark")
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
                            .foregroundStyle(theme.gradient)
                            .contentTransition(.numericText(value: Double(bytes)))
                            .monospacedDigit()
                    }
                    Text(vm.scannedConfig?.volume.map { "can be reclaimed from \($0.name)" } ?? (vm.canClean ? "can be reclaimed safely" : "found before the scan stopped"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if let items = summary?.items { Pill(text: "\(items.formatted()) items", symbol: "doc.on.doc", tint: theme.accent) }
                        if let c = summary?.categories { Pill(text: "\(c) categories", symbol: "square.grid.2x2", tint: .blue) }
                        if let free = summary?.freeSpace ?? report.freeSpaceBefore { Pill(text: "\(CleanStyle.human(free)) free", symbol: "internaldrive", tint: .secondary) }
                    }
                    .fixedSize()
                    HStack(spacing: 10) {
                        Button(action: clean) { Label("Clean…", systemImage: "sparkles") }
                            .buttonStyle(.hero(theme))
                            .disabled(!vm.canClean)
                            .help(vm.cleanBlocker ?? "Review and clean")
                        if let file = summary?.previewFile {
                            Button("Full List", systemImage: "list.bullet.rectangle") { Finder.open(file) }
                                .buttonStyle(.glass)
                                .help("Open Mole's detailed preview file")
                        }
                    }
                    .fixedSize()
                    .padding(.top, 6)
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
                    .frame(width: 180, height: 180)
                    .chartBackground { _ in
                        VStack(spacing: 0) {
                            Text("\(slices.count)").font(.system(size: 30, weight: .bold, design: .rounded))
                            Text(slices.count == 1 ? "category" : "categories").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Reclaimable space by category")
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(slices.prefix(6)) { s in
                            HStack(spacing: 8) {
                                Circle().fill(CleanStyle.color(for: s.id)).frame(width: 8, height: 8)
                                Text(s.id).font(.caption).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(ByteFormat.string(s.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 190)
                }
            }
        }
    }
}

// MARK: - Notices

struct CleanNotices: View {
    let report: CleanReport
    let includeSystem: Bool
    let openProtection: () -> Void

    var body: some View {
        let sudoHint = report.notices.first { $0.contains("need sudo") || $0.contains("System-level cleanup skipped") }
        let warnings = report.notices.filter { $0.hasPrefix("◎ Whitelist") || $0.hasPrefix("Whitelist:") }
        VStack(spacing: 10) {
            if sudoHint != nil && !includeSystem {
                InfoBanner(symbol: "lock.shield", title: "System caches were not included",
                           message: "Turn on “Include system caches” below to preview and clean them too (requires your password).",
                           tint: .orange)
            }
            if !warnings.isEmpty {
                InfoBanner(symbol: "exclamationmark.shield", title: "Some protection rules were ignored",
                           message: warnings.joined(separator: "\n"), tint: .moleWarn, actionTitle: "Protection", action: openProtection)
            }
            if let status = report.whitelistStatus {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(Color.moleGood)
                    Text("Protection: \(status)").font(.callout)
                    Spacer()
                    Button("Manage", action: openProtection).buttonStyle(.link)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
            }
        }
    }
}
