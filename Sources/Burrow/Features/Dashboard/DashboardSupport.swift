import Darwin
import Foundation
import SwiftUI

// MARK: - Health message

/// Splits Mole's `health_score_msg` ("Fair: High Memory, Restart Recommended") into its band and issues.
struct StatusHealthMessage: Equatable, Sendable {
    var band: String
    var issues: [String]

    init(_ raw: String?) {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else {
            band = text
            issues = []
            return
        }
        band = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        issues = text[text.index(after: colon)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// SF Symbol for a known issue name from `metrics_health.go`.
    static func symbol(for issue: String) -> String {
        switch issue.lowercased() {
        case let s where s.contains("cpu"): "cpu"
        case let s where s.contains("memory"): "memorychip"
        case let s where s.contains("disk almost"): "internaldrive"
        case let s where s.contains("smart"): "exclamationmark.triangle"
        case let s where s.contains("overheat"): "thermometer.high"
        case let s where s.contains("disk io"): "arrow.up.arrow.down"
        case let s where s.contains("battery"): "battery.25percent"
        case let s where s.contains("restart"): "arrow.clockwise"
        default: "exclamationmark.circle"
        }
    }

    /// A short friendly sentence for the band.
    static func blurb(for score: Int) -> String {
        switch score {
        case 85...: "Your Mac is running smoothly."
        case 65..<85: "Your Mac is in good shape."
        case 45..<65: "A few things could use attention."
        default: "Your Mac needs some attention."
        }
    }
}

// MARK: - Memory pressure

/// macOS 26's `memory_pressure` no longer prints a level, so Mole's `memory.pressure` is often empty.
/// The kernel's own level is one sysctl away: 1 normal, 2 warn, 4 critical.
enum StatusMemoryPressure: String, Sendable {
    case normal, warn, critical, unknown

    init(mole: String?) {
        switch (mole ?? "").lowercased() {
        case "normal": self = .normal
        case "warn", "warning": self = .warn
        case "critical": self = .critical
        default: self = .unknown
        }
    }

    init(kernelLevel: Int32) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warn
        case 4: self = .critical
        default: self = .unknown
        }
    }

    static func readKernel() -> StatusMemoryPressure {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .unknown }
        return StatusMemoryPressure(kernelLevel: value)
    }

    /// Mole's value when present, otherwise the kernel's.
    static func resolve(mole: String?) -> StatusMemoryPressure {
        let fromMole = StatusMemoryPressure(mole: mole)
        return fromMole == .unknown ? readKernel() : fromMole
    }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warn: "Elevated"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .normal: .moleGood
        case .warn: .moleWarn
        case .critical: .moleBad
        case .unknown: .secondary
        }
    }

    /// 0–1 for a small gauge.
    var fraction: Double {
        switch self {
        case .normal: 0.25
        case .warn: 0.65
        case .critical: 1
        case .unknown: 0
        }
    }
}

// MARK: - Formatting

enum StatusFormat {
    /// Mole reports rates in MiB/s.
    static func rate(_ mibPerSecond: Double) -> String {
        let v = max(0, mibPerSecond)
        if v >= 1024 { return String(format: "%.1f GB/s", v / 1024) }
        if v >= 100 { return String(format: "%.0f MB/s", v) }
        if v >= 1 { return String(format: "%.1f MB/s", v) }
        let kb = v * 1024
        if kb >= 10 { return String(format: "%.0f KB/s", kb) }
        return String(format: "%.1f KB/s", kb)
    }

    static func percent(_ value: Double?, digits: Int = 0) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f%%", value)
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteFormat.string(value)
    }

    /// RAM and swap use binary units, so 16 GiB of RAM reads "16 GB" like About This Mac.
    static func memory(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func load(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }

    static func watts(_ value: Double?) -> String? {
        guard let value, value > 0.05 else { return nil }
        return String(format: "%.1f W", value)
    }

    static func celsius(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(format: "%.1f°C", value)
    }

    /// pmset status words, made friendly.
    static func batteryStatus(_ status: String?) -> String {
        switch (status ?? "").lowercased() {
        case "charged": "Fully charged"
        case "charging": "Charging"
        case "discharging": "On battery"
        case "ac", "ac attached", "finishing charge": "On power adapter"
        case "": "Unknown"
        default: status!.capitalized
        }
    }

    static func batterySymbol(percent: Double, status: String?) -> String {
        let s = (status ?? "").lowercased()
        if s == "charging" { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    static func proxyNote(_ proxy: StatusSnapshot.Proxy?) -> String? {
        guard let proxy, proxy.enabled == true else { return nil }
        let type = proxy.type ?? ""
        if type == "TUN" {
            return "A tunnel interface is active (VPN, iCloud Private Relay or a proxy)."
        }
        let host = (proxy.host ?? "").isEmpty ? "" : " via \(proxy.host!)"
        return "\(type.isEmpty ? "Proxy" : type + " proxy") enabled\(host)."
    }
}

extension StatusSnapshot.Disk {
    var displayName: String {
        if mount == "/" { return "Macintosh HD" }
        return (mount as NSString).lastPathComponent
    }

    var fraction: Double {
        if let usedPercent { return usedPercent / 100 }
        guard let used, let total, total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    var free: UInt64? {
        guard let used, let total, total >= used else { return nil }
        return total - used
    }

    var smartTitle: String? {
        switch (smartStatus ?? "").lowercased() {
        case "verified": "SMART verified"
        case "failing": "SMART failing"
        default: nil
        }
    }
}

extension StatusSnapshot.GPU {
    var usageAvailable: Bool { (usage ?? -1) >= 0 }
}

extension StatusSnapshot.Bluetooth {
    var batteryPercent: Double? {
        guard let battery, !battery.isEmpty else { return nil }
        return Double(battery.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpods") { return "airpods" }
        if n.contains("watch") { return "applewatch" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("beats") || n.contains("headphone") || n.contains("buds") { return "headphones" }
        if n.contains("speaker") || n.contains("homepod") { return "hifispeaker" }
        return "dot.radiowaves.left.and.right"
    }
}

extension StatusSnapshot.Process {
    var displayName: String {
        let n = (name ?? "").isEmpty ? (command ?? "pid \(pid)") : name!
        return n
    }
}

/// A small coloured icon badge.
struct StatusIconBadge: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: .circle)
            .accessibilityHidden(true)
    }
}

/// Label/value row used across detail cards.
struct StatusDetailRow: View {
    let label: String
    let value: String
    var symbol: String? = nil
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
