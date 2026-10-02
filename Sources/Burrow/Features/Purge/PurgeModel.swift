import Foundation
import Observation

enum PurgeScanPaths {
    static let defaults = ["~/www", "~/dev", "~/Projects", "~/GitHub", "~/Code", "~/Workspace", "~/Repos", "~/Development",
                           "~/Library/CloudStorage", "~/.codex/worktrees", "~/.claude/worktrees"]

    /// Configured scan roots (empty when Mole uses discovery/defaults), and a problem when the file
    /// exists but can't be read.
    static func configured() -> (paths: [String], problem: String?) {
        let snapshot = PurgePathsStore.load()
        return (snapshot.file.paths.map { WhitelistPattern.portable($0) }, snapshot.problem)
    }

    static var scanningFile: String {
        let env = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"] ?? ""
        return (env.isEmpty ? MoleHomeDir.path + "/.cache" : env) + "/mole/purge_scanning"
    }
}

struct PurgeProject: Identifiable, Hashable {
    var displayPath: String
    var artifacts: [PurgeArtifact]
    var id: String { displayPath }
    var name: String { (displayPath as NSString).lastPathComponent }
    var bytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
}

/// A whitelist entry that protects one purge artifact.
struct PurgeProtectedEntry: Identifiable, Hashable {
    /// The line as written in the whitelist (possibly glob-escaped).
    let pattern: String
    /// The artifact path it protects, in `~` form.
    let path: String
    var id: String { pattern }
    var type: String { (path as NSString).lastPathComponent }
}

/// What a fresh dry run found that the confirmed list did not have. Nothing was purged.
struct PurgeListChange: Equatable {
    var added: [PurgeArtifact]
    var removedCount: Int
}

@MainActor
@Observable
final class PurgeStore {
    static let shared = PurgeStore()

    enum Phase: Equatable { case idle, scanning, ready, verifying, purging, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var scan = PurgeParser()
    private(set) var scanRun: CommandRun?
    private(set) var verifyRun: CommandRun?
    private(set) var purgeRun: CommandRun?
    private(set) var currentRoot: String?
    private(set) var scannedAt: Date?
    private(set) var purgeResult: PurgeSummary?
    private(set) var purgeErrors: [String] = []
    private(set) var protected: [PurgeProtectedEntry] = []
    private(set) var protectError: String?
    /// Why the listed results no longer describe what `mo purge --yes` would remove; purging needs a rescan.
    private(set) var staleReason: String?
    /// Set when the re-check right before purging found artifacts the user had not confirmed.
    private(set) var listChange: PurgeListChange?
    var includeEmpty = false {
        didSet {
            guard includeEmpty != oldValue, scannedAt != nil, includeEmpty != scannedIncludeEmpty else { return }
            markStale("“Include empty folders” changed since the scan.")
        }
    }

    @ObservationIgnored private var inventory: CleanProtectionInventory?
    /// Flag and config files the listed scan was made with.
    @ObservationIgnored private var scannedIncludeEmpty = false
    @ObservationIgnored private var scannedFingerprint: [ConfigFileState] = []

    var isBusy: Bool { phase == .scanning || phase == .verifying || phase == .purging }
    var artifacts: [PurgeArtifact] { scan.artifacts }
    /// Artifacts `mo purge --yes` removes. Mole lists cloud-backed ones but never deletes them.
    var purgeable: [PurgeArtifact] { scan.artifacts.filter { !$0.isCloud } }
    var cloudCount: Int { scan.artifacts.count - purgeable.count }
    var totalBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
    var purgeableBytes: Int64 { purgeable.reduce(0) { $0 + $1.bytes } }
    var canPurge: Bool { phase == .ready && staleReason == nil && !purgeable.isEmpty }

    var projects: [PurgeProject] { Self.projects(artifacts) }
    var purgeableProjects: [PurgeProject] { Self.projects(purgeable) }

