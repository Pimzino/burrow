import SwiftUI

/// Touch ID for sudo, read from PAM with Mole's own semantics.
///
/// Mole's `is_touchid_configured` (bin/touchid.sh at V1.56.0) is a plain `grep -q pam_tid.so` on
/// sudo_local, then sudo, so a commented-out line counts as "enabled" for every Mole decision
/// (`enable` says "already enabled", `disable` removes every line containing it). The app mirrors
/// that exactly, and separately tracks whether sudo really loads the module.
enum TouchIDStatus {
    struct State: Equatable {
        /// What Mole believes (`grep -q pam_tid.so`).
        var configured: Bool
        /// A line that isn't commented out loads pam_tid.so, so sudo really accepts Touch ID.
        var active: Bool
        /// The file Mole found `pam_tid.so` in.
        var source: String?

        /// Only commented-out lines: Mole says enabled, sudo doesn't use it.
        var commentedOut: Bool { configured && !active }
    }

    static func read(files: [String] = [MolePaths.pamSudoLocal, MolePaths.pamSudo],
                     contents: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> State {
        var state = State(configured: false, active: false, source: nil)
        for path in files {
            guard let text = contents(path) else { continue }
            if !state.configured, text.contains("pam_tid.so") {
                state.configured = true
                state.source = path
            }
            let active = text.split(separator: "\n").contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("#") && t.contains("pam_tid.so")
            }
            if active { state.active = true }
        }
        return state
    }

    /// `mo touchid status` prints "Touch ID is enabled for sudo" or "Touch ID is not configured for sudo".
    static func parseStatus(_ text: String) -> Bool? {
        if text.contains("Touch ID is enabled for sudo") { return true }
        if text.contains("Touch ID is not configured") { return false }
        return nil
    }

    /// Dry-run outcomes where Mole would change nothing.
    static func dryRunIsNoOp(_ text: String) -> Bool {
        text.contains("already enabled, no changes needed") || text.contains("Touch ID is not currently enabled")
    }
}

struct SettingsTouchIDPane: View {
    @Environment(MoleService.self) private var service
    @State private var state = TouchIDStatus.read()
    @State private var preview: Preview?
    /// A dry run that won't lead to a change (no-op or failure), shown inline instead of a sheet.
    @State private var notice: Notice?
    @State private var loadingPreview = false
    @State private var run: CommandRun?

    struct Preview: Identifiable {
        let id = UUID()
        let enable: Bool
        let lines: [OutputLine]
    }

    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    private enum Display { case on, off, inactive }

