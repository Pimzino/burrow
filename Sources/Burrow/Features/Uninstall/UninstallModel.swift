import AppKit
import Foundation
import Observation

enum AppSource: String, CaseIterable, Identifiable, Sendable {
    case app, homebrew, appStore, steam
    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "App"
        case .homebrew: "Homebrew"
        case .appStore: "App Store"
        case .steam: "Steam"
        }
    }

    var symbol: String {
        switch self {
        case .app: "app.dashed"
        case .homebrew: "mug.fill"
        case .appStore: "bag.fill"
        case .steam: "gamecontroller.fill"
        }
    }
}

/// An installed app merged with Mole's metadata cache.
struct AppEntry: Identifiable, Hashable, Sendable {
    let app: InstalledApp
    var sizeBytes: Int64?
    var lastUsed: Date?
    var source: AppSource

    var id: String { app.path }
    var name: String { app.cleanName }
    var sizeText: String { sizeBytes.map { ByteFormat.string($0) } ?? (app.isSteam ? "Steam" : "—") }
    var parentWritable: Bool {
        FileManager.default.isWritableFile(atPath: (app.path as NSString).deletingLastPathComponent)
    }
    /// Needs administrator access for a real uninstall.
    var needsAdmin: Bool { app.isHomebrew || !parentWritable }

    static func make(_ app: InstalledApp, metadata: AppMetadata?) -> AppEntry {
        var size = app.sizeBytes
        if size == nil, let kb = metadata?.sizeKB, kb > 0 { size = kb * 1024 }
        let source: AppSource
        if app.isSteam { source = .steam }
        else if app.isHomebrew { source = .homebrew }
        else if FileManager.default.fileExists(atPath: app.path + "/Contents/_MASReceipt/receipt") { source = .appStore }
        else { source = .app }
        return AppEntry(app: app, sizeBytes: size, lastUsed: metadata?.lastUsed, source: source)
    }
}

/// Caches `mo uninstall --list` for the app session so revisiting the page is instant.
@MainActor
@Observable
final class UninstallStore {
    static let shared = UninstallStore()

    private(set) var apps: [AppEntry] = []
    private(set) var isLoading = false
    private(set) var isRefreshingSizes = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    private(set) var lastDuration: TimeInterval?
    /// When the current `apps` came from Mole (a load or a background size refresh).
    @ObservationIgnored private var listFetchedAt: Date?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sizeRefreshScheduled = false

