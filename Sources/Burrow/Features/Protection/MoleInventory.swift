import Foundation

/// One predefined protection from Mole's `get_all_cache_items` (`display name|pattern|category`).
struct CacheInventoryItem: Sendable, Equatable, Identifiable, Hashable {
    let name: String
    /// Pattern with `$HOME` already expanded (as Mole does before matching).
    let pattern: String
    let category: String
    var id: String { category + "|" + pattern }
}

/// Mole's clean-protection inventory, loaded from its own shell libraries at runtime.
struct CleanProtectionInventory: Sendable, Equatable {
    var items: [CacheInventoryItem]
    var defaults: [String]
    var safety: [String]
    /// True when the lists came from Mole itself rather than the built-in fallback.
    var fromMole: Bool

    static let categoryOrder = ["system_cache", "browser_cache", "ide_cache", "ai_ml_cache", "compiler_cache",
                                "package_manager", "container_cache", "network_tools", "app_cache"]

    static func title(for category: String) -> String {
        switch category {
        case "system_cache": "System"
        case "ide_cache": "IDEs & Editors"
        case "ai_ml_cache": "AI & Machine Learning"
        case "compiler_cache": "Compilers & Build Tools"
        case "package_manager": "Package Managers"
        case "browser_cache": "Browsers"
        case "network_tools": "Network Tools"
        case "container_cache": "Containers"
        case "app_cache": "Apps"
        default: category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func symbol(for category: String) -> String {
        switch category {
        case "system_cache": "apple.logo"
        case "ide_cache": "chevron.left.forwardslash.chevron.right"
        case "ai_ml_cache": "brain"
        case "compiler_cache": "hammer.fill"
        case "package_manager": "shippingbox.fill"
        case "browser_cache": "safari.fill"
        case "network_tools": "network"
        case "container_cache": "cube.transparent.fill"
        case "app_cache": "app.badge.fill"
        default: "folder.fill"
        }
    }

    func isSafety(_ pattern: String) -> Bool { safety.contains { WhitelistPattern.equivalent($0, pattern) } }
    func isInventory(_ pattern: String) -> Bool { items.contains { WhitelistPattern.equivalent($0.pattern, pattern) } }
    func isDefault(_ pattern: String) -> Bool { defaults.contains { WhitelistPattern.equivalent($0, pattern) } }

    /// Parses the tagged output of `loaderScript`.
    static func parse(_ output: String, home: String = NSHomeDirectory()) -> CleanProtectionInventory? {
        var items: [CacheInventoryItem] = [], defaults: [String] = [], safety: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if s.hasPrefix("I|") {
                let parts = s.dropFirst(2).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3 else { continue }
                items.append(CacheInventoryItem(name: parts[0], pattern: WhitelistPattern.expand(parts[1], home: home), category: parts[2]))
            } else if s.hasPrefix("D|") {
                defaults.append(String(s.dropFirst(2)))
            } else if s.hasPrefix("S|") {
                safety.append(String(s.dropFirst(2)))
            }
        }
        guard !items.isEmpty else { return nil }
        return CleanProtectionInventory(items: items, defaults: defaults.isEmpty ? fallback.defaults : defaults,
                                        safety: safety.isEmpty ? fallback.safety : safety, fromMole: true)
    }

    static func loaderScript(libexec: String) -> String {
        """
        source "\(libexec)/lib/manage/whitelist.sh" >/dev/null 2>&1 || exit 3
        get_all_cache_items | while IFS= read -r row; do printf 'I|%s\\n' "$row"; done
        for p in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do printf 'D|%s\\n' "$p"; done
        for p in "${SAFETY_WHITELIST_PATTERNS[@]}"; do printf 'S|%s\\n' "$p"; done
        """
    }

    @MainActor
    static func load(service: MoleService) async -> CleanProtectionInventory {
        guard let libexec = service.installation?.libexec,
              let result = try? await service.bash(loaderScript(libexec: libexec)),
              let parsed = parse(result.stdoutString) else { return fallback }
        return parsed
    }

    /// Mole v1.56.0 defaults, used when the libraries cannot be read.
    static var fallback: CleanProtectionInventory {
        let h = NSHomeDirectory()
        let rows: [(String, String, String)] = [
            ("Playwright browser binaries", "~/Library/Caches/ms-playwright*", "ai_ml_cache"),
            ("Ollama local AI models", "~/.ollama/models/*", "ai_ml_cache"),
            ("Surge proxy cache", "~/Library/Caches/com.nssurge.surge-mac/*", "network_tools"),
            ("Surge configuration and data", "~/Library/Application Support/com.nssurge.surge-mac/*", "network_tools"),
            ("R renv global cache (virtual environments)", "~/Library/Caches/org.R-project.R/R/renv/*", "package_manager"),
            ("tealdeer tldr pages cache", "~/Library/Caches/tealdeer/tldr-pages", "package_manager"),
            ("Homebrew downloaded packages", "~/Library/Caches/Homebrew/*", "package_manager"),
            ("npm package cache", "~/.npm/_cacache/*", "package_manager"),
            ("pip Python package cache", "~/.cache/pip/*", "package_manager"),
            ("Xcode DerivedData (build outputs, indexes)", "~/Library/Developer/Xcode/DerivedData/*", "ide_cache"),
            ("JetBrains IDEs cache", "~/Library/Caches/JetBrains/*", "ide_cache"),
            ("Safari web browser cache", "~/Library/Caches/com.apple.Safari/*", "browser_cache"),
            ("Chrome browser cache", "~/Library/Caches/Google/Chrome/*", "browser_cache"),
            ("Trash", "~/.Trash", "system_cache"),
            ("Finder metadata, .DS_Store", "FINDER_METADATA", "system_cache"),
        ]
        return CleanProtectionInventory(
            items: rows.map { CacheInventoryItem(name: $0.0, pattern: WhitelistPattern.expand($0.1, home: h), category: $0.2) },
            defaults: [
                "~/Library/Caches/ms-playwright*", "~/.gradle/caches/*", "~/.gradle/daemon/*", "~/.ollama/models/*",
                "~/Library/Caches/com.nssurge.surge-mac/*", "~/Library/Application Support/com.nssurge.surge-mac/*",
                "~/Library/Caches/org.R-project.R/R/renv/*", "~/Library/Caches/JetBrains*",
                "~/Library/Caches/com.jetbrains.toolbox*", "~/Library/Caches/tealdeer/tldr-pages",
                "~/Library/Application Support/JetBrains*", "~/Library/Caches/com.apple.finder",
                "~/Library/Mobile Documents*", "FINDER_METADATA",
            ].map { WhitelistPattern.expand($0, home: h) },
            safety: [
                "FINDER_METADATA", "~/Library/Caches/com.apple.FontRegistry*", "~/Library/Caches/com.apple.spotlight*",
                "~/Library/Caches/com.apple.Spotlight*", "~/Library/Caches/CloudKit*", "~/Library/Caches/pypoetry/virtualenvs*",
            ].map { WhitelistPattern.expand($0, home: h) },
            fromMole: false)
    }
}

/// Mole's default project roots for `mo purge` (`MOLE_PURGE_DEFAULT_SEARCH_PATHS`).
enum ProtectionPurgeDefaults {
    static var fallback: [String] {
        ["~/www", "~/dev", "~/Projects", "~/GitHub", "~/Code", "~/Workspace", "~/Repos", "~/Development",
         "~/Library/CloudStorage", "~/.codex/worktrees", "~/.claude/worktrees"].map { WhitelistPattern.expand($0) }
    }

