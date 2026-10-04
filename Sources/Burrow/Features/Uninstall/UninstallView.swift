import AppKit
import SwiftUI

struct UninstallView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service

    @State private var store = UninstallStore.shared
    @State private var search = ""
    @State private var sort: SortKey = .size
    @State private var ascending = false
    @State private var sourceFilter: AppSource? = nil
    @State private var selection: Set<String> = []
    @State private var permanent = false
    @State private var showReview = false
    @AppStorage("uninstall.viewMode") private var viewMode: ViewMode = .grid

    private let theme = FeatureTheme.uninstall

    enum SortKey: String, CaseIterable, Identifiable {
        case name, size, lastUsed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: "Name"
            case .size: "Size"
            case .lastUsed: "Last Used"
            }
        }
    }

    enum ViewMode: String { case grid, list }

    /// The active or last uninstall. It lives in the store, so it survives leaving the page.
    private var session: UninstallSession? { store.session }
    private var sessionActive: Bool { store.hasActiveSession }

    var body: some View {
        FeaturePage(theme: theme) {
            header
        } content: {
            if let session, session.phase != .cancelled {
                UninstallSessionCard(session: session, theme: theme) {
                    withAnimation(.smooth) { store.dismissSession() }
                } showReview: {
                    showReview = true
                } openClean: {
                    model.route = .clean
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty && !sessionActive {
                selectionBar
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: selection.isEmpty)
        .animation(.smooth, value: session?.phase)
        .sheet(isPresented: $showReview) {
            if let session {
                UninstallReviewSheet(session: session, theme: theme) {
                    showReview = false
                    session.confirm()
                } onCancel: {
                    showReview = false
                    session.cancel()
                }
                .interactiveDismissDisabled()
            }
        }
        .onChange(of: session?.phase) { old, phase in
            showReview = phase == .review
            if phase == .finished, old != .finished, session?.dryRun == false {
                selection.removeAll()
            }
        }
        .onAppear {
            store.pageVisible = true
            // A review that became ready while the page was away is shown again.
            showReview = session?.phase == .review
        }
        .onDisappear {
            store.pageVisible = false
            // Leaving the page while the review is open is an explicit abandonment: tell Mole to
            // cancel rather than leave it waiting at a prompt where EOF would confirm. A run still
            // matching or scanning keeps going; its review is shown when the page is back.
            if session?.phase == .review { session?.cancel() }
        }
        .task { await onAppear() }
        .onKeyPress(.escape) {
            guard !selection.isEmpty, !sessionActive else { return .ignored }
            selection.removeAll()
            return .handled
        }
    }

    // MARK: Header

    private var header: some View {
        PageHeader(theme: theme, subtitle: subtitle) {
            HStack(spacing: 10) {
                if store.isLoading && store.hasLoaded || store.isRefreshingSizes {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(store.isRefreshingSizes ? "Updating sizes…" : "Refreshing…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
                Picker("View", selection: $viewMode) {
                    Image(systemName: "square.grid.2x2").tag(ViewMode.grid).accessibilityLabel("Grid")
                    Image(systemName: "list.bullet").tag(ViewMode.list).accessibilityLabel("List")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
                .help("Switch between grid and list")
                Button {
                    Task { await store.load(service: service) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.soft)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isLoading || (session?.isActive ?? false))
                .help("Reload the app list (⌘R)")
            }
        }
    }

    private var subtitle: String {
        if !store.hasLoaded { return store.isLoading ? "Looking for installed apps…" : theme.subtitle }
        return "\(store.apps.count) apps · \(ByteFormat.string(store.totalBytes)) on disk"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let error = store.error, !store.hasLoaded {
            ErrorBanner(message: error) { Task { await store.load(service: service) } }
        } else if !store.hasLoaded {
            loadingState
        } else {
            if let error = store.error {
                ErrorBanner(message: error) { Task { await store.load(service: service) } }
            }
            controls
            let apps = filteredApps
            if apps.isEmpty {
                GlassCard {
                    EmptyStateView(symbol: search.isEmpty ? "app.dashed" : "magnifyingglass",
                                   title: search.isEmpty ? "No apps here" : "No apps match “\(search)”",
                                   message: search.isEmpty ? "Try another source filter." : "Check the spelling or clear the search.")
                }
            } else if viewMode == .grid {
                grid(apps)
            } else {
                list(apps)
            }
            Footnote(symbol: "info.circle", text: "Already dragged an app to the Trash? Clean finds the files it left behind.",
                     actionTitle: "Open Clean") { model.route = .clean }
                .padding(.bottom, selection.isEmpty ? 0 : 70)
        }
    }

    private var loadingState: some View {
        VStack(spacing: Metrics.spacing) {
            GlassCard {
                ScanningView(theme: theme, title: "Finding your apps",
                             detail: "Reading bundles, sizes and last-used dates. The first scan takes about 30 seconds.")
            }
            SkeletonGrid()
        }
    }

    private var stats: some View {
        let unused = store.apps.filter { ($0.lastUsed.map { Date().timeIntervalSince($0) > 90 * 86_400 }) ?? false }
        let unusedBytes = unused.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let largest = store.apps.max { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }
        let brew = store.apps.filter { $0.source == .homebrew }.count
        return HStack(spacing: 14) {
            StatTile(title: "Installed", value: "\(store.apps.count)", detail: "\(brew) from Homebrew",
                     symbol: "square.grid.3x3.fill", tint: theme.accent)
            StatTile(title: "Total Size", value: ByteFormat.string(store.totalBytes), detail: "Across all app bundles",
                     symbol: "externaldrive.fill", tint: theme.colors[1])
            StatTile(title: "Unused 90+ Days", value: "\(unused.count)",
                     detail: unused.isEmpty ? "Everything is in use" : "\(ByteFormat.string(unusedBytes)) you may not need",
                     symbol: "moon.zzz.fill", tint: .purple)
            StatTile(title: "Largest", value: largest?.sizeText ?? "—", detail: largest?.name ?? "",
                     symbol: "arrow.up.right.square.fill", tint: .orange)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search apps")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minWidth: 160, maxWidth: 260)
            .glassEffect(.regular, in: .capsule)

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    filterChip(nil, title: "All", symbol: "square.grid.2x2", count: store.apps.count)
                    ForEach(AppSource.allCases) { source in
                        let count = store.apps.filter { $0.source == source }.count
                        if count > 0 || source == .app {
                            filterChip(source, title: source.title, symbol: source.symbol, count: count)
                        }
                    }
                }
            }
            .fixedSize()

            Spacer(minLength: 8)

            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Reverse Order", isOn: $ascending)
                Divider()
                Button("Select All Shown") { selection.formUnion(filteredApps.map(\.id)) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Deselect All") { selection.removeAll() }
            } label: {
                Label("Sort: \(sort.title)", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(.soft)
            .fixedSize()
        }
    }

    private func filterChip(_ source: AppSource?, title: String, symbol: String, count: Int) -> some View {
        let active = sourceFilter == source
        return Button {
            withAnimation(.snappy) { sourceFilter = source }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption)
                Text(title)
                Text("\(count)").foregroundStyle(active ? .white.opacity(0.8) : .secondary).monospacedDigit()
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(active ? .white : .primary)
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .glassEffect(active ? .regular.tint(theme.accent.opacity(0.85)).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var filteredApps: [AppEntry] {
        var apps = store.apps
        if let sourceFilter { apps = apps.filter { $0.source == sourceFilter } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            apps = apps.filter {
                $0.name.localizedCaseInsensitiveContains(q) || $0.app.bundleId.localizedCaseInsensitiveContains(q)
                    || $0.app.matchName.localizedCaseInsensitiveContains(q)
            }
        }
        // Natural order: name A→Z, size largest first, last used most recent first.
        func natural(_ a: AppEntry, _ b: AppEntry) -> Bool {
            switch sort {
            case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: (a.sizeBytes ?? -1) > (b.sizeBytes ?? -1)
            case .lastUsed: (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast)
            }
        }
        apps.sort { ascending ? natural($1, $0) : natural($0, $1) }
        return apps
    }

    private var maxBytes: Int64 { max(1, store.apps.map { $0.sizeBytes ?? 0 }.max() ?? 1) }

    private func grid(_ apps: [AppEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 200), spacing: 14)], spacing: 14) {
            ForEach(apps) { app in
                AppGridCard(app: app, selected: selection.contains(app.id), theme: theme) {
                    toggle(app)
                }
                .contextMenu { contextMenu(for: app) }
            }
        }
        .disabled(session?.isActive ?? false)
    }

    private func list(_ apps: [AppEntry]) -> some View {
        GlassCard(padding: 8) {
            LazyVStack(spacing: 2) {
                ForEach(apps) { app in
                    AppListRow(app: app, selected: selection.contains(app.id), fraction: Double(app.sizeBytes ?? 0) / Double(maxBytes), theme: theme) {
                        toggle(app)
                    }
                    .contextMenu { contextMenu(for: app) }
                }
            }
        }
        .disabled(session?.isActive ?? false)
    }

    @ViewBuilder
    private func contextMenu(for app: AppEntry) -> some View {
        Button(selection.contains(app.id) ? "Deselect" : "Select", systemImage: selection.contains(app.id) ? "circle" : "checkmark.circle") { toggle(app) }
        Divider()
        Button("Uninstall “\(app.name)”…", systemImage: "trash") { begin([app], dryRun: false) }
        Button("Preview Uninstall", systemImage: "eye") { begin([app], dryRun: true) }
        Divider()
        Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(app.app.path) }
        Button("Copy Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.app.path, forType: .string)
        }
        if app.app.bundleId != "unknown" {
            Button("Copy Bundle ID", systemImage: "number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.app.bundleId, forType: .string)
            }
        }
    }

    private func toggle(_ app: AppEntry) {
        withAnimation(.snappy(duration: 0.2)) {
            if selection.contains(app.id) { selection.remove(app.id) } else { selection.insert(app.id) }
        }
    }

    // MARK: Selection bar

    private var selectedApps: [AppEntry] { store.apps.filter { selection.contains($0.id) } }

    private var selectionBar: some View {
        let apps = selectedApps
        let bytes = apps.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        return HStack(spacing: 14) {
            HStack(spacing: -10) {
                ForEach(apps.prefix(4)) { app in
                    FileIconView(path: app.app.path, size: 30)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(apps.count) selected")
                    .font(.headline)
                    .contentTransition(.numericText())
                Text(ByteFormat.string(bytes))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .animation(.snappy, value: apps.count)
            Button("Clear", systemImage: "xmark") { selection.removeAll() }
                .labelStyle(.iconOnly)
                .buttonStyle(.soft)
                .help("Clear selection (Esc)")
            Divider().frame(height: 26)
            Toggle(isOn: $permanent) {
                Text("Skip Trash")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .help("Delete permanently instead of moving to the Trash. Files cannot be recovered.")
            Button("Preview", systemImage: "eye") { begin(apps, dryRun: true) }
                .buttonStyle(.soft)
                .help("Run Mole in dry-run mode: see every file, remove nothing")
            Button {
                begin(apps, dryRun: false)
            } label: {
                Label("Uninstall", systemImage: "trash.fill")
                    .fixedSize()
            }
            .buttonStyle(.hero(theme))
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Uninstall the selected apps (⌘⌫)")
        }
        .fixedSize()
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
    }

    // MARK: Flow

    private func begin(_ apps: [AppEntry], dryRun: Bool, autoConfirm: Duration? = nil) {
        guard !apps.isEmpty, !sessionActive else { return }
        let automation = model.automation
        withAnimation(.smooth) {
            _ = store.begin(apps, dryRun: dryRun, permanent: permanent, service: service, autoConfirm: autoConfirm,
                            onFinish: autoConfirm == nil ? nil : { session in Self.recordProtocol(session, automation: automation) })
        }
    }

    private func onAppear() async {
        let automation = model.automation
        let automate = automation.autorun && automation.route == .uninstall
        if automate {
            let started = Date()
            await store.load(service: service)
            let count = store.apps.count
            automation.record("uninstall", passed: count > 0 && store.error == nil,
                              detail: store.error ?? "Loaded \(count) apps",
                              metrics: ["apps": "\(count)",
                                        "seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
                                        "unknownSizes": "\(store.apps.filter { $0.sizeBytes == nil }.count)"])
            // Optional end-to-end check of the prompt protocol, always in dry-run mode.
            if UserDefaults.standard.bool(forKey: "MoleE2EDryRunProtocol") {
                let names = (UserDefaults.standard.string(forKey: "MoleE2EUninstallApps") ?? "VLC,LinearMouse")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                let picks = store.apps.filter { names.contains($0.app.matchName.lowercased()) || names.contains($0.name.lowercased()) }
                selection = Set(picks.map(\.id))
                let hold = UserDefaults.standard.double(forKey: "MoleE2EReviewHold")
                begin(picks, dryRun: true, autoConfirm: .seconds(hold > 0 ? hold : 4))
            }
        } else {
            await store.loadIfNeeded(service: service)
        }
    }

    private static func recordProtocol(_ session: UninstallSession, automation: Automation) {
        let p = session.parser
        let files = p.apps.reduce(0) { $0 + $1.files.count }
        let passed = session.phase == .finished && (p.summary?.isDryRun ?? false) && p.apps.count == session.apps.count
        automation.record("uninstall-protocol", passed: passed,
                                detail: p.summary?.details.joined(separator: " / ") ?? "\(session.phase)",
                                metrics: ["matched": "\(p.matched.count)", "previewApps": "\(p.apps.count)",
                                          "files": "\(files)", "heading": p.summary?.heading ?? "",
                                          "warnings": p.warnings.joined(separator: " | ")])
    }
}

// MARK: - Icons

/// App/file icon loaded from Finder, cached across views.
struct FileIconView: View {
    let path: String
    var size: CGFloat = 48

    var body: some View {
        Image(nsImage: FileIconCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
enum FileIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let image = Finder.icon(for: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

// MARK: - Grid card

private struct AppGridCard: View {
    let app: AppEntry
    let selected: Bool
    let theme: FeatureTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                FileIconView(path: app.app.path, size: 64)
                    .padding(.top, 6)
                Text(app.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(app.sizeText)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(app.sizeBytes == nil ? .secondary : .primary)
                    .contentTransition(.numericText())
                Text(lastUsedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.tertiary))
                    .opacity(selected || hovering ? 1 : 0)
                    .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if app.source != .app {
                    Image(systemName: app.source.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(sourceColor, in: .circle)
                        .padding(10)
                        .help(app.source.title)
                }
            }
            .contentShape(.rect(cornerRadius: Metrics.tileRadius))
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(theme.accent.opacity(0.22)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: Metrics.tileRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
                .strokeBorder(theme.gradient, lineWidth: selected ? 2 : 0)
        }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name), \(app.sizeText), \(lastUsedText), \(app.source.title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var lastUsedText: String {
        app.lastUsed.map { "Used " + RelativeAge.string($0).lowercased() } ?? "Last use unknown"
    }

    private var sourceColor: Color {
        switch app.source {
        case .homebrew: Color(red: 0.95, green: 0.62, blue: 0.18)
        case .appStore: .blue
        case .steam: Color(red: 0.12, green: 0.25, blue: 0.45)
        case .app: .gray
        }
    }
}

// MARK: - List row

private struct AppListRow: View {
    let app: AppEntry
    let selected: Bool
    let fraction: Double
    let theme: FeatureTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.tertiary))
                FileIconView(path: app.app.path, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(app.app.path.abbreviatingHome)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                Pill(text: app.source.title, symbol: app.source.symbol, tint: app.source == .homebrew ? .orange : app.source == .appStore ? .blue : .secondary)
                    .frame(width: 110, alignment: .leading)
                Text(app.lastUsed.map { RelativeAge.string($0) } ?? "Unknown")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(app.sizeText)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    CapsuleBar(fraction: fraction, tint: theme.accent, height: 4)
                        .frame(width: 90)
                }
                .frame(width: 100, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? theme.accent.opacity(0.14) : hovering ? Color.primary.opacity(0.05) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name), \(app.sizeText), \(app.source.title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Skeleton

private struct SkeletonGrid: View {
    @State private var phase = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 200), spacing: 14)], spacing: 14) {
            ForEach(0..<12, id: \.self) { i in
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary).frame(width: 60, height: 60)
                    Capsule().fill(.quaternary).frame(width: 90, height: 10)
                    Capsule().fill(.quaternary).frame(width: 60, height: 14)
                    Capsule().fill(.quaternary.opacity(0.6)).frame(width: 70, height: 8)
                }
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.tileRadius))
                .opacity(phase ? 0.45 : 1)
                .animation(.easeInOut(duration: 1.1).repeatForever().delay(Double(i % 6) * 0.12), value: phase)
            }
        }
        .onAppear { phase = true }
        .accessibilityHidden(true)
    }
}