    var hasLoaded: Bool { loadedAt != nil }
    var totalBytes: Int64 { apps.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    func loadIfNeeded(service: MoleService) async {
        guard !hasLoaded, !isLoading else { return }
        await load(service: service)
    }

    func load(service: MoleService) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        generation += 1
        let started = Date()
        do {
            let list = try await Self.fetchList(service: service)
            apply(list)
            lastDuration = Date().timeIntervalSince(started)
            loadedAt = Date()
            scheduleSizeRefreshIfNeeded(service: service, list: list)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// `mo uninstall --list` prints JSON when stdout is piped. Its keys are snake_case, so decode with
    /// `InstalledApp.decoder` (MoleService.json uses a plain decoder).
    static func fetchList(service: MoleService) async throws -> [InstalledApp] {
        let result = try await service.collect(["uninstall", "--list"], timeout: 900)
        guard result.succeeded || !result.stdout.isEmpty else {
            throw MoleError.commandFailed(result.stderrString.isEmpty ? "Exit code \(result.exitCode)" : result.stderrString)
        }
        do {
            return try InstalledApp.decoder.decode([InstalledApp].self, from: MoleService.extractJSON(result.stdout))
        } catch {
            throw MoleError.decodeFailed("\(error)")
        }
    }

    private func apply(_ list: [InstalledApp]) {
        let metadata = AppMetadata.loadAll()
        apps = list.map { AppEntry.make($0, metadata: metadata[$0.path]) }
        listFetchedAt = Date()
    }

    /// The app list as Mole sees it now: reuses the cached list when it was read in the last
    /// `maxAge` seconds, otherwise asks Mole again (and updates the page with the result).
    func freshList(service: MoleService, maxAge: TimeInterval = 120) async throws -> [AppEntry] {
        if let listFetchedAt, Date().timeIntervalSince(listFetchedAt) < maxAge, !apps.isEmpty { return apps }
        let list = try await Self.fetchList(service: service)
        generation += 1
        apply(list)
        loadedAt = Date()
        error = nil
        return apps
    }

    // MARK: Active uninstall

    /// The uninstall in progress (or its result). It lives here, not in the view, so leaving the
    /// page never strands a Mole run waiting at a prompt: coming back shows it again.
    private(set) var session: UninstallSession?
    /// True while the Uninstall page is on screen (the session declines an unattended review sooner).
    @ObservationIgnored var pageVisible = false

    var hasActiveSession: Bool { session?.isActive ?? false }

    /// Starts an uninstall (or preview) of `apps` unless one is already running.
    @discardableResult
    func begin(_ apps: [AppEntry], dryRun: Bool, permanent: Bool, service: MoleService,
               autoConfirm: Duration? = nil, onFinish: ((UninstallSession) -> Void)? = nil) -> UninstallSession? {
        guard !apps.isEmpty, !hasActiveSession else { return nil }
        let session = UninstallSession(apps: apps, dryRun: dryRun, permanent: permanent)
        self.session = session
        Task { [weak self] in
            await session.start(service: service, store: self, autoConfirmAfter: autoConfirm)
            onFinish?(session)
            guard let self else { return }
            if session.phase == .finished, !session.dryRun {
                self.refreshAfterUninstall(service: service)
            } else if session.didChangeList {
                // Mole's view of an app differed from the page's; show the current list.
                Task { await self.load(service: service) }
            }
            if session.phase == .cancelled, self.session === session {
                self.session = nil
            }
        }
        return session
    }

    /// Clears a finished session's result card. An active session cannot be dismissed.
    func dismissSession() {
        guard let session, !session.isActive else { return }
        self.session = nil
    }

    /// Cold runs report "--" for sizes Mole is still computing in the background; fetch once more later.
    private func scheduleSizeRefreshIfNeeded(service: MoleService, list: [InstalledApp]) {
        guard !sizeRefreshScheduled, list.contains(where: { $0.size.trimmingCharacters(in: .whitespaces) == "--" }) else { return }
        sizeRefreshScheduled = true
        let myGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, self.generation == myGeneration, !self.isLoading else { return }
            self.isRefreshingSizes = true
            if let fresh = try? await Self.fetchList(service: service), self.generation == myGeneration {
                self.apply(fresh)
            }
            self.isRefreshingSizes = false
        }
    }

    /// Drops apps that no longer exist on disk (after an uninstall) and reloads in the background.
    func refreshAfterUninstall(service: MoleService) {
        apps.removeAll { !FileManager.default.fileExists(atPath: $0.app.path) }
        Task { await load(service: service) }
    }
}

/// Drives one `mo uninstall` run through Mole's two prompts.
///
/// Safety model:
/// - Before Mole starts, the selection is checked against a recent app list. Every selected app
///   must still be installed, and must be the only app Mole could match by that name (Mole's CLI
///   matches by name only).
/// - PROMPT 1 ("Proceed with uninstallation? [y/N]") is answered at most once. It gets "y" only
///   when Mole's matched rows are exactly the selected apps (name and size, in order); otherwise "n".
/// - PROMPT 2 treats Enter *and* EOF as "confirm". It is answered with "\n" only after the user
///   confirms in the review sheet, and with "q" otherwise (cancel, timeout, unattended review).
///   stdin is never closed.
/// - The session stays active until Mole has really exited, so a second run cannot overlap it.
@MainActor
@Observable
final class UninstallSession: Identifiable {
    enum Phase: Equatable {
        /// Checking the selection against a fresh app list (Mole has not started yet).
        case checking
        case starting
        case scanning
        case review
        case removing
        /// Cancel requested; waiting for Mole to exit.
        case cancelling
        case finished
        case cancelled
        case failed(String)
    }

