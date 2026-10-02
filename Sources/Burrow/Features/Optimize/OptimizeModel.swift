import Foundation
import Observation

@MainActor
@Observable
final class OptimizeModel {
    /// One model for the app session, so a run keeps its state when you switch screens.
    static let shared = OptimizeModel()

    enum Mode: Equatable { case preview, optimize }
    enum Phase: Equatable {
        case idle, running(Mode), finished(Mode)
        /// Mole ended without its summary (or with some tasks unreported). The message says why.
        case incomplete(Mode, String)
        case failed(String)
    }

    private(set) var tasks: [OptimizeTask] = OptimizeCatalog.fallback
    private(set) var catalogFromMole = false
    private(set) var loaded = false
    private(set) var whitelist = OptimizeWhitelistFile(entries: [])
    private(set) var whitelistExists = false
    /// True when the rules come from Mole's legacy `whitelist_checks` file.
    private(set) var whitelistIsLegacy = false
    /// Set when the whitelist Mole reads exists but can't be read; toggles are disabled.
    private(set) var whitelistProblem: String?
    private(set) var report = OptimizeReport()
    private(set) var run: CommandRun?
    private(set) var stderrMessages: [String] = []
    var phase: Phase = .idle
    var saveMessage: String?
    var saveError: String?
    /// A dismissible note, for example after a run was stopped.
    var banner: String?

    var enableDiskVerify: Bool = UserDefaults.standard.bool(forKey: "optimize.diskVerify") {
        didSet { UserDefaults.standard.set(enableDiskVerify, forKey: "optimize.diskVerify") }
    }

    @ObservationIgnored private var parser = OptimizeParser(tasks: OptimizeCatalog.fallback)
    @ObservationIgnored private var didAutorun = false
    @ObservationIgnored private var saveToken = 0

    var isRunning: Bool { if case .running = phase { true } else { false } }
    var runningMode: Mode? { if case .running(let m) = phase { m } else { nil } }
    /// The mode of the run whose results are on screen (finished or incomplete).
    var resultMode: Mode? {
        switch phase {
        case .finished(let m), .incomplete(let m, _): m
        default: nil
        }
    }
    var canEditWhitelist: Bool { !isRunning && whitelistProblem == nil }
    var taskIDs: Set<String> { Set(tasks.map(\.id)) }
    var includedTasks: [OptimizeTask] { tasks.filter { !whitelist.excludes(task: $0.id) } }
    var excludedTasks: [OptimizeTask] { tasks.filter { whitelist.excludes(task: $0.id) } }
    var pathPatterns: [String] { whitelist.pathPatterns(taskIDs: taskIDs) }

    func onAppear(model: AppModel, service: MoleService) async {
        if !loaded {
            let (tasks, fromMole) = await OptimizeCatalog.load(service: service)
            self.tasks = tasks
            catalogFromMole = fromMole
            parser = OptimizeParser(tasks: tasks)
            loaded = true
        }
        reloadWhitelist()
        if model.automation.autorun && model.automation.route == .optimize && !didAutorun {
            didAutorun = true
            start(.preview, service: service, automation: model.automation)
        }
    }

    // MARK: Whitelist

    func reloadWhitelist() {
        // Mole falls back to the legacy `whitelist_checks` when `whitelist_optimize` is absent.
        let snapshot = OptimizeWhitelistStore.load()
        whitelist = snapshot.file
        whitelistExists = snapshot.exists
        whitelistIsLegacy = snapshot.source == .legacy && snapshot.problem == nil
        whitelistProblem = snapshot.problem
    }

    func isIncluded(_ task: OptimizeTask) -> Bool { !whitelist.excludes(task: task.id) }

