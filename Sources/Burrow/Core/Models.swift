import Foundation

// MARK: - mo status --json / --watch

/// One metrics snapshot from `mo status`. Sizes are bytes, percentages 0–100, rates MB/s.
/// Every field is optional-tolerant because watch mode omits fields before the first full collect.
struct StatusSnapshot: Decodable, Sendable, Equatable {
    struct Hardware: Decodable, Sendable, Equatable {
        var model: String?
        var cpuModel: String?
        var totalRam: String?
        var diskSize: String?
        var osVersion: String?
        var refreshRate: String?
    }
    struct CPU: Decodable, Sendable, Equatable {
        var usage: Double?
        var perCore: [Double]?
        var perCoreEstimated: Bool?
        var load1: Double?
        var load5: Double?
        var load15: Double?
        var coreCount: Int?
        var logicalCpu: Int?
        var pCoreCount: Int?
        var eCoreCount: Int?
    }
    struct GPU: Decodable, Sendable, Equatable {
        var name: String?
        var usage: Double?
        var coreCount: Int?
        var note: String?
    }
    struct Memory: Decodable, Sendable, Equatable {
        var used: UInt64?
        var total: UInt64?
        var available: UInt64?
        var usedPercent: Double?
        var swapUsed: UInt64?
        var swapTotal: UInt64?
        var cached: UInt64?
        var pressure: String?
    }
    struct Disk: Decodable, Sendable, Equatable, Identifiable {
        var mount: String
        var device: String?
        var used: UInt64?
        var total: UInt64?
        var usedPercent: Double?
        var fstype: String?
        var external: Bool?
        var smartStatus: String?
        var purgeable: UInt64?
        var id: String { mount }
    }
    struct DiskIO: Decodable, Sendable, Equatable {
        var readRate: Double?
        var writeRate: Double?
    }
    struct NetworkInterface: Decodable, Sendable, Equatable, Identifiable {
        var name: String
        var rxRateMbs: Double?
        var txRateMbs: Double?
        var ip: String?
        var id: String { name }
    }
    struct NetworkHistory: Decodable, Sendable, Equatable {
        var rxHistory: [Double]?
        var txHistory: [Double]?
    }
    struct Proxy: Decodable, Sendable, Equatable {
        var enabled: Bool?
        var type: String?
        var host: String?
    }
    struct Battery: Decodable, Sendable, Equatable {
        var percent: Double?
        var status: String?
        var timeLeft: String?
        var health: String?
        var cycleCount: Int?
        var capacity: Int?
    }
    struct Thermal: Decodable, Sendable, Equatable {
        var cpuTemp: Double?
        var gpuTemp: Double?
        var batteryTemp: Double?
        var fanSpeed: Int?
        var fanCount: Int?
        var systemPower: Double?
        var adapterPower: Double?
        var batteryPower: Double?
    }
    struct Bluetooth: Decodable, Sendable, Equatable, Identifiable {
        var name: String
        var connected: Bool?
        var battery: String?
        var id: String { name }
    }
    struct Process: Decodable, Sendable, Equatable, Identifiable {
        var pid: Int
        var ppid: Int?
        var name: String?
        var command: String?
        var cpu: Double?
        var memory: Double?
        var memoryBytes: UInt64?
        var id: Int { pid }
    }
    struct ZombieParent: Decodable, Sendable, Equatable {
        var pid: Int
        var name: String?
        var count: Int?
    }
    struct ProcessWatch: Decodable, Sendable, Equatable {
        var enabled: Bool?
        var cpuThreshold: Double?
        var window: String?
    }
    struct ProcessAlert: Decodable, Sendable, Equatable, Identifiable {
        var pid: Int
        var name: String?
        var command: String?
        var cpu: Double?
        var threshold: Double?
        var window: String?
        var triggeredAt: String?
        var status: String?
        var id: Int { pid }
    }

    var collectedAt: String?
    var host: String?
    var platform: String?
    var uptime: String?
    var uptimeSeconds: UInt64?
    var procs: UInt64?
    var hardware: Hardware?
    var healthScore: Int?
    var healthScoreMsg: String?
    var cpu: CPU?
    var gpu: [GPU]?
    var memory: Memory?
    var disks: [Disk]?
    var trashSize: UInt64?
    var trashApprox: Bool?
    var diskIo: DiskIO?
    var network: [NetworkInterface]?
    var networkHistory: NetworkHistory?
    var proxy: Proxy?
    var batteries: [Battery]?
    var thermal: Thermal?
    var bluetooth: [Bluetooth]?
    var topProcesses: [Process]?
    var processCollectedAt: String?
    var processStale: Bool?
    var zombieCount: Int?
    var zombieParents: [ZombieParent]?
    var processWatch: ProcessWatch?
    var processAlerts: [ProcessAlert]?