    /// How long an unanswered review waits before Mole is told to cancel.
    static let reviewTimeout: TimeInterval = 30 * 60
    /// The same while the Uninstall page is not on screen, where nobody can see the review.
    static let unattendedReviewTimeout: TimeInterval = 5 * 60

    let id = UUID()
    /// The selected apps (replaced by their fresh list entries once checked).
    private(set) var apps: [AppEntry]
    let dryRun: Bool
    let permanent: Bool
    private(set) var phase: Phase = .checking
    private(set) var parser = UninstallParser()
    private(set) var run: CommandRun?
    private(set) var confirmInfo: (count: Int, size: String?, running: Bool)?
    /// True until `start` has returned: Mole has exited (or never started).
    private(set) var isActive = true
    /// Set when Mole's view of an app differed from the page's list.
    @ObservationIgnored private(set) var didChangeList = false

    @ObservationIgnored private var expected: [UninstallParser.ExpectedMatch] = []
    @ObservationIgnored private var answeredProceed = false
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var decision: Bool?
    @ObservationIgnored private var reviewShownAt: Date?

    init(apps: [AppEntry], dryRun: Bool, permanent: Bool) {
        self.apps = apps
        self.dryRun = dryRun
        self.permanent = permanent
    }

    var admin: Bool { !dryRun && apps.contains { $0.needsAdmin } }

    var arguments: [String] {
        var args = ["uninstall"]
        if dryRun { args.append("--dry-run") }
        if permanent { args.append("--permanent") }
        args.append(contentsOf: apps.map(\.app.matchName))
        return args
    }

    var totalPreviewBytes: Int64 {
        parser.apps.reduce(0) { $0 + (ByteFormat.parse($1.size) ?? 0) }
    }

    /// Runs the whole protocol. Returns only when Mole has exited (or was never started).
    func start(service: MoleService, store: UninstallStore?, autoConfirmAfter: Duration? = nil) async {
        defer { isActive = false }

        if let problem = await checkSelection(service: service, store: store) {
            phase = cancelRequested ? .cancelled : .failed(problem + " Nothing was removed.")
            return
        }
        if cancelRequested { phase = .cancelled; return }

        phase = .starting
        let run = service.start(dryRun ? "Preview uninstall" : "Uninstall apps", arguments, admin: admin,
                                keepInputOpen: true, onLine: { [weak self] line in self?.parser.feed(line) })
        self.run = run

        // PROMPT 1: "Proceed with uninstallation? [y/N]" after the matched list.
        let gotProceed = await MoleRunDriver.wait(for: run, timeout: 900) {
            cancelRequested || UninstallParser.isProceedPrompt(run.pendingPrompt)
        }
        if cancelRequested { return await finishCancelled(run) }
        guard gotProceed, run.state.isRunning else {
            return await finishEarly(run, fallback: "Mole stopped before it could list the apps.")
        }
        phase = .scanning
        if let problem = UninstallParser.verify(matched: parser.matched, expectedCount: parser.matchedCount, expected: expected) {
            if case .sizeChanged = problem { didChangeList = true }
            answerProceed(run, yes: false)
            await settle(run)
            phase = .failed(problem.message + " Nothing was removed.")
            return
        }
        answerProceed(run, yes: true)

        // Mole now scans each app's leftovers, then shows PROMPT 2.
        let gotConfirm = await MoleRunDriver.wait(for: run, timeout: 1800) {
            cancelRequested || UninstallParser.isConfirmPrompt(run.pendingPrompt)
        }
        if cancelRequested { return await finishCancelled(run) }
        guard gotConfirm, run.state.isRunning else {
            return await finishEarly(run, fallback: "Mole could not prepare the uninstall. Nothing was removed.")
        }
        reviewShownAt = Date()
        confirmInfo = UninstallParser.parseConfirmPrompt(run.pendingPrompt)
        if let problem = planProblem() {
            phase = .cancelling
            await MoleRunDriver.stop(run, answering: "q")
            phase = .failed(problem + " Nothing was removed.")
            return
        }
        phase = .review

        let (confirmed, expired) = await awaitDecision(run: run, store: store, autoConfirmAfter: autoConfirmAfter)

        guard run.state.isRunning else {
            return await finishEarly(run, fallback: "Mole exited before confirmation. Nothing was removed.")
        }
        if confirmed {
            // Mole drains stdin for ~10 ms around the read; give it a comfortable margin.
            if let shown = reviewShownAt {
                let elapsed = Date().timeIntervalSince(shown)
                if elapsed < 0.25 { await MoleRunDriver.pause(.milliseconds(Int((0.25 - elapsed) * 1000))) }
            }
            guard run.state.isRunning else {
                return await finishEarly(run, fallback: "Mole exited before confirmation. Nothing was removed.")
            }
            phase = .removing
            run.send("\n")
            _ = await run.waitUntilExit()
            if let summary = parser.summary, !summary.heading.isEmpty {
                phase = .finished
            } else if run.authFailed {
                phase = .failed("Administrator access was not granted, so nothing was removed.")
            } else if run.succeeded {
                phase = .finished
            } else {
                phase = .failed(errorText(fallback: "Mole reported a problem while uninstalling."))
            }
        } else {
            phase = .cancelling
            await MoleRunDriver.stop(run, answering: "q")
            phase = expired
                ? .failed("The review was left unanswered, so Mole was told to cancel. Nothing was removed.")
                : .cancelled
        }
    }

