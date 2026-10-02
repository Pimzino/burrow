import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(selection: $model.route)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            Group {
                if service.isLocating {
                    ScanningView(theme: .dashboard, title: "Looking for Mole…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { AmbientBackground(theme: .dashboard) }
                } else if !service.isAvailable {
                    OnboardingView()
                } else {
                    detail(for: model.route)
                        .id(model.route)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: model.route)
        }
        .task {
            // E2E: open the Settings window so its tabs can be captured.
            if UserDefaults.standard.bool(forKey: "MoleE2EOpenSettings") {
                try? await Task.sleep(for: .seconds(1.5))
                openSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    @ViewBuilder
    private func detail(for route: Route) -> some View {
        switch route {
        case .dashboard: DashboardView()
        case .clean: CleanView()
        case .uninstall: UninstallView()
        case .optimize: OptimizeView()
        case .analyze: AnalyzeView()
        case .purge: PurgeView()
        case .installers: InstallersView()
        case .history: HistoryView()
        case .protection: ProtectionView()
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: Route
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let v = $0 { selection = v } })) {
            Section {
                row(.dashboard)
            }
            Section("Clean Up") {
                row(.clean)
                row(.uninstall)
                row(.purge)
                row(.installers)
            }
            Section("Maintain") {
                row(.optimize)
                row(.analyze)
            }
            Section("Records") {
                row(.history)
                row(.protection)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func row(_ route: Route) -> some View {
        Label {
            HStack {
                Text(route.theme.title)
                Spacer()
                if route == .dashboard, let score = model.status.snapshot?.healthScore {
                    Text("\(score)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.health(score))
                }
            }
        } icon: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(route.theme.gradient)
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: route.theme.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
        }
        .tag(route)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if service.runningCount > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("\(service.runningCount) task\(service.runningCount == 1 ? "" : "s") running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let update = model.availableUpdate {
                SettingsLink {
                    Label("Mole \(update) available", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(service.isAvailable ? Color.moleGood : Color.moleBad)
                    .frame(width: 7, height: 7)
                Text(service.installation.map { "Mole \($0.version)" } ?? "Mole not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Shown when the Mole CLI cannot be found.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @State private var install: CommandRun?
    @State private var installLines: [OutputLine] = []
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                FeatureIcon(theme: .clean, size: 96)
                    .padding(.top, 50)
                VStack(spacing: 8) {
                    Text("Welcome to Burrow").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Burrow is a beautiful home for the open-source Mole CLI. Install Mole to get started.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Install with Homebrew", systemImage: "terminal").font(.headline)
                        Text("brew install mole")
                            .font(.system(.body, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.2), in: .rect(cornerRadius: 10))
                            .textSelection(.enabled)
                        HStack {
                            Button(running ? "Installing…" : "Install Now") { installWithBrew() }
                                .buttonStyle(.hero(.clean))
                                .disabled(running || brewPath == nil)
                            Button("Check Again") { Task { await model.relocate() } }
                                .buttonStyle(.glass)
                            Spacer()
                            Link("Mole on GitHub", destination: URL(string: "https://github.com/tw93/mole")!)
                        }
                        if brewPath == nil {
                            Text("Homebrew was not found. Install it from brew.sh, or use Mole's install script.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !installLines.isEmpty {
                            ConsoleView(lines: installLines, maxHeight: 200)
                        }
                    }
                }
                .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity)
            .padding(Metrics.pagePadding)
        }
        .background { AmbientBackground(theme: .clean) }
    }

    private var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func installWithBrew() {
        guard let brewPath else { return }
        running = true
        installLines = []
        Task {
            do {
                let process = try Subprocess(executable: brewPath, arguments: ["install", "mole"],
                                             environment: MoleLocator.environment(), stdinOpen: false)
                for await event in process.events {
                    if case .line(let line) = event { installLines.append(line) }
                }
            } catch {
                installLines.append(OutputLine(id: -1, stream: .stderr, raw: error.localizedDescription))
            }
            running = false
            await model.relocate()
        }
    }
}