    /// True for the first watch line, which has no hardware enrichment yet.
    var isEnriched: Bool { !(hardware?.model ?? "").isEmpty }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: - mo analyze --json

struct AnalyzeReport: Decodable, Sendable, Equatable {
    struct Entry: Decodable, Sendable, Equatable, Identifiable, Hashable {
        var name: String
        var path: String
        var size: Int64
        var isDir: Bool
        var insight: Bool?
        var cleanable: Bool?
        var lastAccess: String?
        var id: String { path }
        /// Symlinks get a " →" suffix from Mole.
        var isSymlink: Bool { name.hasSuffix(" →") }
        var displayName: String { isSymlink ? String(name.dropLast(2)) : name }
    }
    struct LargeFile: Decodable, Sendable, Equatable, Identifiable, Hashable {
        var name: String
        var path: String
        var size: Int64
        var id: String { path }
    }

    var path: String
    var overview: Bool
    var entries: [Entry]
    var largeFiles: [LargeFile]?
    var totalSize: Int64
    var totalFiles: Int64?

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: - mo history --json

struct HistoryReport: Decodable, Sendable, Equatable {
    struct Logs: Decodable, Sendable, Equatable {
        var operations: String?
        var deletions: String?
    }
    struct Session: Decodable, Sendable, Equatable, Identifiable, Hashable {
        struct Actions: Decodable, Sendable, Equatable, Hashable {
            var removed: Int?
            var trashed: Int?
            var skipped: Int?
            var failed: Int?
            var rebuilt: Int?
            var other: Int?
        }
        var command: String
        var startedAt: String
        var endedAt: String?
        var items: Int?
        var size: String?
        var operationCount: Int?
        var failedTasks: Int?
        var actions: Actions?
        var id: String { command + startedAt }
    }
    struct Deletion: Decodable, Sendable, Equatable, Identifiable, Hashable {
        var timestamp: String
        var mode: String?
        var status: String?
        var sizeKb: Int?
        var path: String
        var id: String { timestamp + path }
    }

    var logs: Logs?
    var limit: Int?
    var sessions: [Session]
    var deletions: [Deletion]

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: - mo uninstall --list (JSON when piped)

struct InstalledApp: Decodable, Sendable, Equatable, Identifiable, Hashable {
    var name: String
    var bundleId: String
    var source: String
    var uninstallName: String
    var path: String
    var size: String

    var id: String { path }
    var isHomebrew: Bool { source == "Homebrew" }
    var isSteam: Bool { size.contains("Steam") }
    /// Mole matches names against the display name and the `.app` basename; the basename is unambiguous.
    var matchName: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    var cleanName: String { name.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}\u{200B}").union(.whitespaces)) }
    var sizeBytes: Int64? { ByteFormat.parse(size) }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

/// Extra metadata from Mole's uninstall cache (`~/.cache/mole/uninstall_app_metadata_v3`).
struct AppMetadata: Sendable, Equatable {
    var sizeKB: Int64?
    var lastUsed: Date?

    /// path|app_mtime|size_kb|last_used_epoch|updated_epoch|bundle_id|display_name|lang_signature
    static func loadAll() -> [String: AppMetadata] {
        guard let text = try? String(contentsOfFile: MolePaths.uninstallMetadata, encoding: .utf8) else { return [:] }
        var result: [String: AppMetadata] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { continue }
            let size = Int64(parts[2])
            let epoch = TimeInterval(parts[3]) ?? 0
            result[String(parts[0])] = AppMetadata(sizeKB: size, lastUsed: epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil)
        }
        return result
    }
}

// MARK: - Byte formatting (Mole uses decimal units)

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        if bytes < 0 { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    static func string(_ bytes: UInt64) -> String { string(Int64(clamping: bytes)) }

    /// Parses Mole's human sizes ("1.38GB", "923.3MB", "4KB", "0B") to bytes (decimal units).
    static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.firstMatch(of: /([0-9]+(?:\.[0-9]+)?)\s*(TB|GB|MB|KB|B)\b/) else { return nil }
        guard let value = Double(match.1) else { return nil }
        let multiplier: Double = switch match.2 {
        case "TB": 1e12
        case "GB": 1e9
        case "MB": 1e6
        case "KB": 1e3
        default: 1
        }
        return Int64(value * multiplier)
    }
}
