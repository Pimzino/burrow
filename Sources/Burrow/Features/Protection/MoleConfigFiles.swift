import Foundation

// Pure models for Mole's plain-text config files. Everything here mirrors Mole v1.56.0:
//   ~/.config/mole/whitelist           (lib/core/base.sh load_mole_whitelist, lib/manage/whitelist.sh)
//   ~/.config/mole/whitelist_optimize  (lib/manage/whitelist.sh, mode "optimize")
//   ~/.config/mole/purge_paths         (lib/clean/project.sh write_purge_config)

// MARK: - Pattern helpers

enum WhitelistPattern {
    static let finderMetadata = "FINDER_METADATA"

    /// Expands `~`, `$HOME` and `${HOME}` the way `load_mole_whitelist` does.
    static func expand(_ pattern: String, home: String = NSHomeDirectory()) -> String {
        var line = pattern.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("~") { line = home + line.dropFirst() }
        line = line.replacingOccurrences(of: "${HOME}", with: home)
        line = line.replacingOccurrences(of: "$HOME", with: home)
        return line
    }

    /// Portable `~` form Mole writes for predefined entries.
    static func portable(_ pattern: String, home: String = NSHomeDirectory()) -> String {
        let expanded = expand(pattern, home: home)
        if expanded == home { return "~" }
        if expanded.hasPrefix(home + "/") { return "~" + expanded.dropFirst(home.count) }
        return expanded
    }

    static func equivalent(_ a: String, _ b: String, home: String = NSHomeDirectory()) -> Bool {
        normalize(expand(a, home: home)) == normalize(expand(b, home: home))
    }

    private static func normalize(_ s: String) -> String {
        var s = s
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Reasons Mole would reject a clean-whitelist line (`load_mole_whitelist`), or nil when accepted.
    static func validationError(_ raw: String, home: String = NSHomeDirectory()) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Enter a path or pattern." }
        if trimmed.hasPrefix("#") { return "Lines starting with # are comments." }
        let line = expand(trimmed, home: home)
        if line.contains("..") { return "Path traversal (..) is not allowed." }
        if line == finderMetadata { return nil }
        if line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "The path contains control characters."
        }
        if !line.hasPrefix("/") { return "Must be an absolute path (start with / or ~)." }
        if line.contains("//") { return "Consecutive slashes (//) are not allowed." }
        for root in ["/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/etc", "/var/db"] {
            if line == root || line.hasPrefix(root + "/") { return "\(root) is a protected system path." }
        }
        if line == "/" { return "The root directory cannot be whitelisted." }
        return nil
    }

    static func isGlob(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
    }

    /// Escapes a literal path so Mole's glob comparison (`[[ path == $pattern ]]`, bash 3.2) and
    /// `fnmatch` match only that exact path. Paths without glob characters are returned unchanged,
    /// because Mole compares those as plain strings first.
    static func escapeLiteral(_ path: String) -> String {
        guard isGlob(path) else { return path }
        var out = ""
        for ch in path {
            if "\\*?[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Reverses `escapeLiteral` (for showing an escaped entry as the path it protects).
    static func unescapeLiteral(_ pattern: String) -> String {
        guard pattern.contains("\\") else { return pattern }
        var out = "", escaping = false
        for ch in pattern {
            if escaping { out.append(ch); escaping = false } else if ch == "\\" { escaping = true } else { out.append(ch) }
        }
        return out
    }

    /// Whitelist lines that protect one literal path and everything inside it. Mole only applies its
    /// "child of a protected folder" rule to patterns without glob characters, so an escaped path also
    /// gets an explicit `/*` entry (bash's `*` matches across `/`).
    static func literalPatterns(for path: String, home: String = NSHomeDirectory()) -> [String] {
        let portablePath = portable(path, home: home)
        guard isGlob(path) else { return [portablePath] }
        let escaped = escapeLiteral(portablePath)
        return [escaped, escaped + "/*"]
    }

    /// Why a literal path can't be protected the way Mole reads the whitelist, or nil when it can.
    static func literalProtectionError(_ path: String, home: String = NSHomeDirectory()) -> String? {
        guard path.hasPrefix("/") else { return "Only absolute paths can be protected." }
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "The name contains a line break or other control character. Mole ignores such whitelist entries, so protect its parent folder instead."
        }
        if path.contains("..") {
            return "The path contains “..”, which Mole rejects in whitelist entries. Protect its parent folder instead."
        }
        for line in literalPatterns(for: path, home: home) {
            if let error = validationError(line, home: home) { return error }
        }
        return nil
    }

    /// Patterns Mole actually honours: entries it would reject with a warning are dropped.
    static func honoured(_ patterns: [String], home: String = NSHomeDirectory()) -> [String] {
        patterns.filter { validationError($0, home: home) == nil }
    }

    /// Mole's `is_path_whitelisted` semantics: exact, glob, parent-of-pattern, or child of a non-glob pattern.
    static func matches(path: String, pattern: String, home: String = NSHomeDirectory()) -> Bool {
        let p = normalize(expand(pattern, home: home))
        let target = normalize(path.replacingOccurrences(of: "//", with: "/"))
        if p == target { return true }
        if isGlob(p), fnmatch(p, target, 0) == 0 { return true }
        if p.hasPrefix(target + "/") { return true }
        if !isGlob(p), target.hasPrefix(p + "/") { return true }
        return false
    }
}

