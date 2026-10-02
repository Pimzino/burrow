import SwiftUI

/// Monospaced transcript of a command's output, auto-scrolling as lines arrive.
struct ConsoleView: View {
    let lines: [OutputLine]
    var maxHeight: CGFloat = 260
    var showsStderr = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.filter { showsStderr || $0.stream != .stderr }) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: maxHeight)
            .background(.black.opacity(0.22), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.06)))
            .onChange(of: lines.last?.id) { _, id in
                if let id { withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private func color(for line: OutputLine) -> Color {
        let t = line.text.trimmingCharacters(in: .whitespaces)
        if line.stream == .stderr { return t.hasPrefix("[DEBUG]") ? .secondary : Color.moleBad.opacity(0.95) }
        if t.hasPrefix("✓") { return .moleGood }
        if t.hasPrefix("◎") || t.hasPrefix("!") { return .moleWarn }
        if t.hasPrefix("☻") { return .moleBad }
        if t.hasPrefix("➤") { return .primary }
        if t.hasPrefix("→") || t.hasPrefix("⊙") || t.hasPrefix("↳") { return .secondary }
        return .primary.opacity(0.85)
    }
}

/// A compact card showing a run's live state with cancel and a collapsible transcript.
struct RunStatusCard: View {
    let run: CommandRun
    let theme: FeatureTheme
    var headline: String? = nil
    var showConsoleInitially = false
    @State private var showConsole: Bool? = nil

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline ?? statusText).font(.headline)
                        Text(run.commandLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if run.admin {
                        Pill(text: run.authenticated ? "Admin" : "Admin requested", symbol: "lock.shield", tint: .orange)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Duration.seconds(run.duration).formatted(.time(pattern: .minuteSecond)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if run.state.isRunning {
                        Button("Stop", systemImage: "stop.fill") { run.cancel() }
                            .buttonStyle(.glass)
                    }
                    Button {
                        withAnimation(.snappy) { showConsole = !(showConsole ?? showConsoleInitially) }
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .buttonStyle(.glass)
                    .help("Show Mole output")
                }
                if showConsole ?? showConsoleInitially {
                    ConsoleView(lines: run.lines)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch run.state {
        case .running:
            ProgressView().controlSize(.small).frame(width: 22)
        case .finished(let code) where code == 0:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.moleGood).font(.title2)
        case .cancelled:
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary).font(.title2)
        default:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.moleWarn).font(.title2)
        }
    }

    private var statusText: String {
        switch run.state {
        case .running: "Running…"
        case .finished(0): "Finished"
        case .finished(let code): run.authFailed ? "Administrator access was not granted" : "Finished with exit code \(code)"
        case .failedToStart(let message): message
        case .cancelled: "Stopped"
        }
    }
}

/// The administrator password sheet shown when sudo prompts inside a privileged run.
struct AuthSheet: View {
    let request: AuthCoordinator.Request
    let submit: (String?) -> Void
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                .symbolEffect(.wiggle, value: request.retry)
            VStack(spacing: 6) {
                Text("Administrator Access").font(.title2.bold())
                Text(request.reason)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("Your password goes straight to sudo on a private terminal. It is never stored or logged, and access is revoked when the task ends.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }
            if request.retry {
                Label("Incorrect password, try again.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Color.moleBad)
                    .font(.callout)
            }
            SecureField("Password for \(NSUserName())", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(confirm)
                .frame(width: 300)
            HStack {
                Button("Cancel", role: .cancel) { submit(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Authorize", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(32)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func confirm() {
        guard !password.isEmpty else { return }
        let value = password
        password = ""
        submit(value)
    }
}

/// A reusable confirmation sheet for destructive actions.
struct ConfirmSheet<Details: View>: View {
    let theme: FeatureTheme
    let title: String
    let message: String
    let confirmTitle: String
    var destructive = true
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var details: Details

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                FeatureIcon(theme: theme, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.bold())
                    Text(message).foregroundStyle(.secondary)
                }
            }
            details
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                // A stray Return must never confirm something destructive.
                if destructive {
                    Button(confirmTitle, role: .destructive, action: onConfirm)
                        .buttonStyle(.hero(theme))
                } else {
                    Button(confirmTitle, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.hero(theme))
                }
            }
        }
        .padding(28)
        .frame(minWidth: 520, maxWidth: 640)
    }
}
