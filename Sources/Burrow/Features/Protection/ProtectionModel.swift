import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ProtectionModel {
    enum Tab: String, CaseIterable, Identifiable {
        case clean = "Clean Protection", optimize = "Optimization Exclusions", purge = "Project Scan Paths"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .clean: "sparkles"
            case .optimize: "bolt.circle"
            case .purge: "folder.badge.gearshape"
            }
        }
    }

    /// `-MoleE2EProtectionTab optimize|purge` opens another tab (automation screenshots).
    var tab: Tab = switch UserDefaults.standard.string(forKey: "MoleE2EProtectionTab") {
    case "optimize": .optimize
    case "purge": .purge
    default: .clean
    }
    private(set) var loaded = false

    // Clean
    private(set) var inventory = CleanProtectionInventory.fallback
    private(set) var cleanPatterns: [String] = []
    private(set) var cleanFileExists = false
    /// Set when ~/.config/mole/whitelist exists but can't be read; edits are refused.
    private(set) var cleanFileProblem: String?

    // Optimize
    private(set) var tasks: [OptimizeTask] = OptimizeCatalog.fallback
    private(set) var optimizeFile = OptimizeWhitelistFile(entries: [])
    private(set) var optimizeFileExists = false
    /// True when the rules come from Mole's legacy `whitelist_checks` (the first save migrates them).
    private(set) var optimizeUsesLegacy = false
    private(set) var optimizeFileProblem: String?

    // Purge
    private(set) var purgeFile = ProtectionPurgePaths(header: ProtectionPurgePaths.defaultHeader, paths: [])
    private(set) var purgeFileExists = false
    private(set) var purgeFileProblem: String?
    private(set) var purgeDefaults: [String] = ProtectionPurgeDefaults.fallback

    var savedMessage: String?
    var errorMessage: String?
    @ObservationIgnored private var toastToken = 0
    @ObservationIgnored private var didRecord = false

    func load(model: AppModel, service: MoleService) async {
        async let inv = CleanProtectionInventory.load(service: service)
        async let cat = OptimizeCatalog.load(service: service)
        async let purge = ProtectionPurgeDefaults.load(service: service)
        inventory = await inv
        tasks = await cat.tasks
        purgeDefaults = await purge
        reloadFiles()
        loaded = true
        if model.automation.isActive && model.automation.route == .protection && !didRecord {
            didRecord = true
            recordAutomation(model.automation)
        }
    }

    func reloadFiles() {
        let clean = CleanWhitelistStore.snapshot(inventory: inventory)
        cleanPatterns = clean.patterns
        cleanFileExists = clean.fileExists
        cleanFileProblem = clean.problem
        let optimize = OptimizeWhitelistStore.load()
        optimizeFile = optimize.file
        optimizeFileExists = optimize.exists
        optimizeUsesLegacy = optimize.source == .legacy && optimize.problem == nil
        optimizeFileProblem = optimize.problem
        let purge = PurgePathsStore.load()
        purgeFile = purge.file
        purgeFileExists = purge.exists
        purgeFileProblem = purge.problem
    }

    // MARK: Clean protection

    var groupedInventory: [(category: String, items: [CacheInventoryItem])] {
        let groups = Dictionary(grouping: inventory.items, by: \.category)
        let order = CleanProtectionInventory.categoryOrder
        return groups.keys.sorted {
            (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1)
        }.map { ($0, groups[$0] ?? []) }
    }

    /// Hard safety rules cover the item (exactly, or because a safety glob matches its pattern).
    func isLocked(_ item: CacheInventoryItem) -> Bool {
        inventory.safety.contains { WhitelistPattern.equivalent($0, item.pattern) || WhitelistPattern.matches(path: item.pattern, pattern: $0) }
    }

    func isProtected(_ item: CacheInventoryItem) -> Bool {
        isLocked(item) || cleanPatterns.contains { WhitelistPattern.equivalent($0, item.pattern) }
    }

    /// Entries that are neither predefined inventory rows nor hard safety rules.
    var customPatterns: [String] {
        cleanPatterns.filter { !inventory.isInventory($0) && !inventory.isSafety($0) }
    }

    var safetyPatterns: [String] { inventory.safety }

    func setProtected(_ item: CacheInventoryItem, _ on: Bool) {
        var patterns = currentCleanPatterns()
        if on {
            if !patterns.contains(where: { WhitelistPattern.equivalent($0, item.pattern) }) { patterns.append(WhitelistPattern.portable(item.pattern)) }
        } else {
            patterns.removeAll { WhitelistPattern.equivalent($0, item.pattern) }
        }
        saveClean(patterns, message: on ? "Protecting \(item.name)" : "\(item.name) no longer protected")
    }

    func addCustom(_ raw: String) -> String? {
        let pattern = raw.trimmingCharacters(in: .whitespaces)
        if let error = WhitelistPattern.validationError(pattern) { return error }
        var patterns = currentCleanPatterns()
        if patterns.contains(where: { WhitelistPattern.equivalent($0, pattern) }) || inventory.isSafety(pattern) {
            return "That pattern is already protected."
        }
        patterns.append(pattern)
        saveClean(patterns, message: "Added \(pattern)")
        return nil
    }

    func removeCustom(_ pattern: String) {
        var patterns = currentCleanPatterns()
        patterns.removeAll { WhitelistPattern.equivalent($0, pattern) }
        saveClean(patterns, message: "Removed \(pattern)")
    }

    /// Moves the whitelist file to the Trash so Mole's built-in defaults apply again.
    func restoreCleanDefaults() {
        guard cleanFileExists else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: MolePaths.cleanWhitelist), resultingItemURL: nil)
            reloadFiles()
            toast("Mole’s default protections restored")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func currentCleanPatterns() -> [String] {
        CleanWhitelistStore.effectivePatterns(inventory: inventory).patterns
    }

    private func saveClean(_ patterns: [String], message: String) {
        do {
            try CleanWhitelistStore.save(patterns, inventory: inventory)
            reloadFiles()
            toast(message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Optimize exclusions

    var taskIDs: Set<String> { Set(tasks.map(\.id)) }
    var optimizePathPatterns: [String] { optimizeFile.pathPatterns(taskIDs: taskIDs) }

    func isExcluded(_ task: OptimizeTask) -> Bool { optimizeFile.excludes(task: task.id) }

    func setExcluded(_ task: OptimizeTask, _ excluded: Bool) {
        reloadFiles()
        var file = optimizeFile
        file.set(task: task.id, excluded: excluded)
        saveOptimize(file, message: excluded ? "\(task.displayName) will be skipped" : "\(task.displayName) included")
    }

    func addOptimizePattern(_ raw: String) -> String? {
        let pattern = raw.trimmingCharacters(in: .whitespaces)
        if let error = WhitelistPattern.validationError(pattern) { return error }
        if taskIDs.contains(pattern) { return "That is a task name; use the task switches above." }
        reloadFiles()
        var file = optimizeFile
        if file.entries.contains(where: { WhitelistPattern.equivalent($0, pattern) }) { return "Already listed." }
        file.entries.append(pattern)
        saveOptimize(file, message: "Added \(pattern)")
        return nil
    }

    func removeOptimizePattern(_ pattern: String) {
        reloadFiles()
        var file = optimizeFile
        file.entries.removeAll { $0 == pattern }
        saveOptimize(file, message: "Removed \(pattern)")
    }

    private func saveOptimize(_ file: OptimizeWhitelistFile, message: String) {
        do {
            try OptimizeWhitelistStore.save(file)
            reloadFiles()
            toast(message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Purge paths

    var usingPurgeDefaults: Bool { purgeFile.paths.isEmpty }
    var effectivePurgePaths: [String] { usingPurgeDefaults ? purgeDefaults : purgeFile.paths }

    static func exists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: WhitelistPattern.expand(path), isDirectory: &isDir) && isDir.boolValue
    }

    func addPurgePath(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return "Choose a folder." }
        let expanded = WhitelistPattern.expand(path)
        guard expanded.hasPrefix("/") else { return "Use an absolute path or one starting with ~." }
        if expanded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "The folder name contains a line break or other control character, which the file can’t hold."
        }
        reloadFiles()
        var file = purgeFile
        if file.paths.contains(where: { WhitelistPattern.equivalent($0, path) }) { return "Already in the list." }
        file.paths.append(WhitelistPattern.portable(expanded))
        savePurge(file, message: "Added \(WhitelistPattern.portable(expanded))")
        return nil
    }

    func removePurgePath(_ path: String) {
        reloadFiles()
        var file = purgeFile
        file.paths.removeAll { WhitelistPattern.equivalent($0, path) }
        savePurge(file, message: "Removed \(path.abbreviatingHome)")
    }

    private func savePurge(_ file: ProtectionPurgePaths, message: String) {
        do {
            if let problem = PurgePathsStore.load().problem { throw ConfigFileError.refusing(problem) }
            try MoleConfigIO.writeAtomically(file.serialized(), to: MolePaths.purgePaths)
            reloadFiles()
            toast(message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Pickers

    func chooseFolder(prompt: String, allowFiles: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = allowFiles
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = prompt
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: Feedback

    private func toast(_ message: String) {
        errorMessage = nil
        toastToken += 1
        let token = toastToken
        savedMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            if self?.toastToken == token { self?.savedMessage = nil }
        }
    }

    // MARK: Automation (read-only)

    private func recordAutomation(_ automation: Automation) {
        // In-memory round trips of each file format: parse(serialize(x)) must equal x. Nothing is written.
        let cleanFile = CleanWhitelistStore.fileContents(for: cleanPatterns, inventory: inventory)
        let cleanRoundTrip = CleanWhitelistFile.parse(cleanFile.serialized()) == cleanFile
        let optRoundTrip = OptimizeWhitelistFile.parse(optimizeFile.serialized()) == optimizeFile
        let purgeRoundTrip = ProtectionPurgePaths.parse(purgeFile.serialized()).paths == purgeFile.paths.map { WhitelistPattern.portable($0) }
        let protectedCount = inventory.items.filter(isProtected).count
        let passed = inventory.fromMole && !inventory.items.isEmpty && cleanRoundTrip && optRoundTrip && purgeRoundTrip
        automation.record("protection", passed: passed,
                          detail: "Loaded \(inventory.items.count) predefined protections in \(groupedInventory.count) categories",
                          metrics: [
                              "inventoryItems": "\(inventory.items.count)",
                              "inventoryFromMole": inventory.fromMole ? "yes" : "no",
                              "categories": "\(groupedInventory.count)",
                              "defaults": "\(inventory.defaults.count)",
                              "safety": "\(inventory.safety.count)",
                              "whitelistFileExists": cleanFileExists ? "yes" : "no",
                              "activePatterns": "\(cleanPatterns.count)",
                              "protectedInventoryItems": "\(protectedCount)",
                              "customPatterns": "\(customPatterns.count)",
                              "optimizeTasks": "\(tasks.count)",
                              "optimizeExcluded": "\(tasks.filter(isExcluded).count)",
                              "purgePaths": "\(purgeFile.paths.count)",
                              "purgeDefaults": "\(purgeDefaults.count)",
                              "roundTrip": cleanRoundTrip && optRoundTrip && purgeRoundTrip ? "ok" : "mismatch",
                          ])
    }
}
