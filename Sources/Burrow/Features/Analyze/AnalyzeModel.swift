import AppKit
import Foundation
import Observation

/// State for the Disk Analyzer: the machine overview, the directory being browsed, navigation
/// history and the scan in flight. Scans run `mo analyze --json [PATH]` (flags before the path).
@MainActor
@Observable
final class AnalyzeModel {
    /// Kept for the app session so leaving and returning to the analyzer restores where you were.
    static let shared = AnalyzeModel()

    enum Target: Hashable, Sendable {
        case overview
        case directory(String)

        var path: String? { if case .directory(let p) = self { p } else { nil } }
    }

    struct Scan: Equatable {
        let target: Target
        let startedAt: Date
        /// Overview with a warm cache, or a directory: expected to be quick.
        let expectedFast: Bool
    }

    /// Where the user is. `nil` until the first scan is requested.
    private(set) var current: Target?
    private(set) var overview: AnalyzeReport?
    private(set) var report: AnalyzeReport?
    private(set) var scan: Scan?
    private(set) var error: String?
    private(set) var lastScanDuration: TimeInterval?
    private(set) var backStack: [Target] = []
    private(set) var forwardStack: [Target] = []
    var selection: String?
    /// Status line after a Trash operation.
    var notice: String?
    /// The automated (E2E) scan runs once per app session.
    var didAutorun = false

