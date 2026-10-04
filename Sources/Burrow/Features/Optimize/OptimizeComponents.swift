import SwiftUI

// MARK: - Task list

/// All maintenance tasks as one list: what each does, its latest result, and whether it is included.
struct OptimizeTaskList: View {
    let vm: OptimizeModel
    let theme: FeatureTheme
    /// Automation aid for screenshots: `-MoleE2EExpand <name>` opens that row.
    @State private var expanded: Set<String> = Set(UserDefaults.standard.string(forKey: "MoleE2EExpand").map { [$0] } ?? [])

    var body: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Maintenance tasks").font(.headline)
                    Spacer()
                    Text("\(vm.includedTasks.count) of \(vm.tasks.count) included")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                ForEach(vm.tasks) { task in
                    Divider().opacity(0.5)
                    OptimizeTaskRow(task: task, vm: vm, theme: theme, expanded: expanded.contains(task.id)) {
                        withAnimation(.snappy) { expanded.formSymmetricDifference([task.id]) }
                    }
                }
            }
        }
    }
}

struct OptimizeTaskRow: View {
    let task: OptimizeTask
    let vm: OptimizeModel
    let theme: FeatureTheme
    let expanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        let included = vm.isIncluded(task)
        let progress = vm.report.tasks[task.id]
        let state = progress?.state ?? .pending
        let lines = progress?.lines ?? []
        // A task that needs attention shows why without being asked.
        let open = !lines.isEmpty && (expanded || state == .attention)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 14) {
                        TidyGlyph(symbol: task.symbol, tint: included ? theme.accent : .secondary, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(task.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                                if task.needsAdmin {
                                    Image(systemName: "lock.shield.fill").font(.caption).foregroundStyle(.orange)
                                        .help("Needs administrator access")
                                }
                            }
                            Text(task.note.map { "\(task.summary) · \($0)" } ?? task.summary)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        stateBadge(state, included: included)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .opacity(lines.isEmpty ? 0 : 1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(lines.isEmpty)
                Toggle("Include \(task.displayName)", isOn: Binding(get: { included }, set: { vm.setIncluded(task, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!vm.canEditWhitelist)
                    .help(included ? "Included. Turn off to have Mole skip this task." : "Skipped. Turn on to include it again.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines) { line in
                        OptimizeLineView(line: line).font(.caption)
                    }
                }
                .padding(.leading, 66)
                .padding(.trailing, 20)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background(tint(state).map { $0.opacity(0.07) } ?? .clear)
        .opacity(included ? 1 : 0.6)
        .animation(.smooth, value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.displayName), \(included ? "included" : "skipped")")
    }

    private func tint(_ state: OptimizeReport.TaskState) -> Color? {
        switch state {
        case .running: theme.accent
        case .attention: .moleWarn
        default: nil
        }
    }

    @ViewBuilder private func stateBadge(_ state: OptimizeReport.TaskState, included: Bool) -> some View {
        let preview = vm.runningMode == .preview || vm.resultMode == .preview
        switch state {
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(preview ? "Checking…" : "Working…").font(.caption.weight(.semibold))
            }
            .foregroundStyle(theme.accent)
        case .applied:
            Pill(text: preview ? "Ready" : "Done", symbol: "checkmark.circle.fill", tint: .moleGood)
        case .attention:
            Pill(text: "Needs attention", symbol: "exclamationmark.triangle.fill", tint: .moleWarn)
        case .unavailable:
            Pill(text: "Not available", symbol: "minus.circle.fill", tint: .secondary)
        case .excluded:
            Pill(text: "Skipped by you", symbol: "slash.circle", tint: .secondary)
        case .pending:
            if !included {
                Pill(text: "Skipped", symbol: "slash.circle", tint: .secondary)
            } else if vm.isRunning {
                Pill(text: "Queued", symbol: "clock", tint: .secondary)
            }
        }
    }
}

// MARK: - Options

struct OptimizeOptionsCard: View {
    @Bindable var vm: OptimizeModel
    let openProtection: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Options", symbol: "slider.horizontal.3")
                TidyOptionRow(symbol: "internaldrive.fill", tint: .blue, title: "Verify disk health",
                              detail: "Runs a filesystem integrity check during real runs (MOLE_ENABLE_DISK_VERIFY). It takes a while and is skipped in previews.") {
                    Toggle("Verify disk health", isOn: $vm.enableDiskVerify).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.5)
                TidyOptionRow(symbol: "checkmark.shield.fill", tint: .green, title: "Exclusions",
                              detail: exclusionText) {
                    Button("Manage", action: openProtection).buttonStyle(.soft)
                }
            }
        }
        .disabled(vm.isRunning)
    }

    private var exclusionText: String {
        let tasks = vm.excludedTasks.count
        let paths = vm.pathPatterns.count
        if tasks == 0 && paths == 0 { return "Nothing is excluded. Skipped tasks and protected disk images are saved to ~/.config/mole/whitelist_optimize." }
        var parts: [String] = []
        if tasks > 0 { parts.append("\(tasks) task\(tasks == 1 ? "" : "s") skipped") }
        if paths > 0 { parts.append("\(paths) path pattern\(paths == 1 ? "" : "s") kept mounted") }
        return parts.joined(separator: ", ") + " · ~/.config/mole/whitelist_optimize"
    }
}

// MARK: - Confirmation

struct OptimizeConfirmSheet: View {
    let vm: OptimizeModel
    let theme: FeatureTheme
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let included = vm.includedTasks
        let admin = included.filter(\.needsAdmin)
        ConfirmSheet(theme: theme, title: "Optimize your Mac?",
                     message: "Mole runs \(included.count) maintenance task\(included.count == 1 ? "" : "s") now.",
                     confirmTitle: "Optimize", destructive: false, onConfirm: onConfirm, onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(included) { t in
                            Label {
                                Text(t.displayName).lineLimit(1)
                            } icon: {
                                Image(systemName: t.symbol).foregroundStyle(theme.accent).frame(width: 22)
                            }
                            .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: 170)
                Divider()
                bullet("lock.shield.fill", .orange, "You’ll be asked for your administrator password. \(admin.count) task\(admin.count == 1 ? " uses" : "s use") it (DNS, network, permissions, Spotlight, periodic scripts).")
                bullet("arrow.triangle.2.circlepath", .blue, "Some services restart briefly, like mDNSResponder and Finder’s thumbnail cache. Open work is not affected.")
                if !vm.excludedTasks.isEmpty {
                    bullet("slash.circle", .secondary, "Skipped: " + vm.excludedTasks.map(\.displayName).joined(separator: ", "))
                }
                if vm.enableDiskVerify {
                    bullet("internaldrive.fill", .blue, "Disk verification is on and can take several minutes.")
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
        }
    }

    private func bullet(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
    }
}
