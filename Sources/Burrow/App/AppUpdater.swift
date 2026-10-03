import AppKit
import Foundation
import Observation

/// Checks GitHub for new Burrow releases and installs them (see Core/AppUpdate.swift for the trust model).
///
/// Automatic checks run at most once a day while Burrow is open. When one finds a version the user hasn't
/// skipped, `prompt` is set and the main window opens the Software Update window.
@MainActor
@Observable
final class AppUpdater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, Double)
        case verifying(AppRelease)
        case installing(AppRelease)
        case failed(String, AppRelease?)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle
    /// The newest release that is newer than this copy (shown in the sidebar), if any.
    private(set) var newer: AppRelease?
    /// Set by an automatic check that found something worth showing; cleared when the window opens.
    var prompt: AppRelease?
    let currentVersion = UpdateConfig.currentVersion

    var automaticChecks: Bool {
        get { access(keyPath: \.automaticChecks); return !defaults.bool(forKey: Keys.disableAutomatic) }
        set { withMutation(keyPath: \.automaticChecks) { defaults.set(!newValue, forKey: Keys.disableAutomatic) } }
    }
    var includePrereleases: Bool {
        get { access(keyPath: \.includePrereleases); return defaults.bool(forKey: Keys.prereleases) }
        set { withMutation(keyPath: \.includePrereleases) { defaults.set(newValue, forKey: Keys.prereleases) } }
    }
    private(set) var lastChecked: Date? {
        get { access(keyPath: \.lastChecked); return defaults.object(forKey: Keys.lastChecked) as? Date }
        set { withMutation(keyPath: \.lastChecked) { defaults.set(newValue, forKey: Keys.lastChecked) } }
    }
    private(set) var skippedVersion: String? {
        get { access(keyPath: \.skippedVersion); return defaults.string(forKey: Keys.skipped) }
        set { withMutation(keyPath: \.skippedVersion) { defaults.set(newValue, forKey: Keys.skipped) } }
    }

    /// Asked before installing: true while Mole tasks run (quitting would interrupt them).
    @ObservationIgnored var hasRunningTasks: @MainActor () -> Bool = { false }
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?

    private enum Keys {
        static let disableAutomatic = "burrowUpdateDisableAutomaticChecks"
        static let prereleases = "burrowUpdateIncludePrereleases"
        static let lastChecked = "burrowUpdateLastChecked"
        static let skipped = "burrowUpdateSkippedVersion"
    }

    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Clears leftovers of earlier attempts and starts the daily schedule.
    func start(automatic: Bool = true) {
        UpdateInstaller.cleanUp()
        guard automatic, scheduler == nil else { return }
        scheduler = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))   // let launch work (locating Mole, first status) go first
            while !Task.isCancelled {
                guard let self else { return }
                if self.automaticChecks, Date().timeIntervalSince(self.lastChecked ?? .distantPast) >= Self.checkInterval {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    // MARK: Checking

    /// Looks for a newer release. A user-initiated check reports every outcome (including "up to date"
    /// and errors) and ignores "Skip This Version"; an automatic one stays quiet unless there's news.
    func check(userInitiated: Bool) async {
        if phase.isBusy { return }
        if !userInitiated, case .available = phase { return }
        let previous = phase
        if userInitiated { phase = .checking }
        do {
            let release = try await ReleaseFeed.newest(includePrereleases: includePrereleases)
            lastChecked = Date()
            if let release, let currentVersion, release.version > currentVersion {
                newer = release
                if userInitiated || release.version.description != skippedVersion {
                    phase = .available(release)
                    if !userInitiated { prompt = release }
                } else if previous == .idle {
                    phase = .idle
                }
            } else {
                newer = nil
                phase = userInitiated || previous != .idle ? .upToDate : .idle
            }
        } catch {
            if userInitiated { phase = .failed(Self.describe(error), nil) } else { phase = previous }
        }
    }

    func skip(_ release: AppRelease) {
        skippedVersion = release.version.description
        phase = .idle
    }

    /// The window closed: stop a download, and forget one-off outcomes (the offer itself stays).
    func dismiss() {
        switch phase {
        case .downloading: work?.cancel()
        case .upToDate, .failed: phase = newer.map { .available($0) } ?? .idle
        default: break
        }
    }

    // MARK: Installing

    func blocker(for release: AppRelease) -> String? {
        if let reason = UpdateInstaller.blocker(for: release) { return reason }
        if hasRunningTasks() { return "A Mole task is running. Wait for it to finish, or stop it, then install the update." }
        return nil
    }

    /// Downloads, verifies, swaps in the new version and relaunches. `relaunch: false` (E2E) still
    /// installs but leaves quitting to the caller.
    func install(_ release: AppRelease, relaunch: Bool = true, onInstalled: (@MainActor (URL) -> Void)? = nil) {
        guard !phase.isBusy, blocker(for: release) == nil else { return }
        phase = .downloading(release, 0)
        work = Task { [weak self] in
            do {
                let (dmg, signature) = try await UpdateInstaller.download(release) { fraction in
                    Task { @MainActor in
                        guard let self, case .downloading(let r, let old) = self.phase, fraction > old else { return }
                        self.phase = .downloading(r, fraction)
                    }
                }
                try Task.checkCancellation()
                self?.phase = .verifying(release)
                try UpdateInstaller.verify(dmg: dmg, signature: signature, release: release)
                let staged = try await UpdateInstaller.stage(dmg: dmg, release: release)
                try Task.checkCancellation()
                self?.phase = .installing(release)
                // Last look before the point of no return: a task may have started meanwhile.
                if self?.hasRunningTasks() == true {
                    try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                    throw UpdateError.install("A Mole task started while the update was downloading. Install again when it has finished.")
                }
                let installed = try await UpdateInstaller.swapIn(staged: staged)
                UpdateInstaller.cleanUp()
                onInstalled?(installed)
                if relaunch {
                    try UpdateInstaller.scheduleRelaunch(of: installed)
                    NSApp.terminate(nil)
                }
            } catch is CancellationError {
                UpdateInstaller.cleanUp()
                self?.phase = .available(release)
            } catch let error as URLError where error.code == .cancelled {
                UpdateInstaller.cleanUp()
                self?.phase = .available(release)
            } catch {
                UpdateInstaller.cleanUp()
                self?.phase = .failed(Self.describe(error), release)
            }
        }
    }

    func cancelInstall() {
        guard case .downloading = phase else { return }
        work?.cancel()
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You're offline. Connect to the internet and try again."
            case .timedOut: return "GitHub took too long to answer. Try again later."
            default: return "Couldn't reach GitHub (\(error.localizedDescription))."
            }
        }
        return error.localizedDescription
    }
}
