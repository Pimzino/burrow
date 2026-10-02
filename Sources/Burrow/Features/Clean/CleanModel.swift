import AppKit
import Foundation
import Observation

/// A mounted external volume that `mo clean --external` accepts.
struct CleanExternalVolume: Sendable, Equatable, Identifiable, Hashable {
    let path: String
    let name: String
    /// Identifies the physical volume, so a different drive mounted at the same path is noticed.
    let uuid: String?
    let capacity: Int64?
    let available: Int64?
    var id: String { path }

    /// Mounted, local, non-internal volumes directly under /Volumes (Mole refuses the rest).
    static func discover() -> [CleanExternalVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .isSymbolicLinkKey, .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let path = url.path
            guard (path as NSString).deletingLastPathComponent == "/Volumes" else { return nil }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            if v.volumeIsRootFileSystem == true || v.volumeIsInternal == true || v.volumeIsLocal == false || v.isSymbolicLink == true { return nil }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { return nil }
            return CleanExternalVolume(path: path, name: v.volumeName ?? url.lastPathComponent, uuid: v.volumeUUIDString,
                                       capacity: v.volumeTotalCapacity.map(Int64.init), available: v.volumeAvailableCapacity.map(Int64.init))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Exactly what a real `mo clean` would be started with. A scan records the configuration it previewed,
/// and the clean runs that same configuration or nothing.
struct CleanRunConfig: Sendable, Equatable {
    struct Volume: Sendable, Equatable {
        let path: String
        let name: String
        let uuid: String?
    }

    /// Arguments of the real run (the preview adds `--dry-run`).
    let arguments: [String]
    let environment: [String: String]
    let admin: Bool
    let volume: Volume?

    var previewArguments: [String] { arguments + ["--dry-run"] }
    var isExternal: Bool { volume != nil }
    var keepsTrash: Bool { environment["MOLE_SKIP_TRASH_CLEANUP"] == "1" }
    var includesSystem: Bool { admin }
}

@MainActor
@Observable
final class CleanModel {
    /// One model for the app session, so a scan or clean keeps its state when you switch screens.
    static let shared = CleanModel()

    enum Phase: Equatable {
        case idle, scanning, scanned, cleaning, cleaned
        case failed(String)
    }

    var phase: Phase = .idle
    private(set) var report = CleanReport()
    /// The scan the clean confirmation is based on (possibly partial; see `cleanBlocker`).
    private(set) var scanReport: CleanReport?
    /// The configuration `scanReport` previewed. A clean runs exactly this, or not at all.
    private(set) var scannedConfig: CleanRunConfig?
    private(set) var preview: CleanPreviewList?
    private(set) var run: CommandRun?
    private(set) var stderrMessages: [String] = []
    private(set) var inventory: CleanProtectionInventory?
    private(set) var protectedPaths: Set<String> = []
    var volumes: [CleanExternalVolume] = []
    var banner: String?

    var includeSystem: Bool = UserDefaults.standard.bool(forKey: "clean.includeSystem") {
        didSet {
            UserDefaults.standard.set(includeSystem, forKey: "clean.includeSystem")
            optionsDidChange()
        }
    }
    var keepTrash: Bool = UserDefaults.standard.bool(forKey: "clean.keepTrash") {
        didSet {
            UserDefaults.standard.set(keepTrash, forKey: "clean.keepTrash")
            optionsDidChange()
        }
    }
    var externalEnabled = false {
        didSet { optionsDidChange() }
    }
    var externalVolumePath: String? {
        didSet { optionsDidChange() }
    }

    @ObservationIgnored private var parser = CleanParser()
    @ObservationIgnored private var didAutorun = false
    @ObservationIgnored private var suppressOptionCheck = false
    /// Configuration and whitelist file of the scan in progress.
    @ObservationIgnored private var pendingConfig: CleanRunConfig?
    @ObservationIgnored private var pendingWhitelist: ConfigFileState?
    /// The whitelist file as it was when `scanReport` was made.
    @ObservationIgnored private var scannedWhitelist: ConfigFileState?

    var isBusy: Bool { phase == .scanning || phase == .cleaning }
    var externalVolume: CleanExternalVolume? {
        guard externalEnabled, let p = externalVolumePath else { return nil }
        return volumes.first { $0.path == p }
    }
    var isExternalMode: Bool { externalVolume != nil }

    /// Last preview on disk (from an earlier session), shown in the idle state.
    var lastPreviewDate: String? { preview?.generated }

    func onAppear(model: AppModel, service: MoleService) {
        refreshVolumes()
        if preview == nil, let text = MoleConfigIO.read(MolePaths.cleanPreview) { preview = CleanPreviewList.parse(text) }
        if inventory == nil {
            Task { await loadInventory(service: service) }
        }
        if model.automation.autorun && model.automation.route == .clean && !didAutorun {
            didAutorun = true
            scan(service: service, automation: model.automation)
        }
    }

    func refreshVolumes() {
        suppressOptionCheck = true
        volumes = CleanExternalVolume.discover()
        if externalVolumePath == nil || !volumes.contains(where: { $0.path == externalVolumePath }) {
            externalVolumePath = volumes.first?.path
        }
        suppressOptionCheck = false
        // A drive that was ejected, or replaced by another one at the same path, changes the target.
        guard !isBusy, let scannedConfig, scannedConfig != currentConfig else { return }
        if let volume = scannedConfig.volume {
            invalidateScan("\(volume.name), the drive you previewed, was ejected or replaced, so that preview was discarded. Scan again to clean a drive.")
        } else {
            optionsDidChange()
        }
    }

    func loadInventory(service: MoleService) async {
        inventory = await CleanProtectionInventory.load(service: service)
        refreshProtection()
    }

    private func refreshProtection() {
        guard let inventory, let preview else { return }
        let patterns = CleanWhitelistStore.enforcedPatterns(inventory: inventory)
        var set = Set<String>()
        for section in preview.sections {
            for entry in section.entries where patterns.contains(where: { WhitelistPattern.matches(path: entry.path, pattern: $0) }) {
                set.insert(entry.path)
            }
        }
        protectedPaths = set
    }

    // MARK: Configuration

    /// The configuration the current options describe.
    var currentConfig: CleanRunConfig {
        let volume = externalVolume
        var args = ["clean"]
        if let volume { args += ["--external", volume.path] }
        return CleanRunConfig(arguments: args,
                              environment: keepTrash ? ["MOLE_SKIP_TRASH_CLEANUP": "1"] : [:],
                              // Admin only matters for system caches, and never for an external volume.
                              admin: includeSystem && volume == nil,
                              volume: volume.map { .init(path: $0.path, name: $0.name, uuid: $0.uuid) })
    }

    /// Any option change that alters what a clean would do throws the preview away.
    private func optionsDidChange() {
        guard !suppressOptionCheck, !isBusy, let scannedConfig, scannedConfig != currentConfig else { return }
        invalidateScan("Options changed since the last scan, so its preview no longer matches what Mole would clean. Scan again to see the new result.")
    }

    private func invalidateScan(_ reason: String) {
        scanReport = nil
        scannedConfig = nil
        scannedWhitelist = nil
        if phase == .scanned {
            report = CleanReport()
            phase = .idle
        }
        banner = reason
    }

    /// Why the previewed scan can't be cleaned, or nil when it can.
    var cleanBlocker: String? {
        guard let scanReport, let scannedConfig else { return "Scan first so you can review what Mole would remove." }
        guard let summary = scanReport.summary else {
            return "The scan ended before Mole printed its summary, so it didn’t preview everything a clean would remove. Scan again to clean."
        }
        switch summary.outcome {
        case .complete:
            break
        case .cancelled, .interrupted:
            return "The scan was stopped before it finished, so sections after that point were never previewed. A clean would still run all of them. Scan again to clean."
        case .incomplete, .other:
            return "Mole skipped part of the scan (“\(summary.heading)”), so the preview doesn’t cover everything a clean would remove. Scan again to clean."
        }
        if summary.alreadyClean { return "Nothing significant to clean." }
        if scannedConfig != currentConfig {
            return "Options changed since the scan. Scan again to preview with the new settings."
        }
        return nil
    }

    var canClean: Bool { phase == .scanned && cleanBlocker == nil }

    // MARK: Scan

    func scan(service: MoleService, automation: Automation? = nil) {
        guard !isBusy else { return }
        let config = currentConfig
        begin(.scanning)
        scanReport = nil
        scannedConfig = nil
        scannedWhitelist = nil
        pendingConfig = config
        pendingWhitelist = MoleConfigIO.load(MolePaths.cleanWhitelist)
        let run = service.start(config.isExternal ? "Preview external volume clean" : "Scan for cleanable files",
                                config.previewArguments, admin: config.admin, environment: config.environment,
                                onLine: { [weak self] line in self?.ingest(line) })
        self.run = run
        run.onCompletion { [weak self] run in
            guard let self else { return }
            self.parser.finish()
            self.report = self.parser.report
            self.finishScan(run)
            if let automation, automation.autorun { self.recordAutomation(automation, run: run) }
        }
    }

    private func finishScan(_ run: CommandRun) {
        let config = pendingConfig
        let whitelist = pendingWhitelist
        pendingConfig = nil
        pendingWhitelist = nil
        func keep() {
            scanReport = report
            scannedConfig = config
            scannedWhitelist = whitelist
            phase = .scanned
        }
        switch run.state {
        case .cancelled:
            if report.sections.isEmpty {
                phase = .idle
            } else {
                keep()
            }
            banner = "Scan stopped. The results below are partial, so cleaning stays off until a scan finishes."
        case .failedToStart(let message):
            phase = .failed(message)
        case .finished(let code):
            if run.authFailed {
                phase = .failed("Administrator access was not granted. Turn off “Include system caches” to scan without it.")
            } else if report.summary == nil && report.sections.isEmpty {
                phase = .failed(errorText(code: code))
            } else {
                keep()
                if code != 0 { banner = report.summary?.messages.first ?? "Mole reported a problem (exit code \(code)). Some steps were skipped." }
                reloadPreview()
            }
        case .running:
            return
        }
        // Options can't change mid-scan from the UI, but a drive can be ejected or swapped meanwhile.
        if scanReport != nil, config != currentConfig {
            invalidateScan("Options or the selected drive changed while Mole was scanning. Scan again to preview the current settings.")
        }
    }

    private func reloadPreview() {
        guard scannedConfig?.isExternal != true else { preview = nil; return }
        let path = report.summary?.previewFile ?? MolePaths.cleanPreview
        if let text = MoleConfigIO.read(path) { preview = CleanPreviewList.parse(text) }
        refreshProtection()
    }

    private func recordAutomation(_ automation: Automation, run: CommandRun) {
        let s = report.summary
        let passed = run.exitCode == 0 && s != nil && s?.outcome == .complete
        var metrics: [String: String] = [
            "potential": s?.spaceText ?? "none",
            "items": s?.items.map(String.init) ?? "0",
            "categories": s?.categories.map(String.init) ?? "0",
            "sections": "\(report.sections.count)",
            "rows": "\(report.allRows.count)",
            "reviewRows": "\(report.reviewRows.count)",
            "exitCode": run.exitCode.map(String.init) ?? "none",
            "seconds": String(format: "%.0f", run.duration),
            "cleanAllowed": cleanBlocker == nil ? "yes" : "no",
        ]
        if let preview { metrics["previewSections"] = "\(preview.sections.count)" }
        automation.record("clean", passed: passed,
                          detail: s.map { "\($0.heading): \($0.spaceText ?? "nothing")" } ?? errorText(code: run.exitCode ?? -1),
                          metrics: metrics)
    }

    // MARK: Clean

    private enum Refusal {
        /// The preview can't be cleaned as it is (partial, nothing to clean); it stays on screen.
        case blocked(String)
        /// The preview no longer describes what a clean would do; it is discarded.
        case stale(String)
    }

    /// Re-checks, right before starting, that the real run would do what the preview showed.
    private func verifyBeforeClean() -> Refusal? {
        guard let scannedConfig else { return .blocked("Scan first so you can review what Mole would remove.") }
        if scannedConfig != currentConfig {
            return .stale("Options changed since the scan, so nothing was cleaned. Scan again to preview the new settings.")
        }
        if let blocker = cleanBlocker { return .blocked(blocker) }
        if let volume = scannedConfig.volume {
            let mounted = CleanExternalVolume.discover()
            guard let now = mounted.first(where: { $0.path == volume.path }), now.uuid == volume.uuid else {
                return .stale("\(volume.name) is no longer mounted, or a different drive is at \(volume.path). Nothing was cleaned.")
            }
        }
        // Rules removed from the whitelist since the scan would let Mole clean paths the preview protected.
        let before = scannedWhitelist ?? .missing
        let after = MoleConfigIO.load(MolePaths.cleanWhitelist)
        if before != after {
            let inventory = inventory ?? .fallback
            func enforced(_ state: ConfigFileState) -> Set<String> {
                let patterns: [String] = switch state {
                case .missing: inventory.defaults
                case .text(let t): CleanWhitelistFile.parse(t).patterns
                case .unreadable: []
                }
                return Set((WhitelistPattern.honoured(patterns) + inventory.safety).map { WhitelistPattern.expand($0) })
            }
            if !enforced(before).isSubset(of: enforced(after)) {
                return .stale("Protection rules were removed since the scan, so Mole could now clean paths the preview showed as protected. Nothing was cleaned; scan again to review.")
            }
        }
        return nil
    }

    func clean(service: MoleService) {
        guard !isBusy else { return }
        switch verifyBeforeClean() {
        case .blocked(let reason)?:
            banner = reason
            return
        case .stale(let reason)?:
            invalidateScan(reason)
            return
        case nil:
            break
        }
        guard let config = scannedConfig else { return }
        begin(.cleaning)
        let run = service.start(config.isExternal ? "Clean external volume" : "Clean your Mac",
                                config.arguments, admin: config.admin, environment: config.environment,
                                onLine: { [weak self] line in self?.ingest(line) })
        self.run = run
        run.onCompletion { [weak self] run in
            guard let self else { return }
            self.parser.finish()
            self.report = self.parser.report
            switch run.state {
            case .failedToStart(let message):
                self.phase = .failed(message)
            case .finished where run.authFailed:
                self.phase = .failed("Administrator access was not granted, so nothing was cleaned.")
            case .finished(let code) where self.report.summary == nil && self.report.sections.isEmpty:
                self.phase = .failed(self.errorText(code: code))
                self.consumeScan()
            case .running:
                return
            default:
                self.phase = .cleaned
                self.consumeScan()
                if run.state == .cancelled { self.banner = "Cleaning was stopped. Items already removed stay removed." }
            }
        }
    }

    /// A clean used up its preview: the next clean needs a new scan.
    private func consumeScan() {
        scanReport = nil
        scannedConfig = nil
        scannedWhitelist = nil
    }

    func cancel() { run?.cancel() }

    func startOver() {
        phase = .idle
        consumeScan()
        report = CleanReport()
        banner = nil
    }

    private func begin(_ phase: Phase) {
        parser = CleanParser()
        report = CleanReport()
        stderrMessages = []
        banner = nil
        self.phase = phase
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

    private func errorText(code: Int32) -> String {
        if let last = stderrMessages.last { return stderrMessages.count > 1 ? stderrMessages.suffix(2).joined(separator: "\n") : last }
        return "Mole stopped unexpectedly (exit code \(code))."
    }

    // MARK: Protect

    func isProtected(_ path: String) -> Bool { protectedPaths.contains(path) }

    /// Adds a literal path to the clean whitelist. Returns a user-facing error, or nil on success.
    func protect(_ path: String, service: MoleService) async -> String? {
        if inventory == nil { await loadInventory(service: service) }
        guard let inventory else { return "Mole’s protection rules couldn’t be loaded." }
        do {
            try CleanWhitelistStore.protect(path, inventory: inventory)
            refreshProtection()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
