import Foundation

/// Mirrors the analyzer TUI's `r` refresh (`invalidateCacheTree`, `cmd/analyze/cache.go`):
/// deletes `~/.cache/mole/analyzer/<hex(xxh64(path))>.cache` for a directory and its direct child
/// directories, and removes those paths from `overview_sizes.json`.
enum AnalyzerCache {
    static var directory: String { MolePaths.analyzerCache }
    static var overviewFile: String { directory + "/overview_sizes.json" }

    /// Cache file for an absolute path: lowercase hex, no zero padding (Go's `strconv.FormatUint(h, 16)`).
    static func cacheFile(for path: String) -> String {
        directory + "/" + String(XXHash64.hash(path), radix: 16) + ".cache"
    }

    /// Paths `invalidateCacheTree` touches: the directory plus its direct child directories
    /// (Go's `DirEntry.IsDir`, which is false for symlinks).
    static func treePaths(_ path: String) -> [String] {
        var paths = [path]
        let url = URL(fileURLWithPath: path)
        if let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) {
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true && values?.isSymbolicLink != true {
                    paths.append((path as NSString).appendingPathComponent(child.lastPathComponent))
                }
            }
        }
        return paths
    }

    /// Invalidates `path` and its direct children. Returns how many cache files were removed.
    @discardableResult
    static func invalidateTree(_ path: String) -> Int {
        let paths = treePaths(path)
        var removed = 0
        for target in paths where (try? FileManager.default.removeItem(atPath: cacheFile(for: target))) != nil {
            removed += 1
        }
        removeOverviewKeys(paths)
        return removed
    }

    /// Invalidates single cache files (no children), e.g. the ancestors of a trashed item whose totals changed.
    /// Overview keys are left alone unless asked: they are measured with `du`, which counts ~/.Trash too.
    static func invalidate(_ paths: [String], overviewKeys: Bool = false) {
        for target in paths {
            try? FileManager.default.removeItem(atPath: cacheFile(for: target))
        }
        if overviewKeys { removeOverviewKeys(paths) }
    }

    static func removeOverviewKeys(_ paths: [String]) {
        guard let data = FileManager.default.contents(atPath: overviewFile),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var changed = false
        for path in paths where object.removeValue(forKey: path) != nil { changed = true }
        guard changed, let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? out.write(to: URL(fileURLWithPath: overviewFile), options: .atomic)
    }

    /// True when every fixed overview root has a fresh (under 7 days) size in `overview_sizes.json`,
    /// so `mo analyze --json` will return almost instantly.
    static func overviewIsWarm(home: String = NSHomeDirectory()) -> Bool {
        guard let data = FileManager.default.contents(atPath: overviewFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let roots = [home, home + "/Library", "/Applications", "/Library"]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for root in roots {
            guard let entry = object[root] as? [String: Any],
                  let size = entry["size"] as? NSNumber, size.int64Value > 0 else { return false }
            if let updated = entry["updated"] as? String,
               let date = iso.date(from: updated) ?? plain.date(from: updated),
               Date().timeIntervalSince(date) > 7 * 86_400 {
                return false
            }
        }
        return true
    }
}
