import SwiftUI

struct ProtectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @State private var vm = ProtectionModel()

    private let theme = FeatureTheme.protection

    var body: some View {
        FeaturePage(theme: theme) {
            PageHeader(theme: theme) {
                Button("Reload", systemImage: "arrow.clockwise") { vm.reloadFiles() }
                    .buttonStyle(.soft)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Re-read Mole’s config files (⌘R)")
            }
        } content: {
            Picker("Section", selection: $vm.tab) {
                ForEach(ProtectionModel.Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)

            if let error = vm.errorMessage {
                ErrorBanner(message: error)
            }
            if !vm.loaded {
                ScanningView(theme: theme, title: "Reading Mole’s protection rules…")
            } else {
                Group {
                    switch vm.tab {
                    case .clean: CleanProtectionTab(vm: vm, theme: theme)
                    case .optimize: OptimizeExclusionsTab(vm: vm, theme: theme)
                    case .purge: PurgePathsTab(vm: vm, theme: theme)
                    }
                }
                .transition(.opacity)
                .animation(.smooth(duration: 0.25), value: vm.tab)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = vm.savedMessage {
                Label("Saved · \(message)", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(Color.moleGood.opacity(0.2)), in: .capsule)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.savedMessage)
        .task { await vm.load(model: model, service: service) }
        .tidyAutomationScroll(ready: vm.loaded)
    }
}

// MARK: - Clean protection

private struct CleanProtectionTab: View {
    let vm: ProtectionModel
    let theme: FeatureTheme
    @State private var confirmReset = false

    var body: some View {
        let protectedCount = vm.inventory.items.filter(vm.isProtected).count
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let problem = vm.cleanFileProblem {
                InfoBanner(symbol: "exclamationmark.lock.fill", title: "Your whitelist can’t be read",
                           message: "\(problem) Mole can’t read it either, so only its safety rules apply. Changes are disabled here so the file isn’t replaced.",
                           tint: .moleBad, actionTitle: "Reveal") { Finder.reveal(MolePaths.cleanWhitelist) }
            } else if vm.cleanFileExists {
                Footnote(symbol: "doc.badge.gearshape", text: "\(vm.cleanPatterns.count) pattern\(vm.cleanPatterns.count == 1 ? "" : "s") in ~/.config/mole/whitelist replace Mole’s defaults. Safety rules always apply.",
                         actionTitle: "Restore Defaults") { confirmReset = true }
            } else {
                Footnote(symbol: "checkmark.shield", text: "Mole’s default protections are active. Your first change saves a whitelist that keeps these defaults.")
            }
            InventoryList(vm: vm)
                .disabled(vm.cleanFileProblem != nil)
            CustomPatternsCard(vm: vm, theme: theme)
                .disabled(vm.cleanFileProblem != nil)
                .id("protection.custom")
            SafetyCard(patterns: vm.safetyPatterns)
            if !vm.inventory.fromMole {
                Text("Mole’s inventory couldn’t be read, so a built-in subset is shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Restore Mole’s default protections?", isPresented: $confirmReset) {
            Button("Move Whitelist to Trash", role: .destructive) { vm.restoreCleanDefaults() }
        } message: {
            Text("Your ~/.config/mole/whitelist file is moved to the Trash (you can put it back from there). Mole then uses its built-in defaults.")
        }
    }
}

/// Every known cache location, grouped by category in one list. Categories open on demand.
private struct InventoryList: View {
    let vm: ProtectionModel
    /// Automation aid for screenshots: `-MoleE2EExpand <name>` opens that row.
    @State private var expanded: Set<String> = Set(UserDefaults.standard.string(forKey: "MoleE2EExpand").map { [$0] } ?? [])

    var body: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cache locations").font(.headline)
                    Spacer()
                    Text("\(vm.inventory.items.filter(vm.isProtected).count) of \(vm.inventory.items.count) protected")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                ForEach(vm.groupedInventory, id: \.category) { group in
                    Divider().opacity(0.5)
                    category(group.category, items: group.items)
                }
            }
        }
    }

    @ViewBuilder
    private func category(_ category: String, items: [CacheInventoryItem]) -> some View {
        let on = items.filter(vm.isProtected).count
        let open = expanded.contains(category)
        Button {
            withAnimation(.snappy) { expanded.formSymmetricDifference([category]) }
        } label: {
            HStack(spacing: 14) {
                TidyGlyph(symbol: CleanProtectionInventory.symbol(for: category), tint: FeatureTheme.protection.accent, size: 32)
                Text(CleanProtectionInventory.title(for: category)).font(.callout.weight(.semibold))
                Spacer()
                Text("\(on) of \(items.count) protected")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(on > 0 ? .primary : .secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .tidyHover(radius: 0)
        .accessibilityHint(open ? "Hides its cache locations" : "Shows its cache locations")
        if open {
            VStack(spacing: 2) {
                ForEach(items) { item in
                    InventoryRow(vm: vm, item: item)
                }
            }
            .padding(.leading, 58)
            .padding(.trailing, 12)
            .padding(.bottom, 10)
            .transition(.opacity)
        }
    }
}

private struct InventoryRow: View {
    let vm: ProtectionModel
    let item: CacheInventoryItem

    var body: some View {
        let locked = vm.isLocked(item)
        let isOn = vm.isProtected(item)
        let isDefault = vm.inventory.isDefault(item.pattern)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.callout).lineLimit(1)
                    if isDefault && !vm.cleanFileExists { Pill(text: "Default", tint: .moleGood) }
                }
                Text(item.pattern == WhitelistPattern.finderMetadata ? ".DS_Store files everywhere" : item.pattern.abbreviatingHome)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if locked {
                Image(systemName: "lock.fill").foregroundStyle(.orange).help("A safety rule: always protected")
                    .accessibilityLabel("Always protected")
            } else {
                Toggle("Protect \(item.name)", isOn: Binding(get: { isOn }, set: { vm.setProtected(item, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .tidyHover()
        .contextMenu {
            if item.pattern.hasPrefix("/") {
                Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(Self.revealTarget(item.pattern)) }
            }
            Button("Copy Pattern", systemImage: "doc.on.doc") { TidyPasteboard.copy(item.pattern) }
        }
    }

    /// The deepest non-glob ancestor of a pattern.
    static func revealTarget(_ pattern: String) -> String {
        var parts: [Substring] = []
        for part in pattern.split(separator: "/") {
            if WhitelistPattern.isGlob(String(part)) { break }
            parts.append(part)
        }
        var path = "/" + parts.joined(separator: "/")
        while !FileManager.default.fileExists(atPath: path) && path != "/" { path = (path as NSString).deletingLastPathComponent }
        return path
    }
}

private struct CustomPatternsCard: View {
    let vm: ProtectionModel
    let theme: FeatureTheme
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Custom patterns", symbol: "text.badge.plus", detail: "Globs like ~/Library/Caches/MyApp* work")
                PatternEntry(draft: $draft, error: $error, placeholder: "~/Library/Caches/com.example.app", allowFiles: true, vm: vm) { vm.addCustom($0) }
                if vm.customPatterns.isEmpty {
                    Text("No custom patterns yet. Add any path Mole should never clean.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    VStack(spacing: 2) {
                        ForEach(vm.customPatterns, id: \.self) { p in
                            PatternRow(pattern: p, badge: vm.inventory.isDefault(p) ? "Mole default" : nil) { vm.removeCustom(p) }
                        }
                    }
                }
            }
        }
    }
}

private struct SafetyCard: View {
    let patterns: [String]

    var body: some View {
        GlassCard(tint: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Safety rules", symbol: "lock.shield.fill", detail: "Always on")
                Text("Mole always protects these, whatever your whitelist says. Removing them would break search, fonts, iCloud sync or Poetry environments.")
                    .font(.caption).foregroundStyle(.secondary)
                TidyFlowLayout(spacing: 8) {
                    ForEach(patterns, id: \.self) { p in
                        Label(p == WhitelistPattern.finderMetadata ? "Finder metadata (.DS_Store)" : p.abbreviatingHome, systemImage: "lock.fill")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.orange.opacity(0.12), in: .capsule)
                    }
                }
            }
        }
    }
}

