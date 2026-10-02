import SwiftUI

// MARK: - Task card

struct OptimizeTaskCard: View {
    let task: OptimizeTask
    let vm: OptimizeModel
    let theme: FeatureTheme
    let expanded: Bool
    let toggleExpanded: () -> Void
    @State private var hovering = false

    var body: some View {
        let included = vm.isIncluded(task)
        let progress = vm.report.tasks[task.id]
        let state = progress?.state ?? .pending
        let lines = progress?.lines ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(included ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: task.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: included ? theme.accent.opacity(0.3) : .clear, radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.displayName).font(.headline).lineLimit(1)
                    Text(task.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Toggle("Include \(task.displayName)", isOn: Binding(get: { included }, set: { vm.setIncluded(task, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!vm.canEditWhitelist)
                    .help(included ? "Included. Turn off to have Mole skip this task." : "Skipped. Turn on to include it again.")
            }
            HStack(spacing: 6) {
                stateBadge(state, included: included)
                if task.needsAdmin { Pill(text: "Admin", symbol: "lock.shield.fill", tint: .orange) }
                if let note = task.note { Pill(text: note, tint: .secondary) }
                Spacer(minLength: 0)
            }
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(expanded ? lines : Array(lines.prefix(2))) { line in
                        OptimizeLineView(line: line)
                            .font(.caption)
                    }
                    if lines.count > 2 {
                        Button(expanded ? "Show less" : "Show \(lines.count - 2) more", action: toggleExpanded)
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(tint(state).map { .regular.tint($0.opacity(0.12)) } ?? .regular, in: .rect(cornerRadius: Metrics.tileRadius))
        .opacity(included ? 1 : 0.62)
        .scaleEffect(hovering ? 1.01 : 1)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
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
                    Button("Manage", action: openProtection).buttonStyle(.glass)
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