    @MainActor
    static func load(service: MoleService) async -> [String] {
        guard let libexec = service.installation?.libexec else { return fallback }
        let script = """
        source "\(libexec)/lib/clean/purge_shared.sh" >/dev/null 2>&1 || exit 3
        for p in "${MOLE_PURGE_DEFAULT_SEARCH_PATHS[@]}"; do printf 'P|%s\\n' "$p"; done
        """
        guard let result = try? await service.bash(script) else { return fallback }
        let paths = result.stdoutString.split(separator: "\n").filter { $0.hasPrefix("P|") }.map { String($0.dropFirst(2)) }
        return paths.isEmpty ? fallback : paths
    }
}

/// Shared read/modify/write access to the clean whitelist, used by Protection, Clean and Purge ("Protect").
enum CleanWhitelistStore {
    struct Snapshot: Equatable {
        /// Patterns as written in the file (or Mole's defaults when there is no file).
        var patterns: [String]
        var fileExists: Bool
        /// Set when the file exists but can't be read or decoded. Mole then honours none of its
        /// entries (only the safety rules), and the app refuses to write over it.
        var problem: String?
    }

    static func snapshot(inventory: CleanProtectionInventory, path: String = MolePaths.cleanWhitelist) -> Snapshot {
        switch MoleConfigIO.load(path) {
        case .missing: Snapshot(patterns: inventory.defaults, fileExists: false)
        case .text(let text): Snapshot(patterns: CleanWhitelistFile.parse(text).patterns, fileExists: true)
        case .unreadable(let why): Snapshot(patterns: [], fileExists: true, problem: why)
        }
    }