    func setIncluded(_ task: OptimizeTask, _ included: Bool) {
        // Re-read first so edits made elsewhere (Protection, the CLI) are not lost.
        reloadWhitelist()
        var updated = whitelist
        updated.set(task: task.id, excluded: !included)
        if let problem = whitelistProblem {
            saveError = ConfigFileError.refusing(problem).message
            return
        }
        guard updated != whitelist else { return }
        do {
            // When the rules came from the legacy file, `updated` carries them into whitelist_optimize.
            try OptimizeWhitelistStore.save(updated)
            reloadWhitelist()
            saveError = nil
            flashSaved(included ? "\(task.displayName) included" : "\(task.displayName) skipped")
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func flashSaved(_ message: String) {
        saveToken += 1
        let token = saveToken
        saveMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if self?.saveToken == token { self?.saveMessage = nil }
        }
    }

    // MARK: Runs

    func start(_ mode: Mode, service: MoleService, automation: Automation? = nil) {
        guard !isRunning else { return }
        banner = nil
        parser = OptimizeParser(tasks: tasks)
        report = OptimizeReport()
        stderrMessages = []
        phase = .running(mode)
        var args = ["optimize"]
        if mode == .preview { args.append("--dry-run") }
        let env = enableDiskVerify ? ["MOLE_ENABLE_DISK_VERIFY": "1"] : [:]
        let run = service.start(mode == .preview ? "Preview optimizations" : "Optimize your Mac", args,
                                admin: mode == .optimize, environment: env,
                                onLine: { [weak self] line in self?.ingest(line) })
        self.run = run
        run.onCompletion { [weak self] run in
            guard let self else { return }
            self.parser.finish()
            self.report = self.parser.report
            self.complete(run, mode: mode)
            if let automation, automation.autorun { self.record(automation, run: run) }
        }
    }

    func cancel() { run?.cancel() }

    private func complete(_ run: CommandRun, mode: Mode) {
        switch run.state {
        case .failedToStart(let message):
            phase = .failed(message)
        case .cancelled:
            // Never shown as success: a stopped run has no summary, and a real run may be half done.
            phase = .idle
            banner = mode == .preview
                ? "Preview stopped. Nothing was changed."
                : "Optimization stopped. Tasks that had already run stay applied; the rest were skipped."
        case .finished where run.authFailed:
            phase = .failed("Administrator access was not granted, so nothing was changed.")
        case .finished(let code) where report.summary == nil && report.tasks.isEmpty:
            phase = .failed(stderrText ?? "Mole stopped unexpectedly (exit code \(code)).")
        case .finished(let code) where report.summary == nil:
            // Tasks ran but Mole never printed its summary (for example "Optimize task outcomes are incomplete").
            let reason = stderrText ?? "Mole ended without a summary (exit code \(code))."
            phase = .incomplete(mode, mode == .preview
                ? reason + " The preview is incomplete, so some tasks weren’t checked."
                : reason + " Some tasks may not have run.")
        case .finished:
            // Exit code 1 with failed tasks is Mole's "needs attention", shown in the summary.
            phase = .finished(mode)
        case .running:
            break
        }
    }

    /// The last couple of meaningful stderr lines, if any.
    private var stderrText: String? {
        stderrMessages.isEmpty ? nil : stderrMessages.suffix(2).joined(separator: "\n")
    }

    private func ingest(_ line: OutputLine) {
        switch line.stream {
        case .stdout:
            parser.consume(line.text)
            report = parser.report
        case .stderr:
            let t = line.text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("[DEBUG]") { stderrMessages.append(t.hasPrefix("☻ ") ? String(t.dropFirst(2)) : t) }
        case .tty:
            break
        }
    }

    private func record(_ automation: Automation, run: CommandRun) {
        let s = report.summary
        let seen = report.tasks.count
        let passed = s != nil && (run.exitCode == 0 || run.exitCode == 1) && seen > 0
        var metrics: [String: String] = [
            "exitCode": run.exitCode.map(String.init) ?? "none",
            "tasksSeen": "\(seen)",
            "catalogTasks": "\(tasks.count)",
            "catalogFromMole": catalogFromMole ? "yes" : "no",
            "wouldApply": s?.applied.map(String.init) ?? "none",
            "diagnosisLines": "\(report.diagnosis.count)",
            "system": report.system.map { "\(Int($0.ramUsed))/\(Int($0.ramTotal))GB RAM, \(Int($0.diskUsed))/\(Int($0.diskTotal))GB disk" } ?? "none",
        ]
        for (k, v) in s?.outcomes ?? [:] { metrics["outcome." + k] = "\(v)" }
        for state in ["applied", "attention", "unavailable", "excluded"] {
            metrics["state." + state] = "\(report.tasks.values.filter { "\($0.state)" == state }.count)"
        }
        automation.record("optimize", passed: passed, detail: s?.heading ?? (stderrMessages.last ?? "No summary"), metrics: metrics)
    }
}