    /// Confirms the review. Ignored unless the review is showing and still unanswered.
    func confirm() {
        guard phase == .review, decision == nil else { return }
        decision = true
    }

    /// Cancels at whatever stage the run is in. Never closes stdin, and never answers a prompt twice.
    func cancel() {
        guard isActive, !cancelRequested else { return }
        switch phase {
        case .review:
            if decision == nil { decision = false }
        case .checking, .starting, .scanning:
            cancelRequested = true
            phase = .cancelling
            guard let run, run.state.isRunning else { return }
            if !answeredProceed && UninstallParser.isProceedPrompt(run.pendingPrompt) {
                answerProceed(run, yes: false)
            } else if answeredProceed && UninstallParser.isConfirmPrompt(run.pendingPrompt) {
                // At PROMPT 2 before the review appeared: `start` answers it with "q".
            } else {
                // Nothing has been changed before the final confirmation; Mole's trap exits cleanly.
                run.cancel()
            }
        default:
            break
        }
    }

    // MARK: Steps

    /// Resolves the selection against a recent app list and refuses anything Mole could confuse.
    private func checkSelection(service: MoleService, store: UninstallStore?) async -> String? {
        let current: [AppEntry]
        if let store {
            do {
                // A real uninstall needs an up-to-date list: a newly installed app with the same
                // name would change what Mole matches.
                current = try await store.freshList(service: service, maxAge: dryRun ? 600 : 120)
            } catch {
                return "The app list could not be re-read (\(error.localizedDescription))."
            }
        } else {
            current = apps
        }
        var resolved: [AppEntry] = []
        for app in apps {
            guard let fresh = current.first(where: { $0.app.path == app.app.path }),
                  FileManager.default.fileExists(atPath: app.app.path) else {
                didChangeList = true
                return "“\(app.name)” is no longer installed at \(MoleHomeDir.abbreviate(app.app.path))."
            }
            if let clash = UninstallParser.ambiguity(for: fresh.app, among: current.map(\.app)) {
                return clash
            }
            resolved.append(fresh)
        }
        apps = resolved
        expected = resolved.map { UninstallParser.ExpectedMatch(name: $0.app.name, size: $0.app.size) }
        return nil
    }

