import AppKit
import QuickLook
import SwiftUI

/// Actions shared by the treemap, the lists, context menus and the selection bar.
struct AnalyzeActions {
    var openFolder: (String) -> Void
    var select: (String) -> Void
    var reveal: (String) -> Void
    var openItem: (String) -> Void
    var quickLook: (String) -> Void
    var copyPath: (String) -> Void
    var trash: (_ path: String, _ size: Int64, _ isDir: Bool) -> Void
    var clean: () -> Void
}

struct AnalyzeView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @State private var analyzer = AnalyzeModel.shared
    @State private var trashRequest: AnalyzeTrashRequest?
    @State private var alertMessage: String?
    @State private var quickLookURL: URL?
    @State private var lastFolderOpen = Date.distantPast

    private let theme = FeatureTheme.analyze

    var body: some View {
        FeaturePage(theme: theme) {
            PageHeader(theme: theme, subtitle: subtitle) {
                headerControls
            }
        } content: {
            content
        }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .toolbar { toolbar }
        .sheet(item: $trashRequest) { request in
            AnalyzeTrashSheet(request: request, onConfirm: { performTrash(request) }, onCancel: { trashRequest = nil })
        }
        .alert("Can't Move to Trash", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .quickLookPreview($quickLookURL)
        .task { start() }
    }

    private var subtitle: String {
        switch analyzer.current {
        case .directory(let path): path.abbreviatingHome
        default: theme.subtitle
        }
    }

    // MARK: Header

    private var headerControls: some View {
        HStack(spacing: 8) {
            if analyzer.current != .overview && analyzer.current != nil {
                Button("Overview", systemImage: "chart.pie") { analyzer.showOverview(service: service) }
                    .buttonStyle(.soft)
                    .help("Back to the whole-Mac overview")
            }
            Button("Choose Folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                .buttonStyle(.soft)
                .keyboardShortcut("o", modifiers: .command)
            Button(action: { analyzer.rescan(service: service) }) {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.hero(theme))
            .keyboardShortcut("r", modifiers: .command)
            .disabled(analyzer.current == nil || analyzer.isScanning)
            .help(analyzer.current == .overview
                  ? "Clear Mole's cached sizes and measure everything again. This can take a few minutes."
                  : "Clear Mole's cache for this folder and scan it again")
        }
        .labelStyle(.titleAndIcon)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") { analyzer.goBack(service: service) }
                .disabled(!analyzer.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
            Button("Forward", systemImage: "chevron.forward") { analyzer.goForward(service: service) }
                .disabled(!analyzer.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")
            Button("Enclosing Folder", systemImage: "arrow.turn.left.up") { analyzer.goUp(service: service) }
                .disabled(analyzer.parentPath == nil)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Enclosing folder")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let scan = analyzer.scan {
            AnalyzeScanGate(scan: scan, hasContent: hasContent(for: scan.target), cancel: { analyzer.cancel() }) {
                loadedContent
            }
        } else if let error = analyzer.error {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                ErrorBanner(message: error) {
                    if let current = analyzer.current { analyzer.navigate(to: current, service: service, force: true) }
                }
                if analyzer.current != .overview {
                    Button("Back to Overview", systemImage: "chart.pie") { analyzer.showOverview(service: service) }
                        .buttonStyle(.soft)
                }
            }
        } else {
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let notice = analyzer.notice {
            InfoBanner(symbol: "trash.circle.fill", title: "Moved to Trash", message: notice, tint: .moleGood,
                       actionTitle: "Open Trash") { Finder.open("~/.Trash") }
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(8))
                    withAnimation(.smooth) { analyzer.notice = nil }
                }
        }
        switch analyzer.current {
        case .overview:
            if let overview = analyzer.overview {
                AnalyzeOverviewSection(report: overview, actions: actions)
            }
        case .directory:
            if let report = analyzer.report {
                AnalyzeDirectorySection(report: report, analyzer: analyzer, actions: actions)
                    .id(report.path)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
            }
        case nil:
            EmptyStateView(symbol: theme.symbol, title: "Ready to analyze", tint: theme.accent)
        }
    }

    private func hasContent(for target: AnalyzeModel.Target) -> Bool {
        switch target {
        case .overview: analyzer.overview != nil
        case .directory: analyzer.report != nil
        }
    }

    // MARK: Selection bar

    @ViewBuilder
    private var selectionBar: some View {
        // Only a selection that resolves to a real item in this report gets actions.
        if let path = analyzer.selection, analyzer.current != .overview,
           analyzer.selectedEntry != nil || analyzer.selectedLargeFile != nil {
            let entry = analyzer.selectedEntry
            let large = analyzer.selectedLargeFile
            let size = entry?.size ?? large?.size ?? 0
            // A symlink to a folder is trashed (and opened) as the link itself, never as a folder.
            let isDir = entry.map { $0.isDir && !$0.isSymlink } ?? false
            AnalyzeSelectionBar(path: path, size: size, isDir: isDir, actions: actions,
                                deselect: { withAnimation(.snappy) { analyzer.selection = nil } })
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Actions

    private var actions: AnalyzeActions {
        AnalyzeActions(
            openFolder: { path in
                // A double click on a folder tile must not drill two levels.
                guard Date().timeIntervalSince(lastFolderOpen) > 0.45 else { return }
                lastFolderOpen = Date()
                analyzer.open(path, service: service)
            },
            select: { path in withAnimation(.snappy) { analyzer.selection = analyzer.selection == path ? nil : path } },
            reveal: { Finder.reveal($0) },
            openItem: { Finder.open($0) },
            quickLook: { quickLookURL = URL(fileURLWithPath: $0) },
            copyPath: { path in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            trash: { path, size, isDir in requestTrash(path: path, size: size, isDir: isDir) },
            clean: { model.route = .clean })
    }

    private func requestTrash(path: String, size: Int64, isDir: Bool) {
        do {
            try AnalyzeTrashGuard.validate(path)
            trashRequest = AnalyzeTrashRequest(path: path, size: size, isDir: isDir)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func performTrash(_ request: AnalyzeTrashRequest) {
        trashRequest = nil
        Task {
            do {
                try await analyzer.trash(request.path, service: service)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyze"
        panel.message = "Choose a folder or volume to analyze"
        panel.directoryURL = URL(fileURLWithPath: analyzer.currentPath ?? NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            analyzer.open(url.standardizedFileURL.path, service: service)
        }
    }

    // MARK: Start and automation

    private func start() {
        let automation = model.automation
        let automate = automation.autorun && automation.route == .analyze && !analyzer.didAutorun
        if automate {
            analyzer.didAutorun = true
            analyzer.onFinish = { target, report, error, duration in
                guard analyzer.onFinish != nil else { return }
                analyzer.onFinish = nil
                var metrics: [String: String] = [
                    "mode": target == .overview ? "overview" : "directory",
                    "path": target.path ?? "/",
                    "seconds": String(format: "%.2f", duration),
                ]
                if let report {
                    metrics["entries"] = "\(report.entries.count)"
                    metrics["total"] = "\(report.totalSize)"
                    metrics["totalFormatted"] = ByteFormat.string(report.totalSize)
                    metrics["largeFiles"] = "\(report.largeFiles?.count ?? 0)"
                    metrics["totalFiles"] = "\(report.totalFiles ?? 0)"
                    metrics["xxh64Vectors"] = AnalyzeSelfCheck.xxhashVectorsPass ? "pass" : "fail"
                }
                let passed = report.map { !$0.entries.isEmpty } ?? false
                automation.record("analyze", passed: passed && AnalyzeSelfCheck.xxhashVectorsPass,
                                  detail: error ?? "Scanned \(target.path ?? "overview") with \(report?.entries.count ?? 0) entries",
                                  metrics: metrics)
            }
            // A specific folder can be requested for automated runs; otherwise the overview when its
            // sizes are cached (instant), else ~/Library.
            if let path = UserDefaults.standard.string(forKey: "MoleE2EAnalyzePath"), !path.isEmpty {
                analyzer.open(path.expandingTilde, service: service)
            } else if AnalyzerCache.overviewIsWarm() {
                analyzer.showOverview(service: service, force: true)
            } else {
                analyzer.open(NSHomeDirectory() + "/Library", service: service)
            }
            return
        }
        if analyzer.current == nil {
            analyzer.showOverview(service: service)
        }
    }
}

enum AnalyzeSelfCheck {
    static let xxhashVectorsPass: Bool =
        XXHash64.hash("") == 0xEF46_DB37_51D8_E999 &&
        XXHash64.hash("a") == 0xD24E_C4F1_A98C_6E5B &&
        XXHash64.hash("abc") == 0x44BC_2CF5_AD77_0999
}

// MARK: - Scanning state

/// Shows the scanning card for slow scans; quick (cached) scans keep the current content on screen
/// for a moment so drilling into folders doesn't flash.
private struct AnalyzeScanGate<Content: View>: View {
    let scan: AnalyzeModel.Scan
    let hasContent: Bool
    let cancel: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        TimelineView(.periodic(from: scan.startedAt, by: 0.5)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(scan.startedAt))
            if hasContent && scan.expectedFast && elapsed < 0.9 {
                content
                    .opacity(0.55)
                    .allowsHitTesting(false)
                    .overlay(alignment: .top) { ProgressView().controlSize(.small).padding(.top, 60) }
            } else {
                card(elapsed: elapsed)
            }
        }
    }

    private func card(elapsed: TimeInterval) -> some View {
        GlassCard(padding: 28) {
            VStack(spacing: 6) {
                ScanningView(theme: .analyze, title: title,
                             detail: Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)) + " elapsed")
                    .contentTransition(.numericText())
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                Button("Cancel", systemImage: "xmark", action: cancel)
                    .buttonStyle(.soft)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var title: String {
        switch scan.target {
        case .overview: "Measuring your Mac…"
        case .directory(let path): "Analyzing “\((path as NSString).lastPathComponent)”…"
        }
    }

    private var note: String {
        switch scan.target {
        case .overview where !scan.expectedFast:
            "The first full scan measures your home folder, libraries and apps, and can take two or three minutes. Mole caches the results, so later visits are instant."
        case .overview:
            "Reading Mole's cached sizes."
        case .directory:
            "Mole walks every file inside this folder. Large folders take longer the first time; after that Mole's cache makes them quick."
        }
    }
}

// MARK: - Selection bar

private struct AnalyzeSelectionBar: View {
    let path: String
    let size: Int64
    let isDir: Bool
    let actions: AnalyzeActions
    let deselect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Finder.icon(for: path))
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).font(.headline).lineLimit(1)
                Text("\(ByteFormat.string(size)) · \(((path as NSString).deletingLastPathComponent).abbreviatingHome)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 120, alignment: .leading)
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    iconButton("Reveal in Finder", "finder") { actions.reveal(path) }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    iconButton("Quick Look", "eye") { actions.quickLook(path) }
                        .keyboardShortcut(.space, modifiers: [])
                    iconButton(isDir ? "Analyze Folder" : "Open", isDir ? "arrow.down.forward.circle" : "arrow.up.forward.app") {
                        isDir ? actions.openFolder(path) : actions.openItem(path)
                    }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    iconButton("Copy Path", "doc.on.doc") { actions.copyPath(path) }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
            Button(role: .destructive) { actions.trash(path, size, isDir) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .buttonStyle(.hero(.analyze))
            .tint(Color.moleBad)
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Deselect", systemImage: "xmark", action: deselect)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Deselect (Esc)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.soft)
            .help(title)
    }
}

// MARK: - Context menu

struct AnalyzeItemMenu: View {
    let path: String
    let size: Int64
    let isDir: Bool
    let actions: AnalyzeActions
    var allowTrash = true

    var body: some View {
        if isDir {
            Button("Analyze Folder", systemImage: "chart.pie") { actions.openFolder(path) }
        } else {
            Button("Open", systemImage: "arrow.up.forward.app") { actions.openItem(path) }
        }
        Button("Reveal in Finder", systemImage: "finder") { actions.reveal(path) }
        Button("Quick Look", systemImage: "eye") { actions.quickLook(path) }
        Button("Copy Path", systemImage: "doc.on.doc") { actions.copyPath(path) }
        if allowTrash {
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { actions.trash(path, size, isDir) }
        }
    }
}

// MARK: - Trash confirmation

struct AnalyzeTrashRequest: Identifiable {
    let path: String
    let size: Int64
    let isDir: Bool
    var id: String { path }
}

private struct AnalyzeTrashSheet: View {
    let request: AnalyzeTrashRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ConfirmSheet(theme: .uninstall, title: "Move to Trash?",
                     message: "“\((request.path as NSString).lastPathComponent)” will be moved to the Trash.",
                     confirmTitle: "Move to Trash", onConfirm: onConfirm, onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: Finder.icon(for: request.path))
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((request.path as NSString).lastPathComponent).font(.headline)
                        Text(request.path.abbreviatingHome)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteFormat.string(request.size))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                Label(request.isDir
                      ? "The folder and everything inside it go to the Trash. You can put them back until you empty the Trash."
                      : "You can put it back from the Trash until you empty it.",
                      systemImage: "arrow.uturn.backward.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("Space is freed when the Trash is emptied.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
