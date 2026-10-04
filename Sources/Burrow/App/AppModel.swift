import AppKit
import Foundation
import Observation
import SwiftUI

enum Route: String, CaseIterable, Identifiable, Hashable {
    case dashboard, clean, uninstall, optimize, analyze, purge, installers, history, protection

    var id: String { rawValue }

    var theme: FeatureTheme {
        switch self {
        case .dashboard: .dashboard
        case .clean: .clean
        case .uninstall: .uninstall
        case .optimize: .optimize
        case .analyze: .analyze
        case .purge: .purge
        case .installers: .installers
        case .history: .history
        case .protection: .protection
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let service = MoleService()
    let status = StatusMonitor()
    let automation: Automation
    let updater = AppUpdater()
    let setup: SetupModel
    var route: Route = .dashboard
    /// Set when a newer Mole release is available ("1.56.1").
    var availableUpdate: String?
    var hasFullDiskAccess = FullDiskAccess.isGranted
    /// Full Disk Access was turned on while Burrow was running: Mole's processes already have it,
    /// Burrow itself gets it the next time it opens.
    var fullDiskAccessNeedsRelaunch = false

    @ObservationIgnored private var bootstrapped = false

    init() {
        let automation = Automation()
        self.automation = automation
        setup = SetupModel(automationActive: automation.isActive)
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        if let route = automation.route { self.route = route }
        if automation.isActive { NSApp.activate() }
        // Screenshots: force light or dark appearance (`-BurrowAppearance light|dark`).
        switch UserDefaults.standard.string(forKey: "BurrowAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        service.debugLogging = UserDefaults.standard.bool(forKey: "moleDebugLogging")
        // Mole's processes run in their own sessions, so stop them explicitly when the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.service.killAllRuns()
                self?.status.stop()
            }
        }
        updater.hasRunningTasks = { [service] in service.runningCount > 0 }
        // Screen-by-screen E2E runs must not hit the network for Burrow updates (scripts/update-e2e.sh opts in).
        let updateE2E = UserDefaults.standard.string(forKey: "BurrowUpdateE2E")
        updater.start(automatic: !automation.isActive && updateE2E == nil)
        if let updateE2E { Task { await runUpdateE2E(updateE2E) } }

        await service.locate(preferred: UserDefaults.standard.string(forKey: "moleLauncherPath"))
        await setup.resolve(moleAvailable: service.isAvailable, fullDiskAccess: hasFullDiskAccess)
        startStatus()
        if service.isAvailable { Task { await checkForUpdate() } }
    }

    /// Live status asks Finder for disk figures, which makes macOS show its "control Finder" prompt.
    /// It waits until setup has explained that, so the prompt never appears out of the blue.
    private func startStatus() {
        guard !setup.isActive, let installation = service.installation else { return }
        status.start(installation: installation)
    }

    func finishSetup() {
        setup.finish()
        refreshPermissions()
        startStatus()
    }

    /// `-BurrowUpdateE2E check|install` (scripts/update-e2e.sh): checks the feed, shows the Software Update
    /// window, and with `install` downloads, verifies and installs the offered release, then relaunches.
    /// Each outcome is recorded as `update-check` / `update-install` in the automation report directory.
    private func runUpdateE2E(_ mode: String) async {
        await updater.check(userInitiated: true)
        var metrics = ["current": updater.currentVersion?.description ?? "none"]
        switch updater.phase {
        case .available(let release):
            metrics["offered"] = release.version.description
            metrics["installBlocker"] = updater.blocker(for: release) ?? "none"
            if !UserDefaults.standard.bool(forKey: "MoleE2EOpenSettings") { updater.prompt = release }
            automation.record("update-check", passed: true, detail: "Offered \(release.version)", metrics: metrics)
        case .upToDate:
            automation.record("update-check", passed: true, detail: "Up to date", metrics: metrics)
        case .failed(let message, _):
            automation.record("update-check", passed: false, detail: message, metrics: metrics)
        default:
            automation.record("update-check", passed: false, detail: "Unexpected state \(updater.phase)", metrics: metrics)
        }
        guard mode == "install", case .available(let release) = updater.phase else { return }
        // Let the window be captured in its "available" state.
        let delay = UserDefaults.standard.double(forKey: "BurrowUpdateE2EInstallDelay")
        try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2))
        updater.install(release) { [automation] installed in
            automation.record("update-install", passed: true, detail: "Installed \(release.version) at \(installed.path)",
                              metrics: metrics.merging(["installed": installed.path]) { $1 })
        }
        while updater.phase.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
        if case .failed(let message, _) = updater.phase {
            automation.record("update-install", passed: false, detail: message, metrics: metrics)
        }
    }

    func relocate() async {
        await service.locate(preferred: UserDefaults.standard.string(forKey: "moleLauncherPath"))
        startStatus()
    }

    func refreshPermissions() {
        hasFullDiskAccess = FullDiskAccess.isGranted
        if hasFullDiskAccess { fullDiskAccessNeedsRelaunch = false }
    }

    /// Also asks a fresh process, which sees a grant made since Burrow launched.
    func refreshPermissionsFromChild() async {
        refreshPermissions()
        guard !hasFullDiskAccess else { return }
        fullDiskAccessNeedsRelaunch = await FullDiskAccess.isGrantedToNewProcesses()
    }

    /// Quits and reopens Burrow so a newly granted permission applies to the app itself.
    func relaunch() {
        guard Bundle.main.bundleIdentifier != nil,
              (try? UpdateInstaller.scheduleRelaunch(of: Bundle.main.bundleURL)) != nil else { return }
        NSApp.terminate(nil)
    }

    /// Mirrors Mole's own update check: Homebrew's view for brew installs, GitHub's latest release otherwise.
    func checkForUpdate() async {
        guard let installation = service.installation else { return }
        var latest: String?
        if installation.isHomebrew, FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/brew") {
            let brew = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
            if let result = try? await Subprocess.run(brew, ["outdated", "--formula", "--verbose", "mole"],
                                                      environment: MoleLocator.environment(), timeout: 60),
               let match = result.stdoutString.firstMatch(of: /<\s*([0-9][0-9A-Za-z.\-]*)/) {
                latest = String(match.1)
            }
        } else {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/tw93/mole/releases/latest")!)
            request.timeoutInterval = 8
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = object["tag_name"] as? String {
                let version = tag.hasPrefix("V") || tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if version.compare(installation.version, options: .numeric) == .orderedDescending { latest = version }
            }
        }
        availableUpdate = latest
    }
}

enum FullDiskAccess {
    /// A folder only readable with Full Disk Access (the same ones Mole probes), falling back to the
    /// TCC-protected Trash.
    private static var probePath: String {
        let home = NSHomeDirectory()
        return ["/Library/Safari", "/Library/Mail", "/Library/Messages"].map { home + $0 }
            .first { FileManager.default.fileExists(atPath: $0) } ?? home + "/.Trash"
    }

    /// Reading the folder also makes macOS list Burrow under Full Disk Access, ready to be switched on.
    static var isGranted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: probePath)) != nil
    }

    /// A running app keeps the answer it had at launch; a process started now gets the current one.
    /// Mole always runs in fresh processes, so this is what its scans will see.
    static func isGrantedToNewProcesses() async -> Bool {
        let result = try? await Subprocess.run("/bin/ls", [probePath], environment: [:], timeout: 5)
        return result?.exitCode == 0
    }

    static func openSettings() { PrivacySettings.open("Privacy_AllFiles") }
}

/// Deep links into System Settings › Privacy & Security (pane and anchors checked on macOS 26.6).
enum PrivacySettings {
    static func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")!)
    }
}
