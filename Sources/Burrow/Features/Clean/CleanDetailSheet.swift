import SwiftUI

/// Every path Mole found for one section, from `~/.config/mole/clean-list.txt`.
struct CleanSectionDetailSheet: View {
    let vm: CleanModel
    let request: CleanDetailRequest
    @Environment(MoleService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sort: Sort = .size
    @State private var justProtected: String?
    @State private var pendingProtect: CleanPreviewList.Entry?
    @State private var protectError: String?

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size", name = "Name"
        var id: String { rawValue }
    }

    private var tint: Color { CleanStyle.color(for: request.section) }

    var body: some View {
        let all = vm.preview?.entries(for: request.section) ?? []
        let entries = filtered(all)
        let total = all.filter { $0.countedUnder == nil }.compactMap(\.sizeBytes).reduce(0, +)
        let maxBytes = max(1, all.compactMap(\.sizeBytes).max() ?? 1)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                TidyGlyph(symbol: CleanStyle.symbol(for: request.section), tint: tint, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.section).font(.title2.bold())
                    Text("\(all.count) paths · \(ByteFormat.string(total))\(vm.preview?.generated.map { " · previewed \($0)" } ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
            }
            .padding(20)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter paths", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            if entries.isEmpty {
                EmptyStateView(symbol: "doc.text.magnifyingglass", title: all.isEmpty ? "No file list" : "No matches",
                               message: all.isEmpty ? "Mole didn’t list individual paths for this section." : "Try a different filter.")
                    .frame(maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    row(entry, maxBytes: maxBytes)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield").foregroundStyle(Color.moleGood)
                Text("Protect adds a path to ~/.config/mole/whitelist so future cleans skip it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let protectError {
                    Label(protectError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.moleWarn)
                        .lineLimit(2)
                        .help(protectError)
                        .transition(.opacity)
                } else if let justProtected {
                    Label("Saved: \(justProtected.replacingOccurrences(of: "\n", with: "↵").abbreviatingHome)", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.moleGood)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 620)
        .confirmationDialog("Protect this path?", isPresented: Binding(get: { pendingProtect != nil }, set: { if !$0 { pendingProtect = nil } }),
                            presenting: pendingProtect) { entry in
            Button("Protect") { protect(entry) }
            Button("Cancel", role: .cancel) { pendingProtect = nil }
        } message: { entry in
            Text(protectMessage(entry))
        }
    }

    private func protectMessage(_ entry: CleanPreviewList.Entry) -> String {
        let shown = entry.displayPath.abbreviatingHome
        var text = MoleConfigIO.exists(MolePaths.cleanWhitelist)
            ? "\(shown) will be added to your whitelist and skipped by future cleans."
            : "\(shown) will be added to a new whitelist file. Mole’s default protections are written into it too, so they stay active."
        if WhitelistPattern.isGlob(entry.path) {
            text += " Its name contains *, ? or [, so it is saved escaped to match only this path."
        }
        return text
    }

    private func filtered(_ all: [CleanPreviewList.Entry]) -> [CleanPreviewList.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? all : all.filter { $0.path.localizedCaseInsensitiveContains(q) }
        switch sort {
        case .size: return base.sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        case .name: return base.sorted { ($0.path as NSString).lastPathComponent.localizedStandardCompare(($1.path as NSString).lastPathComponent) == .orderedAscending }
        }
    }

    private func row(_ entry: CleanPreviewList.Entry, maxBytes: Int64) -> some View {
        let name = (entry.displayPath as NSString).lastPathComponent
        let parent = ((entry.displayPath as NSString).deletingLastPathComponent).abbreviatingHome
        let isProtected = vm.isProtected(entry.path)
        let cantProtect = isProtected ? nil : WhitelistPattern.literalProtectionError(entry.path)
        return HStack(spacing: 12) {
            Image(nsImage: Finder.icon(for: entry.path)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.callout.weight(.medium)).lineLimit(1)
                    if isProtected { Pill(text: "Protected", symbol: "checkmark.shield.fill", tint: .moleGood) }
                }
                Text(parent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let under = entry.countedUnder {
                    Text("Counted under \(under.abbreviatingHome)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.sizeBytes.map(ByteFormat.string) ?? "Size unknown")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(entry.sizeBytes == nil ? .secondary : .primary)
                if let b = entry.sizeBytes {
                    CapsuleBar(fraction: Double(b) / Double(maxBytes), tint: tint, height: 3).frame(width: 90)
                }
                if let items = entry.items { Text("\(items.formatted()) items").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(width: 110, alignment: .trailing)
            Button { Finder.reveal(entry.path) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(name) in Finder")
            Button { pendingProtect = entry } label: {
                Image(systemName: isProtected ? "checkmark.shield.fill" : "shield")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isProtected ? Color.moleGood : Color.accentColor)
            .disabled(isProtected || cantProtect != nil)
            .help(isProtected ? "Already protected" : cantProtect ?? "Protect: never clean this path")
            .accessibilityLabel(isProtected ? "\(name) is protected" : "Protect \(name)")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .tidyHover()
        .tidyFileMenu(entry.path) {
            if !isProtected && cantProtect == nil {
                Divider()
                Button("Protect…", systemImage: "checkmark.shield") { pendingProtect = entry }
            }
        }
    }

    private func protect(_ entry: CleanPreviewList.Entry) {
        pendingProtect = nil
        Task {
            let error = await vm.protect(entry.path, service: service)
            withAnimation {
                protectError = error
                justProtected = error == nil ? entry.path : nil
            }
        }
    }
}
