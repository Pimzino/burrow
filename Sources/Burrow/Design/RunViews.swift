import SwiftUI

/// A compact row showing a run's live state: what is happening, for how long, and a way to stop it.
struct RunStatusCard: View {
    let run: CommandRun
    let theme: FeatureTheme
    var headline: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(headline ?? statusText).font(.callout.weight(.semibold))
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
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
                    .buttonStyle(.soft)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder private var statusIcon: some View {
        switch run.state {
        case .running:
            ProgressView().controlSize(.small).frame(width: 22)
        case .finished(let code) where code == 0:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.moleGood).font(.title3)
        case .cancelled:
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary).font(.title3)
        default:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.moleWarn).font(.title3)
        }
    }

    private var statusText: String {
        switch run.state {
        case .running: "Working…"
        case .finished(0): "Finished"
        case .finished: run.authFailed ? "Administrator access was not granted" : "Mole couldn’t finish"
        case .failedToStart(let message): message
        case .cancelled: "Stopped"
        }
    }

    /// What Mole last said when a run fails, as plain text.
    private var failure: String? {
        guard case .finished(let code) = run.state, code != 0, !run.authFailed else { return nil }
        return run.lines.last { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?
            .text.trimmingCharacters(in: .whitespaces)
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
                Text("Your password goes straight to macOS. It is never stored or logged, and access is revoked when the task ends.")
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
                    .buttonStyle(.hero(tint: .accentColor))
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
            .controlSize(.large)
        }
        .padding(28)
        .frame(minWidth: 520, maxWidth: 640)
    }
}