    private var display: Display {
        if state.active { return .on }
        return state.commentedOut ? .inactive : .off
    }

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(tab: .touchID, subtitle: "Approve Mole's administrator tasks, and any sudo in Terminal, with your fingerprint.")
            }
            Section {
                statusRow
                    .padding(.vertical, 6)
                if let notice {
                    Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.callout)
                        .foregroundStyle(notice.isError ? Color.moleWarn : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            if let run {
                Section("Last change") {
                    RunStatusCard(run: run, theme: .settings)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                Label("Changing this needs your administrator password once. Mole shows exactly what it will change before anything happens.",
                      systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .sheet(item: $preview) { preview in
            ConfirmSheet(theme: .settings,
                         title: sheetTitle(preview),
                         message: "This is what Mole will change:",
                         confirmTitle: preview.enable ? "Turn On" : (state.commentedOut ? "Remove Line" : "Turn Off"),
                         destructive: !preview.enable,
                         onConfirm: { apply(enable: preview.enable) },
                         onCancel: { self.preview = nil }) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(preview.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { line in
                            Text(line.text.trimmingCharacters(in: .whitespaces))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                    if !preview.enable && state.commentedOut {
                        Label("Mole removes every line mentioning pam_tid.so from \(state.source ?? MolePaths.pamSudoLocal), including the commented-out one. Touch ID stays off; you can then turn it on properly.",
                              systemImage: "text.badge.minus")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label("You'll be asked for your administrator password.", systemImage: "key.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: display == .on ? SettingsTab.touchID.colors : [.gray.opacity(0.5), .gray.opacity(0.3)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                Image(systemName: "touchid")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Touch ID for sudo").font(.title3.weight(.semibold))
                    switch display {
                    case .on: SettingsStatusPill(text: "On", on: true)
                    case .off: SettingsStatusPill(text: "Off", on: false)
                    case .inactive: SettingsStatusPill(text: "Commented out", on: true, onColor: .orange)
                    }
                }
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        // Mole's `enable` would be a no-op while a commented line exists, so the
                        // commented-out case goes through `disable` first (it removes that line).
                        loadPreview(enable: !state.configured)
                    } label: {
                        Label(buttonTitle, systemImage: display == .on ? "xmark.circle" : display == .inactive ? "text.badge.minus" : "touchid")
                    }
                    .buttonStyle(.hero(tint: .accentColor))
                    .tint(display == .off ? SettingsTab.touchID.colors[0] : display == .inactive ? .orange : .secondary)
                    .disabled(loadingPreview || run?.state.isRunning == true || !service.isAvailable)
                    if loadingPreview { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .buttonStyle(.soft)
                }
                .padding(.top, 4)
            }
        }
    }

    private var buttonTitle: String {
        switch display {
        case .on: "Turn Off…"
        case .off: "Turn On…"
        case .inactive: "Clean Up…"
        }
    }

    private var statusDetail: String {
        let file = state.source ?? MolePaths.pamSudoLocal
        switch display {
        case .on:
            return "Enabled in \(file). Password prompts accept your fingerprint."
        case .inactive:
            return "\(file) mentions pam_tid.so only in a commented-out line, so sudo still asks for your password, but Mole treats Touch ID as already enabled and won't turn it on. Clean Up removes that line; then turn Touch ID on."
        case .off:
            return "Mole adds pam_tid.so to /etc/pam.d/sudo_local, which survives macOS updates."
        }
    }

    private func sheetTitle(_ preview: Preview) -> String {
        if preview.enable { return "Turn On Touch ID for sudo?" }
        return state.commentedOut ? "Remove the Commented-Out Touch ID Line?" : "Turn Off Touch ID for sudo?"
    }

    /// Reads PAM directly, then asks Mole itself so the app's view never disagrees with Mole's.
    private func refresh() async {
        var fresh = TouchIDStatus.read()
        if service.isAvailable,
           let result = try? await service.collect(["touchid", "status"], timeout: 20),
           let moleSays = TouchIDStatus.parseStatus(result.stdoutString + result.stderrString) {
            fresh.configured = moleSays
            if !moleSays { fresh.active = false }
        }
        withAnimation(.smooth) { state = fresh }
    }

    private func loadPreview(enable: Bool) {
        loadingPreview = true
        withAnimation(.smooth) { notice = nil }
        Task {
            defer { loadingPreview = false }
            await refresh()
            // Explicit subcommand + --dry-run: never prompts and changes nothing.
            let args = ["touchid", enable ? "enable" : "disable", "--dry-run"]
            do {
                let result = try await service.collect(args, timeout: 30)
                let text = (result.stdoutString + result.stderrString).trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.succeeded else {
                    withAnimation(.smooth) {
                        notice = Notice(text: "Mole's dry run failed (exit code \(result.exitCode)): \(text.split(separator: "\n").last.map(String.init) ?? "no output")",
                                        isError: true)
                    }
                    return
                }
                guard !TouchIDStatus.dryRunIsNoOp(text) else {
                    withAnimation(.smooth) {
                        notice = Notice(text: enable ? "Mole reports Touch ID is already enabled, so there is nothing to change."
                                                     : "Mole reports Touch ID isn't enabled, so there is nothing to change.",
                                        isError: false)
                    }
                    return
                }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
                    OutputLine(id: $0.offset, stream: .stdout, raw: String($0.element))
                }
                preview = Preview(enable: enable, lines: lines)
            } catch {
                withAnimation(.smooth) { notice = Notice(text: error.localizedDescription, isError: true) }
            }
        }
    }

    private func apply(enable: Bool) {
        preview = nil
        // stdin stays at EOF: the only prompt ("Continue anyway? [y/N]") then declines.
        let title = enable ? "Turn on Touch ID for sudo" : (state.commentedOut ? "Remove commented-out Touch ID line" : "Turn off Touch ID for sudo")
        let run = service.start(title, ["touchid", enable ? "enable" : "disable"], admin: true)
        withAnimation(.smooth) { self.run = run }
        run.onCompletion { _ in
            Task { await refresh() }
        }
    }
}
