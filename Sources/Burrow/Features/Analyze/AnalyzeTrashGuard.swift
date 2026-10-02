import Darwin
import Foundation

/// Swift port of the analyzer's `validateTrashTarget` (`cmd/analyze/delete.go`): the paths Mole's
/// own analyzer refuses to move to the Trash. The GUI applies exactly the same rules.
enum AnalyzeTrashGuard {
    enum Rejection: Error, Equatable, LocalizedError {
        case empty, relative, nullByte, traversal
        case protected(String)

        var errorDescription: String? {
            switch self {
            case .empty: "The path is empty."
            case .relative: "Only absolute paths can be moved to the Trash."
            case .nullByte: "The path contains a null byte."
            case .traversal: "The path contains “..” components."
            case .protected(let path): "“\(path.abbreviatingHome)” is protected. Mole never moves system folders, account homes or container runtimes to the Trash."
            }
        }
    }

    static let criticalRoots = [
        "/", "/Applications", "/Applications/Finder.app", "/Applications/Safari.app", "/Library", "/Library/Apple",
        "/Library/Application Support", "/Library/Extensions", "/Library/Keychains", "/System", "/Users", "/Volumes",
        "/Network", "/cores", "/dev", "/etc", "/home", "/net", "/tmp", "/var", "/private", "/private/etc", "/private/tmp",
        "/private/var", "/private/var/audit", "/private/var/db", "/private/var/root", "/private/var/tmp",
        "/private/var/folders", "/bin", "/sbin", "/usr", "/opt", "/opt/homebrew",
    ]

    static let protectedTrees = [
        "/System", "/bin", "/sbin", "/usr", "/private/etc", "/private/var/audit", "/private/var/db", "/private/var/root",
        "/Library/Apple", "/Library/Extensions", "/Library/Keychains", "/Applications/Finder.app",
        "/Applications/Safari.app", "/dev",
    ]

    static let endpointSecurityPrefixes = [
        "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.", "com.eset.", "com.jamf.", "com.jamfsoftware.",
        "com.paloaltonetworks.", "com.cisco.anyconnect", "com.cisco.secureclient",
    ]

    /// Throws a `Rejection` when Mole's analyzer would refuse to trash `path`.
    static func validate(_ path: String) throws(Rejection) {
        try validatePath(path)
        if isProtected(path) { throw .protected(path) }
        if let resolved = resolveSymlinks(path), isProtected(resolved) { throw .protected(path) }
    }

    static func validatePath(_ path: String) throws(Rejection) {
        if path.isEmpty { throw .empty }
        if !path.hasPrefix("/") { throw .relative }
        if path.contains("\u{0}") { throw .nullByte }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains("..") { throw .traversal }
    }

    static func isProtected(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let clean = cleanPath(path)
        if isEndpointSecurityCache(clean) { return true }
        if isCritical(clean) { return true }

        for home in homeRoots() {
            if clean == home || sameExisting(clean, home) { return true }
            for state in [home + "/Library/Containers/com.docker.docker", home + "/.orbstack"] {
                if clean == state || clean.hasPrefix(state + "/") || withinExistingRoot(clean, state) { return true }
            }
            let groupContainers = home + "/Library/Group Containers"
            if let names = try? FileManager.default.contentsOfDirectory(atPath: groupContainers) {
                for name in names where name.lowercased().hasSuffix("dev.orbstack") {
                    if withinExistingRoot(clean, groupContainers + "/" + name) { return true }
                }
            }
            let lowerRoot = groupContainers.lowercased() + "/"
            let lower = clean.lowercased()
            if lower.hasPrefix(lowerRoot) {
                let rel = lower.dropFirst(lowerRoot.count)
                let container = rel.split(separator: "/").first.map(String.init) ?? String(rel)
                if container.hasSuffix("dev.orbstack") { return true }
            }
        }
        return false
    }

    static func isCritical(_ path: String) -> Bool {
        for root in criticalRoots where path == root || sameExisting(path, root) { return true }
        // A direct child of /Users is an account home.
        let parent = (path as NSString).deletingLastPathComponent
        if path != "/Users", parent != path, sameExisting(parent, "/Users") { return true }
        for root in protectedTrees where path.hasPrefix(root + "/") || withinExistingRoot(path, root) { return true }
        return false
    }

    static func isEndpointSecurityCache(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.hasPrefix("/private/var/folders/") || lower.hasPrefix("/var/folders/") else { return false }
        return endpointSecurityPrefixes.contains { lower.contains($0) }
    }

    // MARK: Helpers (Go's filepath.Clean / os.SameFile / EvalSymlinks equivalents)

    static func cleanPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." { parts.append(part) }
        return "/" + parts.joined(separator: "/")
    }

    static func homeRoots() -> [String] {
        var roots: [String] = []
        func add(_ home: String?) {
            guard let home, !home.isEmpty else { return }
            let clean = cleanPath(home)
            if !roots.contains(clean) { roots.append(clean) }
            if let resolved = resolveSymlinks(clean), !roots.contains(resolved) { roots.append(resolved) }
        }
        add(ProcessInfo.processInfo.environment["HOME"])
        add(NSHomeDirectory())
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { add(String(cString: dir)) }
        return roots
    }

    static func resolveSymlinks(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private static func identity(_ path: String) -> (dev_t, ino_t)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (st.st_dev, st.st_ino)
    }

    static func sameExisting(_ a: String, _ b: String) -> Bool {
        guard let x = identity(a), let y = identity(b) else { return false }
        return x == y
    }

    static func withinExistingRoot(_ path: String, _ root: String) -> Bool {
        guard let rootID = identity(root) else { return false }
        var current = cleanPath(path)
        while true {
            if let id = identity(current), id == rootID { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }
}