// MARK: - Shared rows

private struct PatternEntry: View {
    @Binding var draft: String
    @Binding var error: String?
    let placeholder: String
    let allowFiles: Bool
    let vm: ProtectionModel
    let add: (String) -> String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .focused($focused)
                    .onSubmit(submit)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .onChange(of: draft) { _, _ in error = nil }
                Button("Choose…", systemImage: "folder") {
                    if let path = vm.chooseFolder(prompt: "Protect", allowFiles: allowFiles) {
                        // A chosen folder is a literal path: escape glob characters so it protects only itself.
                        draft = WhitelistPattern.escapeLiteral(WhitelistPattern.portable(path))
                        submit()
                    }
                }
                .buttonStyle(.soft)
                Button("Add", systemImage: "plus", action: submit)
                    .buttonStyle(.hero(.protection))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.moleBad)
                    .transition(.opacity)
            }
        }
    }

    private func submit() {
        if let message = add(draft) {
            withAnimation { error = message }
        } else {
            draft = ""
            error = nil
        }
    }
}

private struct PatternRow: View {
    let pattern: String
    var badge: String? = nil
    let remove: () -> Void

    var body: some View {
        let expanded = WhitelistPattern.expand(pattern)
        let exists = !WhitelistPattern.isGlob(expanded) && FileManager.default.fileExists(atPath: expanded)
        HStack(spacing: 10) {
            Image(systemName: WhitelistPattern.isGlob(pattern) ? "asterisk.circle" : (exists ? "folder.fill" : "questionmark.folder"))
                .foregroundStyle(exists ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(pattern.abbreviatingHome).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            if let badge { Pill(text: badge, tint: .moleGood) }
            Spacer()
            if exists {
                Button { Finder.reveal(expanded) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
            }
            Button(role: .destructive, action: remove) { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.moleBad)
                .help("Remove")
                .accessibilityLabel("Remove \(pattern)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .tidyHover()
        .contextMenu {
            if exists { Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(expanded) } }
            Button("Copy Path", systemImage: "doc.on.doc") { TidyPasteboard.copy(expanded) }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive, action: remove)
        }
    }
}

// MARK: - Optimization exclusions

private struct OptimizeExclusionsTab: View {
    let vm: ProtectionModel
    let theme: FeatureTheme
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        let excluded = vm.tasks.filter(vm.isExcluded).count
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let problem = vm.optimizeFileProblem {
                InfoBanner(symbol: "exclamationmark.lock.fill", title: "The optimization whitelist can’t be read",
                           message: "\(problem) Changes are disabled here so the file isn’t replaced.", tint: .moleBad)
            } else if vm.optimizeUsesLegacy {
                InfoBanner(symbol: "clock.arrow.circlepath", title: "Using your older whitelist_checks file",
                           message: "Mole still reads ~/.config/mole/whitelist_checks. Your next change saves these rules to whitelist_optimize, as Mole itself does.",
                           tint: .blue)
            }
            Footnote(symbol: "info.circle", text: "Switch a task off to have Mole skip it. The Optimize screen uses the same list.")
            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(title: "Tasks", symbol: "checklist", detail: "\(vm.tasks.count - excluded) of \(vm.tasks.count) run")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)], spacing: 4) {
                        ForEach(vm.tasks) { task in
                            let skipped = vm.isExcluded(task)
                            HStack(spacing: 10) {
                                TidyGlyph(symbol: task.symbol, tint: skipped ? .secondary : FeatureTheme.optimize.accent, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(task.whitelistName).font(.callout).lineLimit(1)
                                    Text(task.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                if task.needsAdmin { Image(systemName: "lock.shield").foregroundStyle(.orange).help("Uses administrator access") }
                                Toggle("Run \(task.whitelistName)", isOn: Binding(get: { !skipped }, set: { vm.setExcluded(task, !$0) }))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .opacity(skipped ? 0.65 : 1)
                            .tidyHover()
                        }
                    }
                }
            }
            .disabled(vm.optimizeFileProblem != nil)
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Keep these disk images mounted", symbol: "externaldrive.badge.checkmark")
                    Text("Optimize’s diagnosis suggests detaching idle disk images. Paths or globs listed here are never suggested.")
                        .font(.caption).foregroundStyle(.secondary)
                    PatternEntry(draft: $draft, error: $error, placeholder: "/Volumes/MyImage*", allowFiles: true, vm: vm) { vm.addOptimizePattern($0) }
                    if vm.optimizePathPatterns.isEmpty {
                        Text("No path patterns.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.optimizePathPatterns, id: \.self) { p in
                            PatternRow(pattern: p) { vm.removeOptimizePattern(p) }
                        }
                    }
                }
            }
            .disabled(vm.optimizeFileProblem != nil)
        }
    }
}