// MARK: - Clean whitelist (~/.config/mole/whitelist)

struct CleanWhitelistFile: Sendable, Equatable {
    static let header = """
    # Mole Whitelist - Protected paths won't be deleted
    # Default protections: Playwright browsers, Ollama models, Surge Mac, R renv, Finder metadata
    # Add one pattern per line to keep items safe.
    """

    /// Active patterns in file order, exactly as written (not expanded).
    var patterns: [String]

    /// Parses the file the way `load_whitelist` does: trims, skips blanks and `#` comments, drops duplicates.
    static func parse(_ text: String, home: String = NSHomeDirectory()) -> CleanWhitelistFile {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if out.contains(where: { WhitelistPattern.equivalent($0, line, home: home) }) { continue }
            out.append(line)
        }
        return CleanWhitelistFile(patterns: out)
    }

    /// Serialises exactly like `save_whitelist_patterns clean`: header, one blank line, one pattern per line.
    func serialized(home: String = NSHomeDirectory()) -> String {
        var unique: [String] = []
        for p in patterns where !unique.contains(where: { WhitelistPattern.equivalent($0, p, home: home) }) {
            unique.append(p)
        }
        var text = Self.header + "\n"
        if !unique.isEmpty {
            text += "\n" + unique.joined(separator: "\n") + "\n"
        }
        return text
    }
}

// MARK: - Optimize whitelist (~/.config/mole/whitelist_optimize)

struct OptimizeWhitelistFile: Sendable, Equatable {
    static let header = "# Mole Optimization Whitelist - These checks will be skipped during optimization"
    static let retired: Set<String> = ["dock_refresh", "memory_pressure_relief", "launch_services_rebuild"]

    /// Entries in file order: task action IDs and path patterns (for mounted-image detection).
    var entries: [String]

    static func parse(_ text: String) -> OptimizeWhitelistFile {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || retired.contains(line) { continue }
            if out.contains(where: { WhitelistPattern.equivalent($0, line) }) { continue }
            out.append(line)
        }
        return OptimizeWhitelistFile(entries: out)
    }

    func serialized() -> String {
        var unique: [String] = []
        for e in entries where !Self.retired.contains(e) && !unique.contains(where: { WhitelistPattern.equivalent($0, e) }) {
            unique.append(e)
        }
        var text = Self.header + "\n"
        if !unique.isEmpty { text += "\n" + unique.joined(separator: "\n") + "\n" }
        return text
    }

    func excludes(task id: String) -> Bool { entries.contains(id) }

    /// Entries that are not task IDs (path patterns).
    func pathPatterns(taskIDs: Set<String>) -> [String] { entries.filter { !taskIDs.contains($0) } }

    mutating func set(task id: String, excluded: Bool) {
        if excluded {
            if !entries.contains(id) { entries.append(id) }
        } else {
            entries.removeAll { $0 == id }
        }
    }
}