    @ObservationIgnored private var process: Subprocess?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var onFinish: ((Target, AnalyzeReport?, String?, TimeInterval) -> Void)?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    init() {
        // Scans run in their own session and aren't registered with MoleService, so the app's quit
        // handling never reaches them: stop the scan here, or `du`/analyze-go keep running after quit.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateScanForQuit() }
        }
    }

    /// Stops the scan synchronously while the app is quitting. A scan only reads, so it needs no grace
    /// period, and the delayed escalation in `Subprocess.cancel()` would never run once the app is gone.
    private func terminateScanForQuit() {
        guard let process else { return }
        generation += 1
        self.process = nil
        scan = nil
        process.signal(SIGTERM)
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        process.signal(SIGKILL)
    }

    var isScanning: Bool { scan != nil }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var currentPath: String? { current?.path }

    var parentPath: String? {
        guard let path = currentPath, path != "/" else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    var selectedEntry: AnalyzeReport.Entry? {
        guard let selection else { return nil }
        return report?.entries.first { $0.path == selection }
    }

    var selectedLargeFile: AnalyzeReport.LargeFile? {
        guard let selection else { return nil }
        return report?.largeFiles?.first { $0.path == selection }
    }

    // MARK: Navigation

    func showOverview(service: MoleService, force: Bool = false) {
        navigate(to: .overview, service: service, force: force)
    }

    func open(_ path: String, service: MoleService) {
        navigate(to: .directory(path), service: service)
    }

    func navigate(to target: Target, service: MoleService, force: Bool = false) {
        if let current, current != target {
            backStack.append(current)
            if backStack.count > 100 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        load(target, service: service, force: force)
    }

    func goBack(service: MoleService) {
        guard let target = backStack.popLast() else { return }
        if let current { forwardStack.append(current) }
        load(target, service: service)
    }

    func goForward(service: MoleService) {
        guard let target = forwardStack.popLast() else { return }
        if let current { backStack.append(current) }
        load(target, service: service)
    }

    func goUp(service: MoleService) {
        guard let parentPath else { return }
        navigate(to: .directory(parentPath), service: service)
    }

    /// Clears Mole's analyzer cache for the current location and scans again.
    func rescan(service: MoleService) {
        guard let current else { return }
        switch current {
        case .overview:
            // Like the TUI's `r` on the overview: `invalidateCache(entry.Path)` for every overview entry
            // (its `<xxh64>.cache` file and its `overview_sizes.json` key), insight rows included, plus the
            // fixed roots in case the last overview never loaded.
            let home = NSHomeDirectory()
            let fixedRoots = [home, home + "/Library", "/Applications", "/Library"]
            var seen = Set<String>()
            let paths = ((overview?.entries.map(\.path) ?? []) + fixedRoots).filter { seen.insert($0).inserted }
            AnalyzerCache.invalidate(paths, overviewKeys: true)
        case .directory(let path):
            AnalyzerCache.invalidateTree(path)
        }
        load(current, service: service, force: true)
    }

    func cancel() {
        generation += 1
        process?.cancel()
        process = nil
        scan = nil
    }

    // MARK: Scanning

    private func load(_ target: Target, service: MoleService, force: Bool = false) {
        cancel()
        current = target
        selection = nil
        error = nil
        if target == .overview, overview != nil, !force {
            return
        }
        guard let installation = service.installation else {
            error = MoleError.notInstalled.localizedDescription
            return
        }

        generation += 1
        let myGeneration = generation
        let expectedFast = target == .overview ? AnalyzerCache.overviewIsWarm() : true
        let started = Date()
        scan = Scan(target: target, startedAt: started, expectedFast: expectedFast)

        var args = ["analyze", "--json"]
        if let path = target.path { args.append(path) }

        do {
            let process = try Subprocess(executable: installation.launcher, arguments: args,
                                         environment: MoleLocator.environment(), stdinOpen: false)
            self.process = process
            Task { [weak self] in
                var stdout = Data()
                var stderr: [String] = []
                var code: Int32 = -1
                for await event in process.events {
                    switch event {
                    case .line(let line):
                        if line.stream == .stderr {
                            if !line.text.isEmpty { stderr.append(line.text) }
                        } else {
                            stdout.append(contentsOf: Array((line.raw + "\n").utf8))
                        }
                    case .partial: break
                    case .exited(let c): code = c
                    }
                }
                let decoded = await Self.decode(stdout)
                self?.finish(target: target, generation: myGeneration, started: started,
                             code: code, decoded: decoded, stderr: stderr)
            }
        } catch {
            scan = nil
            self.error = error.localizedDescription
        }
    }

    /// Decoding a large directory report can take a moment; keep it off the main actor.
    nonisolated private static func decode(_ data: Data) async -> Result<AnalyzeReport, Error> {
        await Task.detached(priority: .userInitiated) {
            Result {
                // Mole prints the JSON document alone, but tolerate stray leading text.
                let start = data.firstIndex(of: UInt8(ascii: "{")) ?? data.startIndex
                return try AnalyzeReport.decoder.decode(AnalyzeReport.self, from: Data(data[start...]))
            }
        }.value
    }

    private func finish(target: Target, generation: Int, started: Date, code: Int32,
                        decoded: Result<AnalyzeReport, Error>, stderr: [String]) {
        guard generation == self.generation else { return }
        process = nil
        scan = nil
        let duration = Date().timeIntervalSince(started)
        lastScanDuration = duration
        switch (code, decoded) {
        case (0, .success(let report)):
            if target == .overview { overview = report } else { self.report = report }
            onFinish?(target, report, nil, duration)
        default:
            let message: String
            if !stderr.isEmpty {
                message = stderr.joined(separator: "\n")
            } else if case .failure(let decodeError) = decoded, code == 0 {
                message = "Mole returned a report Burrow could not read (\(decodeError.localizedDescription))."
            } else {
                message = "Mole's analyzer stopped with exit code \(code)."
            }
            error = Self.friendly(message)
            onFinish?(target, nil, error, duration)
        }
    }

    private static func friendly(_ message: String) -> String {
        if message.contains("no such file or directory") { return "That folder no longer exists." }
        if message.contains("not a directory") { return "That item is not a folder." }
        if message.contains("operation not permitted") || message.contains("permission denied") {
            return "macOS blocked access to this folder. Grant Burrow Full Disk Access in System Settings so Mole can analyze it."
        }
        return message
    }

    // MARK: Trash

    /// Moves `path` to the Trash after the analyzer's safety rules pass, then refreshes Mole's cache
    /// the way the TUI does and rescans the current folder.
    func trash(_ path: String, service: MoleService) async throws {
        try AnalyzeTrashGuard.validate(path)
        let url = URL(fileURLWithPath: path)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }.value

        // invalidateCache(removedPath) + invalidateCache(currentDir), plus every ancestor whose total changed.
        AnalyzerCache.invalidate([path], overviewKeys: true)
        var ancestors: [String] = []
        var cursor = (path as NSString).deletingLastPathComponent
        while !cursor.isEmpty && cursor != "/" {
            ancestors.append(cursor)
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        AnalyzerCache.invalidate(ancestors)
        if let currentPath { AnalyzerCache.invalidateTree(currentPath) }

        notice = "Moved “\((path as NSString).lastPathComponent)” to the Trash."
        if selection == path { selection = nil }
        if let current { load(current, service: service, force: true) }
    }
}
