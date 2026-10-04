import SwiftUI

/// Removes the Mole CLI itself (`mo remove`). Always previews with `--dry-run` first, only arms
/// after a clean preview, runs with admin when a launcher sits in a folder the user can't write to,
/// and declines Mole's prompt if the real list differs from the preview.
struct SettingsUninstallPane: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @State private var preview: MoleRemoval.Preview?
    @State private var previewError: String?
    @State private var loading = false
    @State private var confirmText = ""
    @State private var run: CommandRun?
    @State private var outcome: MoleRemoval.Outcome?
    @FocusState private var fieldFocused: Bool

    /// Only a successful dry run that listed something can arm the button.
    private var previewOK: Bool {
        guard let preview else { return false }
        return previewError == nil && preview.completed && !preview.items.isEmpty
    }

    private var adminPaths: [String] { preview?.binariesNeedingAdmin() ?? [] }
    private var needsAdmin: Bool { !adminPaths.isEmpty }
    private var isRunning: Bool { run?.state.isRunning == true }
    private var armed: Bool { confirmText == "REMOVE" && previewOK && !isRunning && !loading && service.isAvailable }

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(tab: .uninstall, subtitle: "Remove the Mole command-line tool from this Mac.")
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Danger zone", systemImage: "exclamationmark.octagon.fill")
                        .font(.headline)
                        .foregroundStyle(Color.moleBad)
                    Text("This uninstalls the Mole CLI, deletes its cache and logs, and moves ~/.config/mole (your whitelists and settings) to the Trash. This app stops working until Mole is installed again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    previewBlock
                }
                .padding(.vertical, 4)
            }
            if previewOK { confirmSection }
            if let run {
                Section("Uninstall") {
                    if let outcome { outcomeBanner(outcome) }
                    RunStatusCard(run: run, theme: .uninstall, headline: outcome.map { headline($0) })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var confirmSection: some View {
        Section {
            if needsAdmin {
                Label {
                    Text("\(adminPaths.map(\.abbreviatingHome).joined(separator: ", ")) \(adminPaths.count == 1 ? "is" : "are") in a folder only an administrator can change, so you'll be asked for your password.")
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent {
                TextField("", text: $confirmText, prompt: Text("REMOVE"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 140)
                    .focused($fieldFocused)
                    .autocorrectionDisabled()
            } label: {
                Text("Type REMOVE to confirm")
            }
            HStack {
                Button("Check Again", systemImage: "arrow.clockwise", action: loadPreview)
                    .buttonStyle(.soft)
                    .disabled(loading || isRunning)
                Spacer()
                Button(role: .destructive, action: remove) {
                    Label(needsAdmin ? "Uninstall Mole (Admin)…" : "Uninstall Mole", systemImage: "trash.fill")
                }
                .buttonStyle(.hero(tint: .accentColor))
                .tint(Color.moleBad)
                .disabled(!armed)
            }
        }
    }

    // MARK: Preview

    @ViewBuilder private var previewBlock: some View {
        if let preview, previewOK {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(preview.items, id: \.self) { item in
                    previewRow(item)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.moleBad.opacity(0.08), in: .rect(cornerRadius: 12))
        } else if let preview, preview.nothingInstalled, previewError == nil {
            InfoBanner(symbol: "questionmark.folder", title: "No Mole installation found",
                       message: "Mole's dry run didn't find anything to remove.", tint: Color.secondary,
                       actionTitle: "Check Again", action: { loadPreview() })
        } else if preview != nil || previewError != nil {
            VStack(alignment: .leading, spacing: 8) {
                ErrorBanner(message: previewError ?? "Mole's dry run didn't list anything to remove, so uninstalling stays disabled.",
                            retry: { loadPreview() })
            }
        } else {
            Button {
                loadPreview()
            } label: {
                Label(loading ? "Checking…" : "Show What Will Be Removed", systemImage: "eye")
            }
            .buttonStyle(.soft)
            .disabled(loading || !service.isAvailable)
        }
    }

    private func previewRow(_ item: MoleRemoval.Item) -> some View {
        let (text, symbol): (String, String) = switch item {
        case .homebrew: ("Would uninstall Mole with Homebrew", "mug")
        case .remove(let p): ("Would remove: \(p.abbreviatingHome)", "xmark.bin")
        case .trash(let p): ("Would move to Trash: \(p.abbreviatingHome)", "trash")
        case .kept(let p): ("Kept for manual review: \(p.abbreviatingHome)", "folder.badge.questionmark")
        }
        let admin = item.path.map(adminPaths.contains) ?? false
        return HStack(spacing: 8) {
            Label(text, systemImage: symbol)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if admin {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange).help("Needs administrator access")
            }
        }
    }

    private func loadPreview() {
        guard !loading else { return }
        loading = true
        confirmText = ""
        Task {
            defer { loading = false }
            do {
                // --dry-run exits before the confirmation prompt and changes nothing.
                let result = try await service.collect(["remove", "--dry-run"], timeout: 60)
                let text = result.stdoutString + "\n" + result.stderrString
                let parsed = MoleRemoval.parsePreview(text)
                withAnimation(.smooth) {
                    previewError = result.succeeded ? nil : "Mole's dry run failed (exit code \(result.exitCode))."
                    preview = parsed
                }
                if previewOK { fieldFocused = true }
            } catch {
                withAnimation(.smooth) {
                    previewError = error.localizedDescription
                    preview = nil
                }
            }
        }
    }

    // MARK: Remove

    private func remove() {
        guard armed, let preview else { return }
        confirmText = ""
        outcome = nil
        // `mo remove` treats EOF as "confirm": keep stdin open and answer only its own prompt,
        // and only after checking that its list is exactly what the preview showed.
        final class Box {
            weak var run: CommandRun?
            var answered = false
            var declined = false
            var lines: [String] = []
        }
        let box = Box()
        let run = service.start("Uninstall Mole", ["remove"], admin: needsAdmin, keepInputOpen: true,
                                onLine: { line in
                                    if line.stream != .tty { box.lines.append(line.text) }
                                },
                                onPrompt: { prompt in
                                    guard !box.answered, prompt.contains("Press Enter to confirm") else { return }
                                    box.answered = true
                                    if let list = MoleRemoval.parseConfirmList(box.lines),
                                       MoleRemoval.confirmListMatchesPreview(list, preview) {
                                        box.run?.send("\n")
                                    } else {
                                        // Any key other than Enter makes remove.sh exit 0 without removing anything.
                                        box.declined = true
                                        box.run?.send("q")
                                    }
                                })
        box.run = run
        withAnimation(.smooth) { self.run = run }
        let binaries = preview.binaries()
        run.onCompletion { run in
            let leftovers = binaries.filter { FileManager.default.fileExists(atPath: $0) }
            let result = MoleRemoval.outcome(lines: run.lines.filter { $0.stream != .tty }.map(\.text),
                                             exitCode: run.exitCode, declined: box.declined, leftovers: leftovers)
            withAnimation(.smooth) {
                // A cancelled or unauthenticated run shows the card's own status instead.
                outcome = (run.exitCode == nil || run.authFailed) ? nil : result
            }
            Task {
                await model.relocate()
                if case .removed = result { return }
                if service.isAvailable { loadPreview() }
            }
        }
    }

    private func headline(_ outcome: MoleRemoval.Outcome) -> String {
        switch outcome {
        case .removed: "Mole was uninstalled"
        case .partial: "Mole uninstalled with some errors"
        case .declined: "Nothing was removed"
        case .failed: "Mole didn't uninstall"
        }
    }

    @ViewBuilder private func outcomeBanner(_ outcome: MoleRemoval.Outcome) -> some View {
        switch outcome {
        case .removed:
            InfoBanner(symbol: "checkmark.seal.fill", title: "Mole was removed",
                       message: "Your settings are in the Trash as “mole-config” if you reinstall later.", tint: .moleGood)
        case .partial(let leftovers):
            ErrorBanner(message: leftovers.isEmpty
                        ? "Mole reported errors while uninstalling, even though it exited normally. Some files may still be in place."
                        : "Mole reported errors while uninstalling. These are still installed: \(leftovers.map(\.abbreviatingHome).joined(separator: ", ")). Remove them manually or try again.")
        case .declined:
            ErrorBanner(message: "Mole's list of what it would remove changed since the preview, so the app declined its prompt. Review the new preview and confirm again.")
        case .failed(let message):
            ErrorBanner(message: message)
        }
    }
}
