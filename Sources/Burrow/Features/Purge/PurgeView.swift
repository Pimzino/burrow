import AppKit
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
                    Button {
                        Task { await store.runScan(service: service) }
                    } label: {
                        Label(store.scannedAt == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.soft)
                    .fixedSize()
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isBusy)
                    .help("Preview what Mole would purge (⌘R)")
                    if store.phase == .ready && !store.artifacts.isEmpty {
                        Button {
                            confirming = true
                        } label: {
                            Label("Purge…", systemImage: "hammer.fill").fixedSize()
                        }
                        .buttonStyle(.hero(theme))
                        .fixedSize()
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(!store.canPurge)
                        .help(store.staleReason ?? (store.purgeable.isEmpty ? "Nothing Mole would remove" : "Review and remove every eligible artifact (⌘⌫)"))
                    }
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
                    Button("Stop") { store.cancelScan() }.buttonStyle(.soft)
                }
                .padding(.bottom, 12)
            }
        case .verifying:
            GlassCard {
                VStack(spacing: 6) {
                    ScanningView(theme: theme, title: "Checking the list one last time",
                                 detail: "Mole purges whatever is eligible when it runs, so the app confirms nothing new has appeared since you reviewed it.")
                    Button("Stop") { store.cancelVerify() }.buttonStyle(.soft)
                }
                .padding(.bottom, 12)
            }
        case .purging:
            FlowProgressCard(theme: theme, title: "Purging project artifacts…",
                             detail: "Mole removes each eligible folder and re-checks it just before deleting. This can take a minute.",
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
        @Bindable var store = store
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
                    Toggle("Include empty folders", isOn: $store.includeEmpty)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(store.isBusy)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
        } else {
            overview
            projectList
        }
        recentNote
        protectedSection
        scanLocations
    }

    private var overview: some View {
        let types = Array(store.byType.prefix(6))
        let maxBytes = max(1, types.map(\.bytes).max() ?? 1)
        return GlassCard(padding: 28) {
            HStack(alignment: .center, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reclaimable").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text(ByteFormat.string(store.totalBytes))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize()
                    Text("\(store.artifacts.count) artifacts in \(store.projects.count) projects")
                        .foregroundStyle(.secondary)
                    if let unmeasured = store.scan.summary?.unmeasured, unmeasured > 0 {
                        Text("+ \(unmeasured) unmeasured").font(.caption).foregroundStyle(.secondary)
                    }
                    if store.cloudCount > 0 {
                        Label("\(store.cloudCount) in cloud storage \(store.cloudCount == 1 ? "is" : "are") skipped", systemImage: "icloud")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .layoutPriority(1)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(types, id: \.type) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: PurgeTypes.symbol(for: entry.type))
                                .foregroundStyle(theme.accent)
                                .frame(width: 18)
                            Text(entry.type).font(.callout).lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                            CapsuleBar(fraction: Double(entry.bytes) / Double(maxBytes), tint: theme.accent, height: 6)
                            Text(ByteFormat.string(entry.bytes))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Reclaimable space by artifact type")
            }
        }
    }

    /// Every project with something to purge, largest first, in one list.
    private var projectList: some View {
        @Bindable var store = store
        return GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Projects").font(.headline)
                    Spacer()
                    Text("\(store.projects.count) · largest first").font(.subheadline).foregroundStyle(.secondary)
                    Toggle("Include empty folders", isOn: $store.includeEmpty)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.subheadline)
                        .fixedSize()
                        .disabled(store.isBusy)
                        .padding(.leading, 12)
                        .help("Also list artifact folders that are empty, on the next scan")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                ForEach(store.projects.sorted { $0.bytes > $1.bytes }) { project in
                    Divider().opacity(0.5)
                    projectRow(project)
                }
            }
        }
    }

    private func projectRow(_ project: PurgeProject) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 32, height: 32)
                .background(theme.accent.opacity(0.16), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(project.displayPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 220, alignment: .leading)
            ChipFlowLayout(spacing: 6) {
                ForEach(project.artifacts) { artifact in artifactChip(artifact) }
            }
            Text(ByteFormat.string(project.bytes))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(MoleHomeDir.expand(project.displayPath)) }
            Button("Copy Path", systemImage: "doc.on.doc") { copy(MoleHomeDir.expand(project.displayPath)) }
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
                Text(artifact.type).font(.caption.weight(.medium))
                Text(ByteFormat.parse(artifact.size).map { ByteFormat.string($0) } ?? artifact.size)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if artifact.isCloud { Image(systemName: "icloud").foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(isProtected ? AnyShapeStyle(Color.moleGood.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .capsule)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(isProtected ? "\(artifact.displayPath) is protected" : artifact.displayPath)
        .accessibilityLabel("\(artifact.type), \(artifact.size)\(isProtected ? ", protected" : "")")
    }

    private var recentNote: some View {
        Footnote(symbol: "clock", text: "Projects you changed in the last 7 days are skipped, so you won't lose the build you're working on.")
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
                                .buttonStyle(.soft).controlSize(.small)
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
                        .buttonStyle(.soft)
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
                    Button("Done") { store.dismissResult() }.buttonStyle(.soft)
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
                    Button("Dismiss") { withAnimation { store.dismissListChange() } }.buttonStyle(.soft)
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