    static func projects(_ artifacts: [PurgeArtifact]) -> [PurgeProject] {
        Dictionary(grouping: artifacts, by: \.projectDisplayPath)
            .map { PurgeProject(displayPath: $0.key, artifacts: $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.bytes > $1.bytes }
    }

    var byType: [(type: String, bytes: Int64, count: Int)] {
        Dictionary(grouping: artifacts, by: \.type)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.bytes }, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    // MARK: Protection (Mole's clean whitelist, which purge honours)

    private func loadInventory(service: MoleService) async -> CleanProtectionInventory {
        if let inventory { return inventory }
        let loaded = await CleanProtectionInventory.load(service: service)
        inventory = loaded
        return loaded
    }

    func reloadProtected() {
        let snapshot = CleanWhitelistStore.snapshot(inventory: inventory ?? .fallback)
        protectError = snapshot.problem.map { "Your whitelist can’t be read, so protection can’t be changed here. \($0)" }
        protected = WhitelistPattern.honoured(snapshot.patterns).compactMap { pattern in
            // `protect` writes an escaped path plus a "/*" twin for names with glob characters; list the path once.
            if pattern.hasSuffix("/*") && WhitelistPattern.isGlob(String(pattern.dropLast(2))) { return nil }
            let path = WhitelistPattern.portable(WhitelistPattern.unescapeLiteral(pattern))
            guard PurgeTypes.targets.contains((path as NSString).lastPathComponent) else { return nil }
            return PurgeProtectedEntry(pattern: pattern, path: path)
        }
    }

    func isProtected(_ artifact: PurgeArtifact) -> Bool {
        CleanWhitelistStore.enforcedPatterns(inventory: inventory ?? .fallback)
            .contains { WhitelistPattern.matches(path: artifact.path, pattern: $0) }
    }

    func protect(_ artifact: PurgeArtifact, service: MoleService) async {
        let inventory = await loadInventory(service: service)
        do {
            try CleanWhitelistStore.protect(artifact.path, inventory: inventory)
            protectError = nil
            markStale("Protection changed since the scan.")
        } catch {
            protectError = "Could not protect \(artifact.displayPath): \(error.localizedDescription)"
        }
        reloadProtected()
    }

    func unprotect(_ entry: PurgeProtectedEntry, service: MoleService) async {
        let inventory = await loadInventory(service: service)
        do {
            try CleanWhitelistStore.unprotect(WhitelistPattern.expand(entry.path), inventory: inventory)
            protectError = nil
            // Unprotecting makes something eligible that the listed scan never showed.
            markStale("\(entry.path) is no longer protected, so it may now be purged.")
        } catch {
            protectError = "Could not update the whitelist: \(error.localizedDescription)"
        }
        reloadProtected()
    }

    // MARK: Staleness

    private func markStale(_ reason: String) {
        guard scannedAt != nil else { return }
        staleReason = reason + " Rescan before purging so you can review exactly what would be removed."
    }

    private static func fingerprint() -> [ConfigFileState] {
        [MoleConfigIO.load(MolePaths.cleanWhitelist), MoleConfigIO.load(MolePaths.purgePaths)]
    }

    /// Notices edits made elsewhere (Protection, the CLI) to the whitelist or the scan paths.
    func checkStaleness() {
        guard phase == .ready, scannedAt != nil, staleReason == nil else { return }
        if Self.fingerprint() != scannedFingerprint {
            markStale("Your whitelist or project scan paths changed since the scan.")
        }
    }

    // MARK: Scan

    /// Runs `mo purge --dry-run` and returns its parsed output (the run tells how it ended).
    private func dryRun(service: MoleService, includeEmpty: Bool, title: String, track: (CommandRun) -> Void) async -> (PurgeParser, CommandRun) {
        var parser = PurgeParser()
        var args = ["purge", "--dry-run"]
        if includeEmpty { args.append("--include-empty") }
        let run = service.start(title, args, onLine: { line in parser.feed(line) })
        track(run)
        // Mole writes the root it is scanning to a progress file.
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                let root = (try? String(contentsOfFile: PurgeScanPaths.scanningFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let root, !root.isEmpty, self?.currentRoot != root { self?.currentRoot = root }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        _ = await run.waitUntilExit()
        poll.cancel()
        return (parser, run)
    }

    func runScan(service: MoleService) async {
        guard !isBusy else { return }
        phase = .scanning
        currentRoot = nil
        listChange = nil
        _ = await loadInventory(service: service)
        reloadProtected()
        let flag = includeEmpty
        let fingerprint = Self.fingerprint()
        let (parser, run) = await dryRun(service: service, includeEmpty: flag, title: "Preview project purge") { scanRun = $0 }
        scan = parser
        scannedAt = Date()
        scannedIncludeEmpty = flag
        scannedFingerprint = fingerprint
        staleReason = nil
        if case .failedToStart(let message) = run.state {
            phase = .failed(message)
        } else if case .cancelled = run.state {
            phase = .failed("The scan was stopped.")
        } else if !parser.sawTitle && !parser.errors.isEmpty {
            phase = .failed(parser.errors.joined(separator: "\n"))
        } else {
            phase = .ready
            if flag != includeEmpty { markStale("“Include empty folders” changed during the scan.") }
            checkStaleness()
        }
    }

    func cancelScan() { scanRun?.cancel() }
    func cancelVerify() { verifyRun?.cancel() }

    // MARK: Purge

    /// `mo purge --yes` removes every artifact that is eligible *when it runs*, not a list. So right before
    /// starting it, a fresh dry run with the same flags must find nothing the user hasn't confirmed.
    func purgeAll(service: MoleService) async {
        checkStaleness()
        guard canPurge else { return }
        let confirmed = Set(purgeable.map(\.path))
        let flag = scannedIncludeEmpty
        phase = .verifying
        purgeResult = nil
        purgeErrors = []
        listChange = nil
        currentRoot = nil
        let (fresh, check) = await dryRun(service: service, includeEmpty: flag, title: "Re-check project purge") { verifyRun = $0 }
        guard case .finished = check.state, fresh.sawTitle else {
            phase = .ready
            purgeErrors = [check.state == .cancelled
                ? "The final check was stopped, so nothing was purged."
                : "Mole couldn’t re-check the list (\(fresh.errors.last ?? "exit code \(check.exitCode ?? -1)")), so nothing was purged."]
            return
        }
        let freshPurgeable = fresh.artifacts.filter { !$0.isCloud }
        let added = freshPurgeable.filter { !confirmed.contains($0.path) }
        if !added.isEmpty {
            // Show the new list and require a new confirmation.
            let removed = confirmed.subtracting(freshPurgeable.map(\.path)).count
            scan = fresh
            scannedAt = Date()
            scannedFingerprint = Self.fingerprint()
            staleReason = nil
            listChange = PurgeListChange(added: added, removedCount: removed)
            phase = .ready
            return
        }
        phase = .purging
        var parser = PurgeParser()
        var args = ["purge", "--yes"]
        if flag { args.append("--include-empty") }
        let run = service.start("Purge project artifacts", args, onLine: { line in parser.feed(line) })
        purgeRun = run
        _ = await run.waitUntilExit()
        purgeResult = parser.summary
        purgeErrors = parser.errors + parser.warnings
        if run.state == .cancelled {
            purgeErrors.insert("The purge was stopped. Folders already removed stay removed.", at: 0)
        } else if parser.summary == nil, !parser.noCandidates, !run.succeeded {
            purgeErrors.insert("Mole exited with code \(run.exitCode ?? -1).", at: 0)
        }
        phase = .ready
        await runScan(service: service)
    }

    func dismissResult() { purgeResult = nil; purgeErrors = [] }
    func dismissListChange() { listChange = nil }

    // MARK: Automation

    /// Protects the smallest artifact, re-runs the dry run and checks that Mole skips it, then puts the
    /// whitelist back exactly as it was (content, or absence). Never runs a real purge.
    func automationProtectCheck(service: MoleService) async -> (passed: Bool, detail: String, metrics: [String: String]) {
        guard let target = artifacts.filter({ !$0.isCloud }).min(by: { $0.bytes < $1.bytes }) else {
            return (true, "No artifact to protect", [:])
        }
        let path = MolePaths.cleanWhitelist
        let original = MoleConfigIO.load(path)
        if let problem = original.problem { return (false, "Whitelist unreadable: \(problem)", [:]) }
        guard let target0 = try? MoleConfigIO.resolvedTarget(of: path) else { return (false, "Whitelist path unresolvable", [:]) }

        await protect(target, service: service)
        let fileText = MoleConfigIO.load(path).text ?? ""
        let wrote = fileText.contains(WhitelistPattern.literalPatterns(for: target.path)[0])
        await runScan(service: service)
        let skipped = !artifacts.contains { $0.path == target.path }
        let protectedNow = isProtected(target)

        // Restore.
        var restoreError: String?
        switch original {
        case .missing:
            if unlink(target0) != 0 && errno != ENOENT { restoreError = String(cString: strerror(errno)) }
        case .text(let text):
            do { try MoleConfigIO.writeAtomically(text, to: path) } catch { restoreError = error.localizedDescription }
        case .unreadable:
            break
        }
        let restored = MoleConfigIO.load(path) == original
        reloadProtected()
        await runScan(service: service)
        return (wrote && skipped && protectedNow && restored,
                "Protected \(target.displayPath); skipped by Mole: \(skipped); whitelist restored: \(restored)",
                ["createdWhitelist": "\(original == .missing)", "defaultsKept": "\(fileText.contains("FINDER_METADATA"))",
                 "restored": "\(restored)", "restoreError": restoreError ?? ""])
    }
}
