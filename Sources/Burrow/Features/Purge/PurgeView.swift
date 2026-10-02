import AppKit
import Charts
import SwiftUI

struct PurgeView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service

    @State private var store = PurgeStore.shared
    @State private var confirming = false

    private let theme = FeatureTheme.purge

    var body: some View {
        @Bindable var store = store
        FeaturePage(theme: theme) {
            PageHeader(theme: theme, subtitle: subtitle) {
                HStack(spacing: 12) {
                    Toggle("Include empty folders", isOn: $store.includeEmpty)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(store.isBusy)
                        .help("Also list artifact folders that are empty (--include-empty)")
                    Button {
                        Task { await store.runScan(service: service) }
                    } label: {
                        Label(store.scannedAt == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isBusy)
                    .help("Preview what Mole would purge (⌘R)")
                }
            }
        } content: {
            content
        }
        .animation(.smooth, value: store.phase)
        .sheet(isPresented: $confirming) { confirmSheet }
        .task { await onAppear() }
    }

    private var subtitle: String {
        guard store.scannedAt != nil, store.phase != .scanning else { return "Old build artifacts in your projects" }
        if store.artifacts.isEmpty { return "No old build artifacts" }
        return "\(store.artifacts.count) artifacts in \(store.projects.count) projects · \(ByteFormat.string(store.totalBytes))"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            GlassCard {
                VStack(spacing: 16) {
                    EmptyStateView(symbol: "hammer", title: "Reclaim space from old builds",
                                   message: "node_modules, target, .venv, DerivedData and friends from projects you have not touched in a week.",
                                   tint: theme.accent)
                    Button { Task { await store.runScan(service: service) } } label: {
                        Label("Scan Projects", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.hero(theme))
                }
                .padding(.bottom, 20)
            }
        case .scanning:
            GlassCard {
                VStack(spacing: 6) {
                    ScanningView(theme: theme, title: "Scanning your projects",
                                 detail: store.currentRoot.map { "Looking in \(MoleHomeDir.abbreviate($0))" } ?? "Finding project folders…")
                    Button("Stop") { store.cancelScan() }.buttonStyle(.glass)
                }
                .padding(.bottom, 12)
            }
        case .verifying:
            GlassCard {
                VStack(spacing: 6) {
                    ScanningView(theme: theme, title: "Checking the list one last time",
                                 detail: "Mole purges whatever is eligible when it runs, so the app confirms nothing new has appeared since you reviewed it.")
                    Button("Stop") { store.cancelVerify() }.buttonStyle(.glass)
                }
                .padding(.bottom, 12)
            }
        case .purging:
            FlowProgressCard(theme: theme, title: "Purging project artifacts…",
                             detail: "Mole removes each eligible folder and re-checks it just before deleting. Per-item progress is not reported without a terminal.",
                             run: store.purgeRun, cancelTitle: nil)
        case .failed(let message):
            ErrorBanner(message: message) { Task { await store.runScan(service: service) } }
            scanLocations
        case .ready:
            ready
        }
    }

    @ViewBuilder
    private var ready: some View {
        purgeResultCard
        ForEach(store.scan.failures, id: \.self) { failure in
            InfoBanner(symbol: "lock.trianglebadge.exclamationmark.fill",
                       title: "Couldn't scan \(failure.root)",
                       message: failure.needsFullDiskAccess && !model.hasFullDiskAccess
                           ? "macOS blocked access (\(failure.status)). Give Burrow Full Disk Access so Mole can look inside."
                           : "Mole could not finish scanning this folder (\(failure.status)). Other folders were scanned normally.",
                       tint: .moleWarn,
                       actionTitle: failure.needsFullDiskAccess && !model.hasFullDiskAccess ? "Open Settings" : nil,
                       action: failure.needsFullDiskAccess && !model.hasFullDiskAccess ? { FullDiskAccess.openSettings() } : nil)
        }
        if let change = store.listChange { listChangeCard(change) }
        if let stale = store.staleReason {
            InfoBanner(symbol: "arrow.triangle.2.circlepath", title: "This list is out of date", message: stale,
                       tint: .moleWarn, actionTitle: "Rescan") { Task { await store.runScan(service: service) } }
        }
        if let error = store.protectError { ErrorBanner(message: error) }
        if store.artifacts.isEmpty {
            GlassCard {
                VStack(spacing: 6) {
                    ResultBurst(style: .success, theme: theme, size: 54)
                    Text(store.scan.failures.isEmpty ? "No old project artifacts" : "Nothing to purge in the folders Mole could scan")
                        .font(.title3.weight(.semibold))
                    Text("Artifacts in projects you used in the last 7 days are always kept.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
        } else {
            overview
            ForEach(store.projects) { project in projectCard(project) }
        }
        recentNote
        protectedSection
        scanLocations
    }

    private var overview: some View {
        HStack(alignment: .top, spacing: 14) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Reclaimable").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text(ByteFormat.string(store.totalBytes))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.gradient)
                        .contentTransition(.numericText())
                    Text("\(store.artifacts.count) artifacts · \(store.projects.count) projects")
                        .foregroundStyle(.secondary)
                    if let unmeasured = store.scan.summary?.unmeasured, unmeasured > 0 {
                        Text("+ \(unmeasured) unmeasured").font(.caption).foregroundStyle(.secondary)
                    }
                    if store.cloudCount > 0 {
                        Label("\(store.cloudCount) in cloud storage \(store.cloudCount == 1 ? "is" : "are") skipped", systemImage: "icloud")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button {
                        confirming = true
                    } label: {
                        Label("Purge All Eligible", systemImage: "hammer.fill")
                    }
                    .buttonStyle(.hero(theme))
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!store.canPurge)
                    .help(store.staleReason ?? (store.purgeable.isEmpty ? "Nothing Mole would remove" : "Remove every artifact listed below (⌘⌫)"))
                }
            }
            .frame(width: 300)
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "By artifact type", symbol: "chart.bar.xaxis")
                    Chart(store.byType.prefix(8), id: \.type) { entry in
                        BarMark(x: .value("Size", entry.bytes), y: .value("Type", entry.type))
                            .foregroundStyle(theme.gradient)
                            .cornerRadius(6)
                            .annotation(position: .trailing, alignment: .leading) {
                                Text(ByteFormat.string(entry.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisValueLabel {
                                if let type = value.as(String.self) {
                                    HStack(spacing: 6) {
                                        Image(systemName: PurgeTypes.symbol(for: type)).foregroundStyle(theme.accent)
                                        Text(type).lineLimit(1)
                                    }
                                    .font(.callout)
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                        }
                    }
                    .frame(height: CGFloat(max(2, min(8, store.byType.count))) * 34)
                    .padding(.trailing, 60)
                }
            }
        }
    }

    private func projectCard(_ project: PurgeProject) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    FileIconView(path: MoleHomeDir.expand(project.displayPath), size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.headline)
                        Text(project.displayPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteFormat.string(project.bytes))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
                .contextMenu {
                    Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(MoleHomeDir.expand(project.displayPath)) }
                    Button("Copy Path", systemImage: "doc.on.doc") { copy(MoleHomeDir.expand(project.displayPath)) }
                }
                ChipFlowLayout(spacing: 8) {
                    ForEach(project.artifacts) { artifact in artifactChip(artifact) }
                }
            }
        }
    }

    private func artifactChip(_ artifact: PurgeArtifact) -> some View {
        let isProtected = store.isProtected(artifact)
        let cantProtect = WhitelistPattern.literalProtectionError(artifact.path)
        return Menu {
            Button(isProtected ? "Protected" : "Protect (Never Purge)", systemImage: "lock.shield") {
                Task { await store.protect(artifact, service: service) }
            }
            .disabled(isProtected || cantProtect != nil || store.isBusy)
            if !isProtected, let cantProtect { Text(cantProtect) }
            Divider()
            Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(artifact.path) }
            Button("Copy Path", systemImage: "doc.on.doc") { copy(artifact.path) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isProtected ? "lock.fill" : PurgeTypes.symbol(for: artifact.type))
                    .foregroundStyle(isProtected ? AnyShapeStyle(Color.moleGood) : AnyShapeStyle(theme.gradient))
                Text(artifact.type).font(.callout.weight(.medium))
                Text(ByteFormat.parse(artifact.size).map { ByteFormat.string($0) } ?? artifact.size)
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if artifact.isCloud { Image(systemName: "icloud").foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .glassEffect(isProtected ? .regular.tint(Color.moleGood.opacity(0.2)).interactive() : .regular.interactive(), in: .capsule)
        .fixedSize()
        .help(isProtected ? "\(artifact.displayPath) is protected" : artifact.displayPath)
        .accessibilityLabel("\(artifact.type), \(artifact.size)\(isProtected ? ", protected" : "")")
    }

    private var recentNote: some View {
        InfoBanner(symbol: "clock.badge.checkmark",
                   title: "Recently active projects are kept automatically",
                   message: "Mole skips artifacts modified in the last 7 days, so you won't lose the build you're working on.",
                   tint: theme.accent)
    }

    @ViewBuilder
    private var protectedSection: some View {
        if !store.protected.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Protected artifacts", symbol: "lock.shield.fill", detail: "\(store.protected.count)")
                    ForEach(store.protected) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: PurgeTypes.symbol(for: entry.type))
                                .foregroundStyle(Color.moleGood).frame(width: 18)
                            Text(entry.path).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Unprotect") { Task { await store.unprotect(entry, service: service) } }
                                .buttonStyle(.glass).controlSize(.small)
                                .disabled(store.isBusy)
                        }
                    }
                    Text("Protection is stored in Mole’s whitelist, which Clean honours too. Changing it means rescanning before the next purge.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var scanLocations: some View {
        let (configured, problem) = PurgeScanPaths.configured()
        let roots = configured.isEmpty ? PurgeScanPaths.defaults : configured
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Where Mole looks", symbol: "folder.badge.gearshape",
                                 detail: configured.isEmpty ? "Default locations" : "Your list")
                    Button("Edit in Protection", systemImage: "arrow.right.circle") { model.route = .protection }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                ChipFlowLayout(spacing: 8) {
                    ForEach(roots, id: \.self) { root in
                        let failed = store.scan.failures.contains { $0.root == root }
                        let exists = FileManager.default.fileExists(atPath: MoleHomeDir.expand(root))
                        Label(root, systemImage: failed ? "exclamationmark.triangle.fill" : exists ? "folder.fill" : "folder.badge.questionmark")
                            .font(.callout)
                            .foregroundStyle(failed ? Color.moleWarn : exists ? .primary : .secondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.quaternary.opacity(0.5), in: .capsule)
                    }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.moleWarn)
                }
                if configured.count == 1, configured.first?.contains("CloudStorage") == true {
                    Text("Only cloud storage is on the list, so your project folders are not being scanned. Add them in Protection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var purgeResultCard: some View {
        if let result = store.purgeResult {
            GlassCard(tint: result.isIncomplete ? .moleWarn : .moleGood) {
                HStack(spacing: 16) {
                    ResultBurst(style: result.isIncomplete ? .warning : .success, theme: theme, size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.nothingRemoved ? "No artifacts were removed" : result.isIncomplete ? "Purge incomplete" : "Purge complete")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        if let amount = result.amount {
                            Text("\(ByteFormat.parse(amount).map { ByteFormat.string($0) } ?? amount) freed\(result.items.map { " from \($0) artifacts" } ?? "")\(result.freeSpace.map { " · \($0) free" } ?? "")")
                                .foregroundStyle(.secondary)
                        }
                        if result.isIncomplete {
                            Text("Some artifacts were skipped or could not be processed.").font(.callout).foregroundStyle(Color.moleWarn)
                        }
                        ForEach(store.purgeErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Done") { store.dismissResult() }.buttonStyle(.glass)
                }
            }
        } else if !store.purgeErrors.isEmpty {
            ErrorBanner(message: store.purgeErrors.joined(separator: "\n"))
        }
    }

    private func listChangeCard(_ change: PurgeListChange) -> some View {
        GlassCard(tint: .moleWarn) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(Color.moleWarn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing was purged: the list changed").font(.headline)
                        Text("The final check found \(change.added.count) artifact\(change.added.count == 1 ? "" : "s") you hadn’t reviewed\(change.removedCount > 0 ? ", and \(change.removedCount) no longer eligible" : ""). The list below is up to date; review it and purge again if it looks right.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Dismiss") { withAnimation { store.dismissListChange() } }.buttonStyle(.glass)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(change.added.prefix(8)) { artifact in
                        PathSizeRow(path: artifact.displayPath, size: artifact.size,
                                    symbol: PurgeTypes.symbol(for: artifact.type), tint: .moleWarn)
                    }
                    if change.added.count > 8 {
                        Text("and \(change.added.count - 8) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
            }
        }
    }

    private var confirmSheet: some View {
        ConfirmSheet(theme: theme, title: "Purge \(store.purgeable.count) Artifact\(store.purgeable.count == 1 ? "" : "s")?",
                     message: "These folders are deleted permanently (Mole’s purge does not use the Trash). They can be rebuilt by your tools.",
                     confirmTitle: "Purge \(ByteFormat.string(store.purgeableBytes))",
                     onConfirm: {
                         confirming = false
                         Task { await store.purgeAll(service: service) }
                     },
                     onCancel: { confirming = false }) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.purgeableProjects) { project in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(project.name).font(.headline)
                                    Spacer()
                                    Text(ByteFormat.string(project.bytes)).font(.callout.weight(.semibold).monospacedDigit())
                                }
                                ForEach(project.artifacts) { artifact in
                                    PathSizeRow(path: artifact.displayPath, size: artifact.size,
                                                symbol: PurgeTypes.symbol(for: artifact.type), tint: theme.accent)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(minHeight: 120, maxHeight: 340)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
                Label("Right before purging, the list is checked again. If anything new would be removed, nothing is purged and you see what changed.",
                      systemImage: "checkmark.shield")
                    .font(.callout).foregroundStyle(.secondary)
                if store.cloudCount > 0 {
                    Label("\(store.cloudCount) cloud-storage artifact\(store.cloudCount == 1 ? " is" : "s are") listed by Mole but never removed.",
                          systemImage: "icloud")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !store.scan.failures.isEmpty {
                    Label("Mole couldn’t finish scanning \(store.scan.failures.count) folder\(store.scan.failures.count == 1 ? "" : "s"). If it can read \(store.scan.failures.count == 1 ? "it" : "them") during the purge, eligible artifacts there are removed too.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Color.moleWarn)
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Automation

    private func onAppear() async {
        let automation = model.automation
        store.reloadProtected()
        store.checkStaleness()
        guard automation.autorun && automation.route == .purge else {
            if store.phase == .idle { await store.runScan(service: service) }
            return
        }
        let started = Date()
        await store.runScan(service: service)
        let scan = store.scan
        let passed = store.phase == .ready && scan.sawTitle
        automation.record("purge", passed: passed,
                          detail: passed ? "\(scan.artifacts.count) artifacts, \(scan.failures.count) failed roots" : "\(store.phase)",
                          metrics: ["artifacts": "\(scan.artifacts.count)", "projects": "\(store.projects.count)",
                                    "bytes": "\(store.totalBytes)", "failedRoots": scan.failures.map(\.root).joined(separator: ","),
                                    "summary": scan.summary?.heading ?? "",
                                    "seconds": String(format: "%.1f", Date().timeIntervalSince(started))])
        // Optional check of Protect: whitelist the smallest artifact, rescan (dry run), verify Mole skips it,
        // then restore the whitelist exactly as it was.
        if passed, UserDefaults.standard.bool(forKey: "MoleE2EDryRunProtocol") {
            let check = await store.automationProtectCheck(service: service)
            automation.record("purge-protect", passed: check.passed, detail: check.detail, metrics: check.metrics)
        }
    }
}

/// Wrapping horizontal layout for chips.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
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