// MARK: - Purge paths (~/.config/mole/purge_paths)

struct ProtectionPurgePaths: Sendable, Equatable {
    static let defaultHeader = """
    # Mole Purge Paths - Directories to scan for project artifacts
    # Add one path per line (supports ~ for home directory)
    # Delete all paths or this file to use defaults
    """

    /// Leading comment block, preserved on save.
    var header: String
    var paths: [String]

    static func parse(_ text: String) -> ProtectionPurgePaths {
        var headerLines: [String] = []
        var paths: [String] = []
        var inHeader = true
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inHeader && line.hasPrefix("#") { headerLines.append(line); continue }
            if line.isEmpty || line.hasPrefix("#") { continue }
            inHeader = false
            if !paths.contains(where: { WhitelistPattern.equivalent($0, line) }) { paths.append(line) }
        }
        let header = headerLines.isEmpty ? defaultHeader : headerLines.joined(separator: "\n")
        return ProtectionPurgePaths(header: header, paths: paths)
    }

    /// Like `write_purge_config`: header, then one path per line with `$HOME` shortened to `~`.
    func serialized(home: String = NSHomeDirectory()) -> String {
        var text = header + "\n\n"
        for p in paths { text += WhitelistPattern.portable(p, home: home) + "\n" }
        return text
    }
}

// MARK: - File state and safe IO

/// What is on disk at a config path. "Unreadable" is kept apart from "missing": Mole treats a missing
/// file as "use the defaults", but a file that exists and can't be read or decoded still holds the
/// user's rules, so it must never be replaced with a fresh one.
enum ConfigFileState: Equatable, Sendable {
    case missing
    case text(String)
    /// The file exists but could not be read or decoded. The payload is a user-facing reason.
    case unreadable(String)

    var text: String? { if case .text(let t) = self { t } else { nil } }
    var exists: Bool { self != .missing }
    var problem: String? { if case .unreadable(let why) = self { why } else { nil } }
}

struct ConfigFileError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static func refusing(_ problem: String) -> ConfigFileError {
        ConfigFileError("Not saved. \(problem) Fix or remove the file first: Burrow won’t overwrite rules it can’t read.")
    }
}

enum MoleConfigIO {
    /// Best-effort read for files the app only displays (for example the clean preview list).
    static func read(_ path: String) -> String? { load(path).text }

    static func exists(_ path: String) -> Bool { load(path).exists }

