import AppKit
import SwiftUI

@main
enum Entry {
    nonisolated(unsafe) static var termSource: DispatchSourceSignal?

    static func main() {
        let args = CommandLine.arguments
        if PrivilegedHelper.isHelperInvocation(args) {
            PrivilegedHelper.run(args)
        }
        Subprocess.orphanGuardExecutable = Bundle.main.executablePath
        // A plain `kill` (SIGTERM) skips applicationWillTerminate; route it through a normal quit so
        // running tasks are stopped. (The helper's parent watch covers crashes and SIGKILL.)
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { exit(0) }
        term.resume()
        Entry.termSource = term
        MoleApp.main()
    }
}

struct MoleApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Burrow", id: "main") {
            RootView()
                .environment(model)
                .environment(model.service)
                .environment(model.status)
                .frame(minWidth: 980, minHeight: 660)
                .task {
                    delegate.model = model
                    await model.bootstrap()
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 820)
        .commands { AppCommands(model: model) }

        Window("Software Update", id: UpdateWindow.id) {
            UpdateWindow()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .environment(model.service)
                .environment(model.status)
        } label: {
            MenuBarLabel(status: model.status)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.service)
                .environment(model.status)
                .frame(width: 620, height: 560)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting while Mole is working would interrupt it mid-way, so ask first, then stop tasks
    /// gracefully (Mole's own interrupt handling) before the app goes away.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.automation.isActive == false else { return .terminateNow }
        let running = model.service.runs.filter { $0.state.isRunning }
        guard !running.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = running.count == 1 ? "A Mole task is still running" : "\(running.count) Mole tasks are still running"
        alert.informativeText = running.map { "• \($0.title)" }.joined(separator: "\n")
            + "\n\nQuitting Burrow stops them. Anything Mole has already removed stays removed."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Stop and Quit")
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }

        model.service.cancelAllRuns()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(6)
            while model.service.runningCount > 0, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(150))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                openWindow(id: UpdateWindow.id)
                Task { await model.updater.check(userInitiated: true) }
            }
            .disabled(model.updater.phase.isBusy)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Route.allCases.enumerated()), id: \.element) { index, route in
                Button(route.theme.title) { model.route = route }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1 < 10 ? index + 1 : 0)")), modifiers: .command)
            }
        }
    }
}
