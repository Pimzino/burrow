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
        guard let reportDir else { return }
        try? FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result) {
            try? data.write(to: URL(fileURLWithPath: reportDir).appendingPathComponent("\(feature).json"))
        }
    }
}
