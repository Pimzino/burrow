import Foundation

struct PurgeArtifact: Identifiable, Hashable, Sendable {
    /// As Mole prints it (`~/Projects/app/node_modules`).
    var displayPath: String
    var size: String
    var isCloud: Bool

    var id: String { displayPath }
    var path: String { MoleHomeDir.expand(displayPath) }
    var bytes: Int64 { ByteFormat.parse(size) ?? 0 }
    var type: String { (displayPath as NSString).lastPathComponent }
    var projectDisplayPath: String { (displayPath as NSString).deletingLastPathComponent }
    var projectName: String { (projectDisplayPath as NSString).lastPathComponent }
}

struct PurgeScanFailure: Hashable, Sendable {
    var root: String
    var status: String
    var needsFullDiskAccess: Bool {
        root.contains("Library/CloudStorage") || root.contains("Library/Mobile Documents") || root.contains("/Library/")
    }
}

struct PurgeSummary: Equatable, Sendable {
    var heading = ""
    var details: [String] = []
    var amount: String?
    var unmeasured: Int?
    var items: Int?
    var freeSpace: String?
    var nothingRemoved = false
    var isDryRun: Bool { heading.localizedCaseInsensitiveContains("dry run") }
    var isIncomplete: Bool { heading.localizedCaseInsensitiveContains("incomplete") }
}

/// Pure, incremental parser for `mo purge` output (dry run or `--yes`) in pipe mode.
struct PurgeParser {
    private(set) var artifacts: [PurgeArtifact] = []
    private(set) var failures: [PurgeScanFailure] = []
    private(set) var warnings: [String] = []
    private(set) var errors: [String] = []
    private(set) var noCandidates = false
    private(set) var sawTitle = false
    private(set) var summary: PurgeSummary?
    private var inFailureList = false
    private var dividers = 0

    mutating func feed(_ line: OutputLine) {
        let text = line.text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if line.stream == .stderr {
            if trimmed.hasPrefix("◎ ") {
                warnings.append(String(trimmed.dropFirst(2)))
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("[DEBUG]") {
                errors.append(trimmed.hasPrefix("☻ ") ? String(trimmed.dropFirst(2)) : trimmed)
            }
            return
        }
        if trimmed.count >= 20 && trimmed.allSatisfy({ $0 == "=" }) {
            dividers += 1
            if dividers == 1 { summary = PurgeSummary() }
            return
        }
        if dividers == 1 {
            guard !trimmed.isEmpty else { return }
            if summary?.heading.isEmpty ?? true { summary?.heading = trimmed } else { parseSummary(trimmed) }
            return
        }
        if trimmed == "Purge Project Artifacts" { sawTitle = true; return }

        if inFailureList {
            if text.hasPrefix("  "), let m = trimmed.firstMatch(of: /^(.+?) \((status .+)\)$/) {
                failures.append(PurgeScanFailure(root: String(m.1), status: String(m.2)))
                return
            }
            inFailureList = false
        }
        if trimmed.hasPrefix("◎ Skipped"), trimmed.contains("because scanning did not complete") {
            inFailureList = true
            return
        }
        if let m = trimmed.firstMatch(of: /^✓ (?:\[DRY RUN\] )?(\[cloud\] )?(.+), (\S+)$/) {
            artifacts.append(PurgeArtifact(displayPath: String(m.2), size: String(m.3), isCloud: m.1 != nil))
            return
        }
        if trimmed.hasPrefix("◎ ") { warnings.append(String(trimmed.dropFirst(2))); return }
        if trimmed.hasPrefix("✓ Great! No old project artifacts")
            || trimmed.hasPrefix("No artifacts found") || trimmed.hasPrefix("No eligible project artifacts")
            || trimmed.hasPrefix("No artifacts could be prepared") || trimmed == "No items selected" {
            noCandidates = true
        }
    }

    private mutating func parseSummary(_ line: String) {
        summary?.details.append(line)
        if let m = line.firstMatch(of: /^(?:Would free approximately|Estimated space freed): (\S+)(?: \+ (\d+) unmeasured)?(?: \| Items: (\d+))?(?: \| Free: (\S+))?/) {
            summary?.amount = String(m.1)
            summary?.unmeasured = m.2.flatMap { Int($0) }
            summary?.items = m.3.flatMap { Int($0) }
            summary?.freeSpace = m.4.map(String.init)
        } else if line.hasPrefix("No artifacts were removed") {
            summary?.nothingRemoved = true
        } else if let m = line.firstMatch(of: /^Free space: (\S+)/) {
            summary?.freeSpace = String(m.1)
        }
    }
}

enum PurgeTypes {
    static func symbol(for type: String) -> String {
        switch type {
        case "node_modules": "shippingbox.fill"
        case "target", "build", "dist", ".build", "zig-out", ".zig-cache", "bin", "obj", "out": "hammer.fill"
        case "venv", ".venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".nox", ".ruff_cache": "chevron.left.forwardslash.chevron.right"
        case "DerivedData", "Pods": "swift"
        case ".next", ".nuxt", ".output", ".turbo", ".parcel-cache", ".angular", ".svelte-kit", ".astro", ".expo": "globe"
        case ".gradle", ".cxx": "cup.and.saucer.fill"
        case ".dart_tool": "bird.fill"
        case "coverage": "checkmark.shield.fill"
        case "vendor": "books.vertical.fill"
        case ".terragrunt-cache": "cloud.fill"
        default: "folder.fill"
        }
    }

    /// Mole's purge target names (`purge_shared.sh`), used to recognise protected artifacts.
    static let targets: Set<String> = ["node_modules", "target", "build", "dist", "venv", ".venv", ".pytest_cache", ".mypy_cache",
                                       ".tox", ".nox", ".ruff_cache", ".gradle", ".terragrunt-cache", "__pycache__", ".next", ".nuxt",
                                       ".output", "vendor", "bin", "obj", ".turbo", ".parcel-cache", ".dart_tool", ".zig-cache",
                                       "zig-out", ".angular", ".svelte-kit", ".astro", "coverage", "DerivedData", "Pods", ".cxx",
                                       ".expo", ".build"]
}