    /// Reads a config file, telling a missing file apart from one that can't be read or decoded.
    /// A dangling symlink counts as missing, like Mole's `[[ -f file ]]`.
    static func load(_ path: String) -> ConfigFileState {
        let shown = path.abbreviatingHome
        var st = stat()
        if stat(path, &st) != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            return .unreadable("\(shown) can’t be checked (\(String(cString: strerror(code)))).")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .unreadable("\(shown) is not a regular file.") }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            return .unreadable("\(shown) can’t be read (\(String(cString: strerror(errno)))).")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            return .unreadable("\(shown) can’t be read (\(error.localizedDescription)).")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unreadable("\(shown) isn’t UTF-8 text, so it can’t be edited here safely.")
        }
        return .text(text)
    }

    /// Follows a chain of symlinks on the last path component, so saving writes through the link
    /// (as Mole's `echo > file` does) instead of replacing it. Directory components need no resolving.
    static func resolvedTarget(of path: String) throws -> String {
        var current = path
        for _ in 0..<32 {
            var st = stat()
            guard lstat(current, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return current }
            let dest = try FileManager.default.destinationOfSymbolicLink(atPath: current)
            current = dest.hasPrefix("/") ? dest : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
        }
        throw ConfigFileError("\(path.abbreviatingHome) is a symlink loop.")
    }

    /// Writes via a temporary file next to the real target and an atomic rename. Symlinks are
    /// followed, existing permissions are kept, and new files get 0600. Refuses to replace a file
    /// that exists but can't be read, because that would silently drop whatever rules it holds.
    static func writeAtomically(_ text: String, to path: String) throws {
        let target = try resolvedTarget(of: path)
        if let problem = load(target).problem { throw ConfigFileError.refusing(problem) }
        let dir = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var st = stat()
        let mode: mode_t = stat(target, &st) == 0 ? (st.st_mode & 0o7777) : 0o600
        let tmp = dir + "/." + (target as NSString).lastPathComponent + ".molegui-\(UUID().uuidString.prefix(8))"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw posixError(errno, saving: path) }
        var code: Int32 = 0
        if fchmod(fd, mode) != 0 { code = errno }
        if code == 0 {
            let bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
                if n < 0 {
                    if errno == EINTR { continue }
                    code = errno
                    break
                }
                offset += n
            }
        }
        if code == 0 && fsync(fd) != 0 { code = errno }
        close(fd)
        if code == 0 && rename(tmp, target) != 0 { code = errno }
        if code != 0 {
            unlink(tmp)
            throw posixError(code, saving: path)
        }
    }

    private static func posixError(_ code: Int32, saving path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Could not save \(path.abbreviatingHome): \(String(cString: strerror(code)))"])
    }
}

// MARK: - Optimize whitelist store (with Mole's legacy fallback)

enum OptimizeWhitelistStore {
    /// Mole reads this when `whitelist_optimize` doesn't exist (`load_whitelist optimize`) and migrates it.
    static var legacyPath: String { MolePaths.config + "/whitelist_checks" }

    struct Snapshot: Equatable {
        enum Source: Equatable { case optimize, legacy, none }
        var file: OptimizeWhitelistFile
        var source: Source
        /// Set when the file Mole would read exists but can't be read; edits are refused.
        var problem: String?
        var exists: Bool { source != .none }
    }

    static func load(path: String = MolePaths.optimizeWhitelist, legacy: String? = nil) -> Snapshot {
        let empty = OptimizeWhitelistFile(entries: [])
        switch MoleConfigIO.load(path) {
        case .text(let t): return Snapshot(file: .parse(t), source: .optimize)
        case .unreadable(let why): return Snapshot(file: empty, source: .optimize, problem: why)
        case .missing: break
        }
        switch MoleConfigIO.load(legacy ?? legacyPath) {
        case .text(let t): return Snapshot(file: .parse(t), source: .legacy)
        case .unreadable(let why): return Snapshot(file: empty, source: .legacy, problem: why)
        case .missing: return Snapshot(file: empty, source: .none)
        }
    }

    /// Writes `whitelist_optimize`. Callers edit a loaded snapshot, so when the rules came from the
    /// legacy file they are carried into the first write, which is the same migration Mole performs.
    static func save(_ file: OptimizeWhitelistFile, path: String = MolePaths.optimizeWhitelist, legacy: String? = nil) throws {
        if let problem = load(path: path, legacy: legacy).problem { throw ConfigFileError.refusing(problem) }
        try MoleConfigIO.writeAtomically(file.serialized(), to: path)
    }
}

// MARK: - Purge paths store

enum PurgePathsStore {
    struct Snapshot: Equatable {
        var file: ProtectionPurgePaths
        var exists: Bool
        var problem: String?
    }

    static func load(path: String = MolePaths.purgePaths) -> Snapshot {
        let empty = ProtectionPurgePaths(header: ProtectionPurgePaths.defaultHeader, paths: [])
        switch MoleConfigIO.load(path) {
        case .text(let t): return Snapshot(file: .parse(t), exists: true)
        case .missing: return Snapshot(file: empty, exists: false)
        case .unreadable(let why): return Snapshot(file: empty, exists: true, problem: why)
        }
    }
}

