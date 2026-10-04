import AppKit
import QuickLook
import SwiftUI

struct InstallersView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service

    @State private var store = InstallersStore.shared
    @State private var selection: Set<String> = []
    @State private var moveToTrash = true
    @State private var confirming = false
    @State private var confirmDryRun = false
    @State private var quickLook: URL?

    private let theme = FeatureTheme.installers

    var body: some View {
        FeaturePage(theme: theme) {
            PageHeader(theme: theme, subtitle: subtitle) {
                Button {
                    Task { await store.scan(service: service) }
                } label: {
                    Label(store.scannedAt == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.soft)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isBusy)
                .help("Scan for installers (⌘R)")
            }
        } content: {
            content
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty && store.phase == .ready {
                selectionBar.padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: selection.isEmpty)
        .animation(.smooth, value: store.phase)
        .quickLookPreview($quickLook)
        .sheet(isPresented: $confirming) { confirmSheet }
        .onChange(of: store.phase) { _, phase in
            if phase == .ready || phase == .done {
                // Only files the app has pinned to one location can be selected.
                let ids = Set(store.items.filter(\.isLocated).map(\.id))
                selection.formIntersection(ids)
            }
        }
        .task { await onAppear() }
    }

    private var subtitle: String {
        guard store.scannedAt != nil else { return theme.subtitle }
        return store.items.isEmpty ? "No installers found" : "\(store.items.count) installer\(store.items.count == 1 ? "" : "s") · \(ByteFormat.string(store.totalBytes))"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            GlassCard {
                VStack(spacing: 18) {
                    EmptyStateView(symbol: "shippingbox", title: "Find leftover installers",
                                   message: "Disk images, packages and archives you already installed from pile up in Downloads, Desktop, Homebrew's cache, Mail and Telegram.",
                                   tint: theme.accent)
                    Button {
                        Task { await store.scan(service: service) }
                    } label: { Label("Scan for Installers", systemImage: "magnifyingglass") }
                    .buttonStyle(.hero(theme))
                }
                .padding(.bottom, 20)
            }
        case .scanning:
            GlassCard {
                ScanningView(theme: theme, title: "Scanning for installers", detail: store.scanStatus)
            }
        case .failed(let message) where store.scannedAt == nil:
            ErrorBanner(message: message) { Task { await store.scan(service: service) } }
        default:
            resultBanner
            if store.items.isEmpty {
                GlassCard {
                    VStack(spacing: 4) {
                        ResultBurst(style: .success, theme: theme, size: 56)
                        Text("No installer files to clean").font(.title3.weight(.semibold))
                        Text("Your Downloads, Desktop and caches are free of old .dmg, .pkg and .zip installers.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else {
                ForEach(groups, id: \.source) { group in
                    section(group.source, items: group.items)
                }
                Text("Mole looks two folders deep in each location. Nothing is removed until you confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, selection.isEmpty ? 0 : 70)
            }
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        if store.phase == .removing {
            FlowProgressCard(theme: theme, title: store.lastRemovalWasDryRun ? "Rehearsing removal…" : "Removing installers…",
                             detail: store.removalStatus.isEmpty
                                ? "Mole is selecting your files in its list and checking each one before it touches it."
                                : store.removalStatus,
                             run: store.removeRun,
                             cancelTitle: store.canCancelRemoval ? "Cancel" : nil,
                             onCancel: { store.cancelRemoval() })
        } else if case .failed(let message) = store.phase {
            GlassCard(tint: .moleWarn) {
                HStack(alignment: .top, spacing: 14) {
                    ResultBurst(style: .warning, theme: theme, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Removal stopped").font(.headline)
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Dismiss") { store.acknowledge() }.buttonStyle(.soft)
                }
            }
        } else if store.phase == .done, let summary = store.lastSummary {
            GlassCard(tint: summary.isIncomplete ? .moleWarn : .moleGood) {
                HStack(alignment: .center, spacing: 16) {
                    ResultBurst(style: store.lastRemovalWasDryRun ? .info : summary.isIncomplete ? .warning : .success, theme: theme, size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.lastRemovalWasDryRun ? "Dry run complete: nothing was removed" : summary.isIncomplete ? "Some installers could not be removed" : "Installers removed")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        if let count = summary.count, let mb = summary.freedMB {
                            Text("\(count) installer\(count == 1 ? "" : "s") · \(ByteFormat.string(Int64(mb * 1_048_576))) \(store.lastRemovalWasDryRun ? "would be freed" : store.lastRemovalMovedToTrash ? "moved to the Trash" : "freed")")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(summary.failures, id: \.self) { f in
                            Label(f, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.moleWarn)
                        }
                    }
                    Spacer()
                    Button("Done") { store.acknowledge() }.buttonStyle(.soft)
                }
            }
        }
    }

    private var groups: [(source: String, items: [InstallerItem])] {
        Dictionary(grouping: store.items, by: \.source)
            .map { ($0.key, $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.1.reduce(0) { $0 + $1.bytes } > $1.1.reduce(0) { $0 + $1.bytes } }
    }

    private func section(_ source: String, items: [InstallerItem]) -> some View {
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        let selectable = items.filter(\.isLocated)
        let allSelected = !selectable.isEmpty && selectable.allSatisfy { selection.contains($0.id) }
        return GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: InstallerLocations.symbol(forSource: source))
                        .foregroundStyle(theme.accent)
                    Text(source).font(.headline)
                    Text("\(items.count) · \(ByteFormat.string(bytes))")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button(allSelected ? "Deselect All" : "Select All") {
                        withAnimation(.snappy) {
                            if allSelected { selection.subtract(selectable.map(\.id)) } else { selection.formUnion(selectable.map(\.id)) }
                        }
                    }
                    .buttonStyle(.soft)
                    .controlSize(.small)
                    .disabled(selectable.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                ForEach(items) { item in
                    Divider().opacity(0.5)
                    InstallerCard(item: item, selected: selection.contains(item.id), theme: theme) {
                        guard item.isLocated else { return }
                        withAnimation(.snappy(duration: 0.2)) {
                            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                        }
                    }
                    .contextMenu {
                        if let path = item.path {
                            Button("Quick Look", systemImage: "eye") { quickLook = URL(fileURLWithPath: path) }
                            Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(path) }
                            Button("Copy Path", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(path, forType: .string)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Selection & confirm

    private var selectedItems: [InstallerItem] { store.items.filter { selection.contains($0.id) } }

    private var selectionBar: some View {
        let items = selectedItems
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(items.count) selected").font(.headline).contentTransition(.numericText())
                Text(ByteFormat.string(bytes)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .animation(.snappy, value: items.count)
            Button("Clear", systemImage: "xmark") { selection.removeAll() }
                .labelStyle(.iconOnly).buttonStyle(.soft)
            Divider().frame(height: 26)
            Toggle("Move to Trash", isOn: $moveToTrash)
                .toggleStyle(.switch).controlSize(.small).fixedSize()
                .help("Off: delete permanently")
            Button("Dry Run", systemImage: "eye") {
                confirmDryRun = true
                confirming = true
            }
            .buttonStyle(.soft)
            .help("Drive Mole's selector in dry-run mode without deleting anything")
            Button {
                confirmDryRun = false
                confirming = true
            } label: {
                Label("Remove", systemImage: "trash.fill").fixedSize()
            }
            .buttonStyle(.hero(theme))
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Remove the selected installers (⌘⌫)")
        }
        .fixedSize()
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
    }

    private var confirmSheet: some View {
        let items = selectedItems
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        return ConfirmSheet(theme: theme,
                            title: confirmDryRun ? "Rehearse Removing \(items.count) Installer\(items.count == 1 ? "" : "s")" : "Remove \(items.count) Installer\(items.count == 1 ? "" : "s")?",
                            message: confirmDryRun ? "Mole goes through every step in dry-run mode. Nothing is deleted."
                                : moveToTrash ? "They will be moved to the Trash." : "They will be deleted permanently.",
                            confirmTitle: confirmDryRun ? "Run Dry Run" : moveToTrash ? "Move to Trash" : "Delete Permanently",
                            destructive: !confirmDryRun,
                            onConfirm: {
                                confirming = false
                                let trash = moveToTrash, dry = confirmDryRun
                                Task {
                                    await store.remove(items, trash: trash, dryRun: dry, service: service)
                                    if store.phase == .done && !dry {
                                        selection.removeAll()
                                        await store.scan(service: service)
                                        store.markDone()
                                    }
                                }
                            },
                            onCancel: { confirming = false }) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            HStack(spacing: 10) {
                                if let path = item.path { FileIconView(path: path, size: 24) }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.displayName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                    Text(item.path.map { MoleHomeDir.abbreviate($0) } ?? item.source)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(item.size).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            let twins = store.twins(of: item)
                            if !twins.isEmpty {
                                Label("Same name and size as \(twins.compactMap(\.path).map { MoleHomeDir.abbreviate($0) }.joined(separator: ", ")). Only the file at the path above is selected.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.moleWarn)
                                    .padding(.leading, 34)
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(minHeight: 80, maxHeight: 300)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
                HStack {
                    Label(confirmDryRun ? "Dry run" : moveToTrash ? "Recoverable from the Trash" : "Permanent",
                          systemImage: confirmDryRun ? "eye" : moveToTrash ? "trash" : "flame.fill")
                        .foregroundStyle(!confirmDryRun && !moveToTrash ? Color.moleBad : .secondary)
                    Spacer()
                    Text("Total").foregroundStyle(.secondary)
                    Text(ByteFormat.string(bytes)).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
                }
            }
        }
    }

    // MARK: Automation

    private func onAppear() async {
        let automation = model.automation
        guard automation.autorun && automation.route == .installers else {
            if store.phase == .idle { await store.scan(service: service) }
            return
        }
        let started = Date()
        await store.scan(service: service)
        let passed = store.phase == .ready
        automation.record("installers", passed: passed,
                          detail: passed ? "Found \(store.items.count) installers" : "\(store.phase)",
                          metrics: ["installers": "\(store.items.count)", "bytes": "\(store.totalBytes)",
                                    "located": "\(store.items.filter { $0.path != nil }.count)",
                                    "seconds": String(format: "%.1f", Date().timeIntervalSince(started))])
        // Optional end-to-end check of the key-driving protocol, always with --dry-run.
        // -MoleE2EInstallerIndex <n> picks Mole's list position n instead of the last located item.
        let defaults = UserDefaults.standard
        let pick = defaults.object(forKey: "MoleE2EInstallerIndex") != nil
            ? store.items.first { $0.index == defaults.integer(forKey: "MoleE2EInstallerIndex") && $0.isLocated }
            : store.items.last(where: \.isLocated)
        if passed, defaults.bool(forKey: "MoleE2EDryRunProtocol"), let first = pick {
            selection = [first.id]
            await store.remove([first], trash: true, dryRun: true, service: service)
            let s = store.lastSummary
            let removed = store.lastToggledRows.joined(separator: " / ")
            automation.record("installers-protocol", passed: store.phase == .done && (s?.isDryRun ?? false) && s?.count == 1,
                              detail: s?.details.joined(separator: " / ") ?? store.lastRemovalError ?? "\(store.phase)",
                              metrics: ["selected": first.displayName, "index": "\(first.index)",
                                        "path": first.path ?? "", "source": first.source, "moleListed": removed,
                                        "items": store.items.map { "\($0.index):\($0.path ?? "?")" }.joined(separator: " | ")])
        }
    }
}

private struct InstallerCard: View {
    let item: InstallerItem
    let selected: Bool
    let theme: FeatureTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: !item.isLocated ? "nosign" : selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.tertiary))
                if let path = item.path {
                    FileIconView(path: path, size: 32)
                } else {
                    Image(systemName: item.kindSymbol).font(.system(size: 20)).foregroundStyle(theme.accent)
                        .frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.isLocated {
                        Text("Location unclear · remove it in Finder").font(.caption).foregroundStyle(Color.moleWarn).lineLimit(1)
                    } else if let path = item.path {
                        Text(MoleHomeDir.abbreviate(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(".\(item.kind)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(kindColor)
                    .frame(width: 48, alignment: .leading)
                Text(item.modified.map { RelativeAge.string($0) } ?? "—")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(ByteFormat.string(item.bytes))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(selected ? theme.accent.opacity(0.12) : hovering ? Color.primary.opacity(0.05) : .clear)
        .opacity(item.isLocated ? 1 : 0.7)
        .help(item.isLocated ? item.path.map { MoleHomeDir.abbreviate($0) } ?? item.displayName
              : "Several files look like this one (same name and size), or it could not be found on disk, so it can't be removed here. Remove it in Finder.")
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.displayName), \(item.kind) installer, \(item.size), in \(item.source)\(item.isLocated ? "" : ", location unclear, cannot be selected")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var kindColor: Color {
        switch item.kind {
        case "dmg": .blue
        case "pkg", "mpkg": .orange
        case "iso": .purple
        case "xip": .teal
        case "zip": .gray
        default: .secondary
        }
    }
}