    /// Answers PROMPT 1 exactly once.
    private func answerProceed(_ run: CommandRun, yes: Bool) {
        guard !answeredProceed else { return }
        answeredProceed = true
        run.send(yes ? "y\n" : "n\n")
    }

    /// Mole's removal plan and PROMPT 2 must cover exactly the selected apps.
    private func planProblem() -> String? {
        if let problem = UninstallParser.verifyPreview(parser.apps, expected: expected) { return problem }
        guard let info = confirmInfo else { return "Mole's confirmation prompt could not be read." }
        guard info.count == apps.count else {
            return "Mole is about to remove \(info.count) app\(info.count == 1 ? "" : "s") but you selected \(apps.count)."
        }
        return nil
    }

    /// Waits for the user's answer to the review, declining it when it is left unattended.
    /// - Returns: whether to confirm, and whether the review expired.
    private func awaitDecision(run: CommandRun, store: UninstallStore?, autoConfirmAfter: Duration?) async -> (Bool, Bool) {
        if let autoConfirmAfter, dryRun {
            // Automation only, and only for dry runs.
            let until = Date().addingTimeInterval(TimeInterval(autoConfirmAfter.components.seconds))
            await MoleRunDriver.hold(run) { decision == nil && Date() < until }
            return (decision ?? true, false)
        }
        let shown = reviewShownAt ?? Date()
        var hiddenSince: Date?
        var expired = false
        await MoleRunDriver.hold(run) {
            guard decision == nil else { return false }
            if store?.pageVisible == false { hiddenSince = hiddenSince ?? Date() } else { hiddenSince = nil }
            let now = Date()
            if now.timeIntervalSince(shown) > Self.reviewTimeout
                || (hiddenSince.map { now.timeIntervalSince($0) > Self.unattendedReviewTimeout } ?? false) {
                expired = true
                return false
            }
            return true
        }
        if expired && decision == nil { decision = false }
        return (decision ?? false, expired && decision == false)
    }

    /// After declining PROMPT 1, Mole prints "Aborted." and exits; make sure it really does.
    private func settle(_ run: CommandRun) async {
        _ = await MoleRunDriver.wait(for: run, timeout: 15) { false }
        await MoleRunDriver.stop(run, answering: nil)
    }

    private func finishCancelled(_ run: CommandRun) async {
        phase = .cancelling
        // At PROMPT 2 the answer is "q" (never EOF, which would confirm). Before it, `cancel()`
        // already answered PROMPT 1 with "n" or interrupted Mole.
        let atConfirm = answeredProceed && UninstallParser.isConfirmPrompt(run.pendingPrompt)
        await MoleRunDriver.stop(run, answering: atConfirm ? "q" : nil, grace: 8)
        phase = .cancelled
    }

    private func finishEarly(_ run: CommandRun, fallback: String) async {
        if run.state.isRunning {
            // Timed out waiting for Mole (a prompt may have been missed). Nothing has been confirmed:
            // answer whichever prompt Mole may be waiting at with "no", then stop it.
            let key = answeredProceed ? "q" : "n\n"
            answeredProceed = true
            phase = .cancelling
            await MoleRunDriver.stop(run, answering: key)
            phase = .failed("Mole took too long to respond. Nothing was removed.")
            return
        }
        if run.authFailed {
            phase = .failed("Administrator access was not granted, so nothing was removed.")
        } else if parser.noMatch {
            didChangeList = true
            phase = .failed("Mole could not find the selected app. It may already have been removed.")
        } else {
            phase = .failed(errorText(fallback: fallback))
        }
    }

    private func errorText(fallback: String) -> String {
        var parts: [String] = []
        parts.append(contentsOf: parser.errors)
        parts.append(contentsOf: parser.warnings)
        if case .failedToStart(let message) = run?.state { parts.append(message) }
        return parts.isEmpty ? fallback : parts.joined(separator: "\n")
    }
}
