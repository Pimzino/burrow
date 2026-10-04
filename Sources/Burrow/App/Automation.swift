import AppKit
import Foundation
import Observation

/// Launch-argument driven automation for end-to-end runs (see scripts/e2e.sh).
///
///     Mole -MoleE2ERoute clean -MoleE2EAutorun YES -MoleE2EReportDir /path/out
///
/// With autorun on, a feature starts its *non-destructive* primary action (scan / preview / dry run)
/// when it appears, and records the outcome with `record`. Destructive actions are never automated.
@MainActor
@Observable
final class Automation {
    let route: Route?
    let autorun: Bool
    let reportDir: String?
    private(set) var results: [String: Result] = [:]

    struct Result: Codable, Sendable {
        var feature: String
        var passed: Bool
        var detail: String
        var metrics: [String: String]
    }

    init(defaults: UserDefaults = .standard) {
        route = defaults.string(forKey: "MoleE2ERoute").flatMap(Route.init(rawValue:))
        autorun = defaults.bool(forKey: "MoleE2EAutorun")
        reportDir = defaults.string(forKey: "MoleE2EReportDir")
    }

    var isActive: Bool { route != nil || autorun || reportDir != nil }

    /// Records the outcome of a feature's automated action into `<reportDir>/<feature>.json`.
    func record(_ feature: String, passed: Bool, detail: String, metrics: [String: String] = [:]) {
        let result = Result(feature: feature, passed: passed, detail: detail, metrics: metrics)
        results[feature] = result
        // E2E runs capture the window right after this; make sure it is frontmost, not a Stage Manager thumbnail.
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true || $0.title == "Burrow" }?.makeKeyAndOrderFront(nil)
        performPointerScript()
        guard let reportDir else { return }
        try? FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result) {
            try? data.write(to: URL(fileURLWithPath: reportDir).appendingPathComponent("\(feature).json"))
        }
    }

    // MARK: Pointer script

    private var pointerScriptRan = false

    /// End-to-end aid for pointer handling: `-MoleE2EPointer "move:612,369;click:612,369"` replays mouse
    /// events inside the main window once the screen's automated action has finished. Steps are
    /// `move`, `click` or `double`, at window points measured from the window's top-left corner
    /// (a window screenshot's pixels divided by the display scale). Events are posted to the app's own event queue, so
    /// the real cursor does not move and no Accessibility permission is needed. The window must be
    /// active (launch with `open -n Burrow.app --args …`), and context menus cannot be opened this way.
    private func performPointerScript() {
        guard !pointerScriptRan, let script = UserDefaults.standard.string(forKey: "MoleE2EPointer") else { return }
        pointerScriptRan = true
        let steps: [(String, CGPoint)] = script.split(separator: ";").compactMap { step in
            let parts = step.split(separator: ":")
            let xy = parts.last?.split(separator: ",").compactMap { Double($0) } ?? []
            guard parts.count == 2, xy.count == 2 else { return nil }
            return (String(parts[0]), CGPoint(x: xy[0], y: xy[1]))
        }
        Task { @MainActor in
            for (kind, point) in steps {
                try? await Task.sleep(for: .seconds(1.5))
                guard let window = NSApp.windows.first(where: { $0.title == "Burrow" }) ?? NSApp.mainWindow else { return }
                // AppKit window coordinates start at the bottom-left corner.
                let location = CGPoint(x: point.x, y: window.frame.height - point.y)
                func send(_ type: NSEvent.EventType, clicks: Int = 1) {
                    guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: clicks, pressure: type == .mouseMoved ? 0 : 1)
                    else { return }
                    NSApp.postEvent(event, atStart: false)
                }
                send(.mouseMoved, clicks: 0)
                try? await Task.sleep(for: .milliseconds(80))
                switch kind {
                case "click":
                    send(.leftMouseDown)
                    try? await Task.sleep(for: .milliseconds(60))
                    send(.leftMouseUp)
                case "double":
                    send(.leftMouseDown); send(.leftMouseUp)
                    try? await Task.sleep(for: .milliseconds(60))
                    send(.leftMouseDown, clicks: 2); send(.leftMouseUp, clicks: 2)
                default: break
                }
            }
        }
    }
}