// MARK: - Project scan paths

private struct PurgePathsTab: View {
    let vm: ProtectionModel
    let theme: FeatureTheme
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let problem = vm.purgeFileProblem {
                InfoBanner(symbol: "exclamationmark.lock.fill", title: "Your scan path list can’t be read",
                           message: "\(problem) Changes are disabled here so the file isn’t replaced.", tint: .moleBad)
            } else if vm.usingPurgeDefaults {
                Footnote(symbol: "info.circle", text: "No custom scan paths are set. Mole scans the defaults below and may save project folders it discovers on its next purge.")
            } else {
                Footnote(symbol: "info.circle", text: "Project Purge looks for build artifacts only inside these folders. Remove them all to go back to Mole’s defaults.")
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionTitle(title: vm.usingPurgeDefaults ? "Default scan paths" : "Scan paths", symbol: "folder")
                        Button("Add Folder…", systemImage: "plus") {
                            if let path = vm.chooseFolder(prompt: "Add", allowFiles: false) {
                                error = vm.addPurgePath(path)
                            }
                        }
                        .buttonStyle(.hero(.protection))
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(Color.moleBad)
                    }
                    ForEach(vm.effectivePurgePaths, id: \.self) { path in
                        purgeRow(path, isDefault: vm.usingPurgeDefaults)
                    }
                }
            }
            .disabled(vm.purgeFileProblem != nil)
            let suggestions = vm.purgeDefaults.filter { d in
                ProtectionModel.exists(d) && !vm.purgeFile.paths.contains { WhitelistPattern.equivalent($0, d) }
            }
            if !vm.usingPurgeDefaults && !suggestions.isEmpty && vm.purgeFileProblem == nil {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Mole’s default folders on this Mac", symbol: "lightbulb", detail: "Not in your list")
                        ForEach(suggestions, id: \.self) { path in
                            HStack(spacing: 12) {
                                Image(nsImage: Finder.icon(for: WhitelistPattern.expand(path))).resizable().frame(width: 26, height: 26)
                                Text(path.abbreviatingHome).font(.callout.monospaced())
                                Spacer()
                                Button("Add", systemImage: "plus") { error = vm.addPurgePath(path) }
                                    .buttonStyle(.soft)
                                    .controlSize(.small)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .tidyHover()
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text("~/.config/mole/purge_paths").font(.caption.monospaced()).foregroundStyle(.secondary)
                if vm.purgeFileExists {
                    Button("Reveal") { Finder.reveal(MolePaths.purgePaths) }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func purgeRow(_ path: String, isDefault: Bool) -> some View {
        let expanded = WhitelistPattern.expand(path)
        let exists = ProtectionModel.exists(path)
        return HStack(spacing: 12) {
            Image(nsImage: Finder.icon(for: exists ? expanded : "/System/Library"))
                .resizable().frame(width: 26, height: 26)
                .opacity(exists ? 1 : 0.4)
            Text(path.abbreviatingHome).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            if isDefault { Pill(text: "Default", tint: .secondary) }
            Spacer()
            Pill(text: exists ? "Found" : "Not found", symbol: exists ? "checkmark.circle.fill" : "questionmark.circle",
                 tint: exists ? .moleGood : .secondary)
            if exists {
                Button { Finder.reveal(expanded) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
            if !isDefault {
                Button(role: .destructive) { vm.removePurgePath(path) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.moleBad)
                    .help("Remove")
                    .accessibilityLabel("Remove \(path)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .tidyHover()
        .contextMenu {
            if exists { Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(expanded) } }
            Button("Copy Path", systemImage: "doc.on.doc") { TidyPasteboard.copy(expanded) }
            if !isDefault {
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive) { vm.removePurgePath(path) }
            }
        }
    }
}
