import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, touchID, completion, updates, logs, uninstall, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .touchID: "Touch ID"
        case .completion: "Completion"
        case .updates: "Updates"
        case .logs: "Logs"
        case .uninstall: "Uninstall"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .touchID: "touchid"
        case .completion: "keyboard"
        case .updates: "arrow.down.circle"
        case .logs: "doc.text.magnifyingglass"
        case .uninstall: "trash"
        case .about: "info.circle"
        }
    }

    /// Accent pair for each pane's header badge.
    var colors: [Color] {
        switch self {
        case .general: [Color(red: 0.45, green: 0.47, blue: 0.53), Color(red: 0.66, green: 0.68, blue: 0.74)]
        case .touchID: [Color(red: 1.0, green: 0.30, blue: 0.40), Color(red: 1.0, green: 0.52, blue: 0.45)]
        case .completion: [Color(red: 0.12, green: 0.14, blue: 0.18), Color(red: 0.32, green: 0.36, blue: 0.42)]
        case .updates: [Color(red: 0.25, green: 0.52, blue: 1.0), Color(red: 0.20, green: 0.84, blue: 0.95)]
        case .logs: [Color(red: 0.40, green: 0.48, blue: 0.62), Color(red: 0.55, green: 0.66, blue: 0.80)]
        case .uninstall: [Color(red: 1.0, green: 0.30, blue: 0.35), Color(red: 0.85, green: 0.15, blue: 0.30)]
        case .about: [Color(red: 0.49, green: 0.33, blue: 1.0), Color(red: 0.85, green: 0.40, blue: 0.95)]
        }
    }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { item in
                pane(item)
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
            }
        }
        .frame(width: 620, height: 560)
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: SettingsGeneralPane()
        case .touchID: SettingsTouchIDPane()
        case .completion: SettingsCompletionPane()
        case .updates: SettingsUpdatesPane()
        case .logs: SettingsLogsPane()
        case .uninstall: SettingsUninstallPane()
        case .about: SettingsAboutPane()
        }
    }
}

// MARK: - Shared pieces

/// The badge + title + subtitle at the top of each pane.
struct SettingsPaneHeader: View {
    let tab: SettingsTab
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: tab.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.clear)
    }
}

/// A label + value row for read-only facts.
struct SettingsFactRow: View {
    let title: String
    let value: String
    var monospaced = false
    var revealPath: String? = nil

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value)
                    .font(monospaced ? .callout.monospaced() : .callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let revealPath {
                    Button("Reveal in Finder", systemImage: "arrow.right.circle.fill") { Finder.reveal(revealPath) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Reveal in Finder")
                }
            }
        }
    }
}

/// A status pill with a dot.
struct SettingsStatusPill: View {
    let text: String
    let on: Bool
    var onColor: Color = .moleGood

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(on ? onColor : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background((on ? onColor : Color.secondary).opacity(0.14), in: .capsule)
        .foregroundStyle(on ? onColor : .secondary)
    }
}

/// Monospaced read-only text block with a copy button.
struct SettingsCodeBlock: View {
    let text: String
    var maxHeight: CGFloat = 200
    @State private var copied = false

    var body: some View {
        ScrollView(.vertical) {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .padding(.trailing, 34)
        }
        .frame(maxHeight: maxHeight)
        .background(.black.opacity(0.22), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
        .overlay(alignment: .topTrailing) {
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                withAnimation(.snappy) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.snappy) { copied = false }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.soft)
            .controlSize(.small)
            .contentTransition(.symbolEffect(.replace))
            .help("Copy to Clipboard")
            .padding(6)
        }
    }
}

extension CommandRun.State {
    var settingsLabel: String {
        switch self {
        case .running: "Running"
        case .finished(0): "Succeeded"
        case .finished(let code): "Exit \(code)"
        case .failedToStart: "Couldn't start"
        case .cancelled: "Stopped"
        }
    }

    var settingsSymbol: String {
        switch self {
        case .running: "circle.dotted"
        case .finished(0): "checkmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        default: "exclamationmark.circle.fill"
        }
    }

    var settingsColor: Color {
        switch self {
        case .running: .accentColor
        case .finished(0): .moleGood
        case .cancelled: .secondary
        default: .moleWarn
        }
    }
}
