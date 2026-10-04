import AppKit
import SwiftUI

struct SettingsGeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @Environment(StatusMonitor.self) private var status
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var customPath = UserDefaults.standard.string(forKey: "moleLauncherPath") ?? ""
    @State private var relocating = false
    @AppStorage("menuBarMetric") private var menuBarMetric = "health"

    var body: some View {
        @Bindable var status = status
        Form {
            Section {
                SettingsPaneHeader(tab: .general, subtitle: "Where Mole lives, how Burrow talks to it, and how Burrow starts.")
            }

            Section("Mole CLI") {
                if let installation = service.installation {
                    LabeledContent("Version") {
                        HStack(spacing: 8) {
                            Text(installation.version).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            SettingsStatusPill(text: installation.isHomebrew ? "Homebrew" : "Manual install", on: true,
                                               onColor: installation.isHomebrew ? .orange : .blue)
                        }
                    }
                    SettingsFactRow(title: "Launcher", value: installation.launcher, monospaced: true, revealPath: installation.launcher)
                    SettingsFactRow(title: "Libraries", value: installation.libexec.abbreviatingHome, monospaced: true,
                                    revealPath: installation.libexec)
                } else {
                    Label(service.isLocating ? "Looking for Mole…" : "Mole was not found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(service.isLocating ? Color.secondary : Color.moleWarn)
                }
                LabeledContent("Custom launcher") {
                    HStack(spacing: 8) {
                        Text(customPath.isEmpty ? "Automatic" : customPath.abbreviatingHome)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if relocating { ProgressView().controlSize(.small) }
                        Button("Choose…", action: chooseLauncher)
                        if !customPath.isEmpty {
                            Button("Reset") { setLauncher("") }
                        }
                    }
                }
                Toggle(isOn: Binding(get: { service.debugLogging }, set: { value in
                    service.debugLogging = value
                    UserDefaults.standard.set(value, forKey: "moleDebugLogging")
                })) {
                    Text("Debug logging")
                    Text("Adds --debug to every command. Mole writes details to mole_debug_session.log.")
                }
            }

            Section("Live status") {
                Picker("Menu bar shows", selection: $menuBarMetric) {
                    Text("Health score").tag("health")
                    Text("CPU usage").tag("cpu")
                    Text("Icon only").tag("none")
                }
                Picker("Refresh every", selection: $status.interval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                LabeledContent("CPU alert threshold") {
                    HStack {
                        Slider(value: $status.cpuAlertThreshold, in: 25...400, step: 25).frame(width: 180)
                        Text("\(Int(status.cpuAlertThreshold))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                            .contentTransition(.numericText())
                    }
                }
                LabeledContent("Alert when sustained for") {
                    Stepper(value: $status.cpuAlertWindowMinutes, in: 1...60, step: 1) {
                        Text("\(Int(status.cpuAlertWindowMinutes)) min")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }

            Section("Startup and permissions") {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                    Text("Open Burrow at login")
                    if let loginError {
                        Text(loginError).foregroundStyle(Color.moleWarn)
                    } else {
                        Text("Keeps the menu bar monitor available after you sign in.")
                    }
                }
                LabeledContent {
                    if model.hasFullDiskAccess {
                        SettingsStatusPill(text: "Granted", on: true)
                    } else {
                        Button("Open Privacy Settings…") { FullDiskAccess.openSettings() }
                    }
                } label: {
                    Text("Full Disk Access")
                    Text("Lets Mole measure and clean protected folders such as Mail and Safari data.")
                }
                LabeledContent {
                    if model.setup.finderAutomation == .granted {
                        SettingsStatusPill(text: "Allowed", on: true)
                    } else {
                        Button("Automation Settings…") { FinderAutomation.openSettings() }
                    }
                } label: {
                    Text("Automation")
                    Text("Mole may ask to control Finder (to move items to the Trash) or System Events. You grant that to Burrow once, in System Settings › Privacy & Security › Automation.")
                }
                LabeledContent {
                    Button("Show Setup Again…") {
                        model.setup.restart(moleAvailable: service.isAvailable)
                        openWindow(id: "main")
                    }
                } label: {
                    Text("Setup")
                    Text("Walk through the welcome and permission steps again.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshPermissions()
            // Until AppModel restores it at launch, apply the saved preference whenever Settings opens.
            if let saved = UserDefaults.standard.object(forKey: "moleDebugLogging") as? Bool, saved != service.debugLogging {
                service.debugLogging = saved
            }
            launchAtLogin = LoginItem.isEnabled
        }
        .task { await model.setup.refreshFinderAutomation() }
    }

    private func chooseLauncher() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Use This Launcher"
        panel.message = "Choose the mo or mole launcher script"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            setLauncher(url.path)
        }
    }

    private func setLauncher(_ path: String) {
        customPath = path
        if path.isEmpty {
            UserDefaults.standard.removeObject(forKey: "moleLauncherPath")
        } else {
            UserDefaults.standard.set(path, forKey: "moleLauncherPath")
        }
        relocating = true
        Task {
            await model.relocate()
            relocating = false
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = LoginItem.set(enabled)
        launchAtLogin = LoginItem.isEnabled
    }
}