    /// Patterns in the file, or Mole's defaults when the file is absent.
    static func effectivePatterns(inventory: CleanProtectionInventory) -> (patterns: [String], fileExists: Bool) {
        let s = snapshot(inventory: inventory)
        return (s.patterns, s.fileExists)
    }

    /// Expanded patterns Mole enforces right now: valid file entries (or defaults) plus the safety rules.
    static func enforcedPatterns(inventory: CleanProtectionInventory, path: String = MolePaths.cleanWhitelist) -> [String] {
        let s = snapshot(inventory: inventory, path: path)
        return (WhitelistPattern.honoured(s.patterns) + inventory.safety).map { WhitelistPattern.expand($0) }
    }

    /// Builds the file Mole's own manager would write for a set of patterns: predefined entries in `~`
    /// form, custom entries verbatim, safety-only entries omitted (Mole always merges them itself).
    static func fileContents(for patterns: [String], inventory: CleanProtectionInventory) -> CleanWhitelistFile {
        var out: [String] = []
        for p in patterns {
            let isInventory = inventory.isInventory(p)
            if inventory.isSafety(p) && !isInventory { continue }
            out.append(isInventory || inventory.isDefault(p) ? WhitelistPattern.portable(p) : p)
        }
        return CleanWhitelistFile(patterns: out)
    }

    static func save(_ patterns: [String], inventory: CleanProtectionInventory, path: String = MolePaths.cleanWhitelist) throws {
        if let problem = MoleConfigIO.load(path).problem { throw ConfigFileError.refusing(problem) }
        let file = fileContents(for: patterns, inventory: inventory)
        try MoleConfigIO.writeAtomically(file.serialized(), to: path)
    }

    /// Protects one literal path (and everything inside it). Creates the file with Mole's header and
    /// defaults when it does not exist yet, so the defaults stay active. Validates the entry the way
    /// `load_mole_whitelist` does and escapes glob characters, so what is saved is what Mole enforces.
    static func protect(_ path: String, inventory: CleanProtectionInventory, file: String = MolePaths.cleanWhitelist) throws {
        if let error = WhitelistPattern.literalProtectionError(path) { throw ConfigFileError(error) }
        let current = snapshot(inventory: inventory, path: file)
        if let problem = current.problem { throw ConfigFileError.refusing(problem) }
        var patterns = current.patterns
        for line in WhitelistPattern.literalPatterns(for: path) where !patterns.contains(where: { WhitelistPattern.equivalent($0, line) }) {
            patterns.append(line)
        }
        try save(patterns, inventory: inventory, path: file)
    }

    /// Removes the entries `protect` writes for a literal path (plain, or escaped plus `/*`).
    static func unprotect(_ path: String, inventory: CleanProtectionInventory, file: String = MolePaths.cleanWhitelist) throws {
        let current = snapshot(inventory: inventory, path: file)
        if let problem = current.problem { throw ConfigFileError.refusing(problem) }
        let lines = WhitelistPattern.literalPatterns(for: path) + [path]
        let kept = current.patterns.filter { p in !lines.contains { WhitelistPattern.equivalent($0, p) } }
        guard kept.count != current.patterns.count else { return }
        try save(kept, inventory: inventory, path: file)
    }

    static func isProtected(_ path: String, inventory: CleanProtectionInventory) -> Bool {
        enforcedPatterns(inventory: inventory).contains { WhitelistPattern.matches(path: path, pattern: $0) }
    }
}

