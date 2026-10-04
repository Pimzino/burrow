import SwiftUI

/// Each area of the app has its own accent gradient, used for its icon, hero and primary action.
enum FeatureTheme: String, CaseIterable, Sendable {
    case dashboard, clean, uninstall, optimize, analyze, purge, installers, history, protection, settings
    /// First-run setup wears the brand colours (ember and lantern, docs/BRAND.md) rather than a feature's.
    case setup

    var colors: [Color] {
        switch self {
        case .dashboard: [Color(red: 0.25, green: 0.52, blue: 1.0), Color(red: 0.20, green: 0.84, blue: 0.95)]
        case .clean: [Color(red: 0.06, green: 0.74, blue: 0.62), Color(red: 0.43, green: 0.90, blue: 0.45)]
        case .uninstall: [Color(red: 1.0, green: 0.30, blue: 0.45), Color(red: 1.0, green: 0.55, blue: 0.35)]
        case .optimize: [Color(red: 1.0, green: 0.58, blue: 0.10), Color(red: 1.0, green: 0.82, blue: 0.20)]
        case .analyze: [Color(red: 0.49, green: 0.33, blue: 1.0), Color(red: 0.85, green: 0.40, blue: 0.95)]
        case .purge: [Color(red: 0.10, green: 0.62, blue: 0.95), Color(red: 0.35, green: 0.40, blue: 1.0)]
        case .installers: [Color(red: 0.93, green: 0.42, blue: 0.20), Color(red: 0.98, green: 0.30, blue: 0.62)]
        case .history: [Color(red: 0.40, green: 0.48, blue: 0.62), Color(red: 0.55, green: 0.66, blue: 0.80)]
        case .protection: [Color(red: 0.18, green: 0.70, blue: 0.45), Color(red: 0.10, green: 0.55, blue: 0.75)]
        case .settings: [Color(red: 0.45, green: 0.47, blue: 0.53), Color(red: 0.62, green: 0.64, blue: 0.70)]
        case .setup: [Color(red: 0.93, green: 0.42, blue: 0.20), Color(red: 1.0, green: 0.70, blue: 0.25)]
        }
    }

    var accent: Color { colors[0] }
    var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
    var angular: AngularGradient { AngularGradient(colors: colors + [colors[0]], center: .center) }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .clean: "sparkles"
        case .uninstall: "trash.square.fill"
        case .optimize: "bolt.circle.fill"
        case .analyze: "chart.pie.fill"
        case .purge: "hammer.circle.fill"
        case .installers: "shippingbox.fill"
        case .history: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .protection: "checkmark.shield.fill"
        case .settings: "gearshape.fill"
        case .setup: "lamp.table.fill"
        }
    }

    var title: String {
        switch self {
        case .dashboard: "Status"
        case .clean: "Clean"
        case .uninstall: "Uninstall"
        case .optimize: "Optimize"
        case .analyze: "Disk Analyzer"
        case .purge: "Project Purge"
        case .installers: "Installers"
        case .history: "History"
        case .protection: "Protection"
        case .settings: "Settings"
        case .setup: "Setup"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: "Live health of your Mac"
        case .clean: "Caches, logs and leftovers"
        case .uninstall: "Remove apps completely"
        case .optimize: "Refresh caches and services"
        case .analyze: "See what fills your disk"
        case .purge: "Old build artifacts"
        case .installers: ".dmg, .pkg and friends"
        case .history: "Everything Mole has done"
        case .protection: "Paths Mole must never touch"
        case .settings: "Mole CLI and Burrow options"
        case .setup: "Get Burrow ready"
        }
    }
}

enum Metrics {
    static let cardRadius: CGFloat = 22
    static let tileRadius: CGFloat = 18
    static let pagePadding: CGFloat = 28
    static let spacing: CGFloat = 18
}

extension Color {
    static let moleGood = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let moleWarn = Color(red: 1.0, green: 0.70, blue: 0.10)
    static let moleBad = Color(red: 1.0, green: 0.32, blue: 0.35)

    /// Colour for a 0–100 "used" percentage.
    static func usage(_ percent: Double) -> Color {
        percent >= 90 ? .moleBad : percent >= 75 ? .moleWarn : .moleGood
    }

    /// Colour for a 0–100 health score (higher is better).
    static func health(_ score: Int) -> Color {
        score >= 85 ? .moleGood : score >= 65 ? Color(red: 0.55, green: 0.80, blue: 0.25) : score >= 45 ? .moleWarn : .moleBad
    }
}
