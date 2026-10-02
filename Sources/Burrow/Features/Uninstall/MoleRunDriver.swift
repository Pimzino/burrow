import Foundation

/// Helpers for driving an interactive `mo` run step by step: waiting for prompts or output and
/// reading new lines incrementally. Shared by the Uninstall, Installers and Purge features.
@MainActor
enum MoleRunDriver {
    /// Polls `condition` until it holds, the run exits, or `timeout` elapses.
    /// Returns true only when the condition became true.
    static func wait(for run: CommandRun, timeout: TimeInterval, poll: Duration = .milliseconds(40),
                     until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if !run.state.isRunning { return condition() }
            if Date() >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: poll)
        }
    }

    /// Sleeps without throwing.
    static func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    /// Stops a run that may be blocked waiting for a key: first answers with `key` (a key the
    /// current prompt treats as "cancel"), then signals it if it has not exited after `grace`,
    /// and waits until the process has really exited. Never closes stdin (EOF can mean "confirm").
    static func stop(_ run: CommandRun, answering key: String?, grace: TimeInterval = 5) async {
        if run.state.isRunning, let key {
            await pause(.milliseconds(250))  // Mole drains pending input right before some reads.
            if run.state.isRunning { run.send(key) }
            _ = await wait(for: run, timeout: grace) { false }
        }
        if run.state.isRunning { run.cancel() }
        _ = await run.waitUntilExit()
    }

    /// Waits while `condition` holds and the run is alive, without busy looping.
    static func hold(_ run: CommandRun, poll: Duration = .milliseconds(100), while condition: () -> Bool) async {
        while run.state.isRunning && condition() && !Task.isCancelled {
            try? await Task.sleep(for: poll)
        }
    }
}

/// The home directory Mole sees (it inherits the app's `HOME`), used to expand Mole's `~/…` paths.
enum MoleHomeDir {
    static var path: String {
        let env = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return env.isEmpty ? NSHomeDirectory() : env
    }

    static func expand(_ path: String) -> String {
        if path == "~" { return Self.path }
        if path.hasPrefix("~/") { return Self.path + path.dropFirst(1) }
        return path
    }

    static func abbreviate(_ path: String) -> String {
        let home = Self.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

enum RelativeAge {
    static func string(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        let text = formatter.localizedString(for: date, relativeTo: now)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
