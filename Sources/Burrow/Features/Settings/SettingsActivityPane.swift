import SwiftUI

/// Every Mole command this app session has run, with its transcript.
struct SettingsActivityPane: View {
    @Environment(MoleService.self) private var service
    @State private var selection: CommandRun.ID?

    private var runs: [CommandRun] { service.runs.reversed() }
    private var selected: CommandRun? { runs.first { $0.id == selection } ?? runs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                SettingsPaneHeader(tab: .activity, subtitle: "Commands Burrow ran this session.")
                Button("Clear Finished", systemImage: "clear") {
                    withAnimation(.smooth) { service.clearFinishedRuns() }
                }
                .buttonStyle(.glass)
                .disabled(!service.runs.contains { !$0.state.isRunning })
            }
            if runs.isEmpty {
                Spacer()
                EmptyStateView(symbol: "waveform.path.ecg", title: "Nothing yet",
                               message: "Scans, cleanups and other Mole commands appear here as they run.")
                Spacer()
            } else {
                List(runs, selection: $selection) { run in
                    SettingsRunRow(run: run).tag(run.id)
                        .contextMenu {
                            Button("Copy Command", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(run.commandLine, forType: .string)
                            }
                            if run.state.isRunning {
                                Button("Stop", systemImage: "stop.fill", role: .destructive) { run.cancel() }
                            }
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
                .frame(height: 170)
                if let selected {
                    SettingsRunDetail(run: selected)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SettingsRunRow: View {
    let run: CommandRun

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if run.state.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: run.state.settingsSymbol).foregroundStyle(run.state.settingsColor)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(run.title).font(.callout.weight(.medium)).lineLimit(1)
                    if run.admin { Image(systemName: "lock.shield.fill").font(.caption).foregroundStyle(.orange) }
                }
                Text(run.commandLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(run.startedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Text(Duration.seconds(run.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(run.state.settingsLabel)
    }
}

private struct SettingsRunDetail: View {
    let run: CommandRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(run.state.settingsLabel, systemImage: run.state.settingsSymbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(run.state.settingsColor)
                Text("\(run.lines.count) lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if run.state.isRunning {
                    Button("Stop", systemImage: "stop.fill") { run.cancel() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(".", modifiers: .command)
                }
            }
            if case .failedToStart(let message) = run.state {
                ErrorBanner(message: message)
            }
            ConsoleView(lines: run.lines, maxHeight: .infinity)
                .overlay {
                    if run.lines.isEmpty {
                        Text(run.state.isRunning ? "Waiting for output…" : "No output")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
