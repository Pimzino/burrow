import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.setup.presentation {
            case .pending: AmbientBackground(theme: .setup)
            case .shown: SetupView().transition(.opacity)
            case .hidden: mainInterface.transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: model.setup.presentation)
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
        .onChange(of: model.updater.prompt, initial: true) { _, release in
            guard release != nil else { return }
            model.updater.prompt = nil
            openWindow(id: UpdateWindow.id)
        }
    }

    private var mainInterface: some View {
        @Bindable var model = model
        return NavigationSplitView {
            Sidebar(selection: $model.route)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            Group {
                if service.isLocating {
                    ScanningView(theme: .dashboard, title: "Looking for Mole…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { AmbientBackground(theme: .dashboard) }
                } else if !service.isAvailable {
                    MoleMissingView()
                } else {
                    detail(for: model.route)
                        .id(model.route)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: model.route)
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
    @Environment(\.openWindow) private var openWindow
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
            if let release = model.updater.newer {
                Button {
                    openWindow(id: UpdateWindow.id)
                } label: {
                    Label("Burrow \(release.version.description) available", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
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
