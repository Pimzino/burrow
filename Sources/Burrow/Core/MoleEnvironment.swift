import Foundation

/// Where the Mole CLI lives and how to invoke it from a GUI process.
struct MoleInstallation: Sendable, Equatable {
    /// The `mo` launcher (e.g. /opt/homebrew/bin/mo).
    let launcher: String
    /// Directory containing `bin/`, `lib/` (e.g. /opt/homebrew/Cellar/mole/1.56.0/libexec).
    let libexec: String
    let version: String
    let isHomebrew: Bool

    var statusBinary: String { libexec + "/bin/status-go" }
    var analyzeBinary: String { libexec + "/bin/analyze-go" }
}

enum MoleLocator {
    static let candidateLaunchers = [
        "/opt/homebrew/bin/mo",
        "/usr/local/bin/mo",
        NSHomeDirectory() + "/.local/bin/mo",
        "/opt/homebrew/bin/mole",
        "/usr/local/bin/mole",
        NSHomeDirectory() + "/.local/bin/mole",
    ]

    /// PATH for child processes. GUI apps start with a minimal PATH, which makes Mole silently
    /// lose Homebrew detection and other tools.
    static var childPath: String {
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return extra.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Environment for every Mole child process.
    static func environment(debug: Bool = false, extra: [String: String] = [:]) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
                    "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy",
                    "XDG_CACHE_HOME", "XDG_CONFIG_HOME"] {
            if let value = parent[key] { env[key] = value }
        }
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["USER"] = env["USER"] ?? NSUserName()
        env["SHELL"] = env["SHELL"] ?? "/bin/zsh"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = childPath
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        // Never let a subcommand open an editor (e.g. `mo purge --paths`).
        env["EDITOR"] = "/usr/bin/true"
        env["VISUAL"] = "/usr/bin/true"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        if debug { env["MO_DEBUG"] = "1" }
        for (key, value) in extra { env[key] = value }
        return env
    }

    static func locate(preferred: String? = nil) async -> MoleInstallation? {
        let fm = FileManager.default
        var candidates = candidateLaunchers
        if let preferred, !preferred.isEmpty { candidates.insert(preferred, at: 0) }
        guard let launcher = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        guard let libexec = resolveLibexec(launcher: launcher) else { return nil }

        var version = "unknown"
        var isHomebrew = libexec.contains("/Cellar/mole/")
        if let result = try? await Subprocess.run(launcher, ["--version"], environment: environment(), timeout: 20) {
            for line in result.stdoutString.split(separator: "\n") {
                if line.hasPrefix("Mole version ") {
                    version = String(line.dropFirst("Mole version ".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("Install: ") {
                    isHomebrew = line.contains("Homebrew")
                }
            }
        }
        return MoleInstallation(launcher: launcher, libexec: libexec, version: version, isHomebrew: isHomebrew)
    }

    /// Finds the directory that holds Mole's `lib/core/common.sh`.
    static func resolveLibexec(launcher: String) -> String? {
        let fm = FileManager.default
        let resolved = (try? fm.destinationOfSymbolicLink(atPath: launcher)).map { dest -> String in
            dest.hasPrefix("/") ? dest : ((launcher as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
        } ?? launcher
        let real = URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
        let dir = (real as NSString).deletingLastPathComponent
        var candidates = [
            dir,
            (dir as NSString).appendingPathComponent("../libexec"),
            (dir as NSString).appendingPathComponent("../share/mole"),
            (dir as NSString).appendingPathComponent(".."),
        ]
        // A Homebrew `bin/mo` wrapper script exec's the libexec launcher; read it to find the real path.
        if let script = try? String(contentsOfFile: real, encoding: .utf8) {
            for match in script.matches(of: /(\/[^\s"']+)\/(mole|mo)["'\s]/) {
                candidates.append((String(match.1) as NSString).standardizingPath)
            }
        }
        for candidate in candidates {
            let standardized = (candidate as NSString).standardizingPath
            if fm.fileExists(atPath: standardized + "/lib/core/common.sh") { return standardized }
        }
        return nil
    }
}

enum MolePaths {
    static let home = NSHomeDirectory()
    static let config = home + "/.config/mole"
    static let cleanWhitelist = config + "/whitelist"
    static let optimizeWhitelist = config + "/whitelist_optimize"
    static let purgePaths = config + "/purge_paths"
    static let cleanPreview = config + "/clean-list.txt"
    static let logs = home + "/Library/Logs/mole"
    static let operationsLog = logs + "/operations.log"
    static let deletionsLog = logs + "/deletions.log"
    static let debugLog = logs + "/mole_debug_session.log"
    static let cache = home + "/.cache/mole"
    static let analyzerCache = cache + "/analyzer"
    static let uninstallMetadata = cache + "/uninstall_app_metadata_v3"
    static let updateMessage = cache + "/update_message"
    static let pamSudo = "/etc/pam.d/sudo"
    static let pamSudoLocal = "/etc/pam.d/sudo_local"
}
