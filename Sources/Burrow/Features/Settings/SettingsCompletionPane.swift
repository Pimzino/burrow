import SwiftUI

/// Parses `mo completion --dry-run` output (bin/completion.sh at V1.56.0).
///
/// bash/zsh: "Will add to <rc>:" + the line, or "[DRY RUN] Would normalize completion entry in <rc>"
/// when already installed. fish: "[DRY RUN] Would write Fish completions to:" followed by the indented
/// `mole.fish` and `mo.fish` paths; the real run only prompts when `mole.fish` doesn't exist yet.
/// Errors start with "☻".
struct CompletionPreview: Equatable {
    var rcFile: String?
    var snippet: String?
    /// Files Mole writes (fish).
    var targets: [String] = []
    var alreadyInstalled = false
    var message: String?
    /// "Dry run complete" or the normalize line: Mole got to the end of its checks.
    var completed = false

    var isFish: Bool { !targets.isEmpty }

    static func parse(_ text: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> CompletionPreview {
        var result = CompletionPreview()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { ANSI.strip(String($0)) }
        var readingTargets = false
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if readingTargets {
                if t.hasPrefix("/") || t.hasPrefix("~") {
                    result.targets.append(t)
                    continue
                }
                readingTargets = false
            }
            if t.contains("Would write Fish completions to:") {
                readingTargets = true
            } else if t.hasPrefix("Will add to "), t.hasSuffix(":") {
                result.rcFile = String(t.dropFirst("Will add to ".count).dropLast())
                if i + 1 < lines.count { result.snippet = lines[i + 1].trimmingCharacters(in: .whitespaces) }
            } else if let r = t.range(of: "Would normalize completion entry in ") {
                result.rcFile = String(t[r.upperBound...])
                result.alreadyInstalled = true
                result.completed = true
            } else if t.contains("Dry run complete") {
                result.completed = true
            } else if t.hasPrefix("☻") {
                result.message = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        // Mole overwrites the fish files silently once mole.fish exists: that is "already installed".
        if let first = result.targets.first, fileExists((first as NSString).expandingTildeInPath) {
            result.alreadyInstalled = true
        }
        return result
    }
}

struct SettingsCompletionPane: View {
    @Environment(MoleService.self) private var service
    @State private var preview: CompletionPreview?
    @State private var previewError: String?
    @State private var shell = SettingsCompletionPane.defaultShell
    @State private var script = ""
    @State private var loadingScript = false
    @State private var confirming = false
    @State private var run: CommandRun?

    /// Only a dry run that finished cleanly and said what it would change can arm Install.
    private var canInstall: Bool {
        guard let preview, preview.message == nil, preview.completed else { return false }
        return preview.isFish || preview.rcFile != nil
    }

    static var defaultShell: String {
        let name = ((ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") as NSString).lastPathComponent
        return ["zsh", "bash", "fish"].contains(name) ? name : "zsh"
    }

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(tab: .completion, subtitle: "Tab-complete mo commands and options in your shell.")
            }
            Section("Install for \(Self.defaultShell)") {
                if let preview {
                    if let message = preview.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.moleWarn)
                    } else if preview.isFish {
                        VStack(alignment: .leading, spacing: 8) {
                            if preview.alreadyInstalled {
                                Label("Fish completion is already installed. Installing again rewrites these files:", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Color.moleGood)
                            } else {
                                Text("Mole will write two completion files for fish:").font(.callout)
                            }
                            SettingsCodeBlock(text: preview.targets.map(\.abbreviatingHome).joined(separator: "\n"), maxHeight: 60)
                        }
                    } else if preview.alreadyInstalled {
                        Label("Completion is already set up in \(preview.rcFile?.abbreviatingHome ?? "your shell config"). Installing again refreshes the entry.",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.moleGood)
                    } else if let rc = preview.rcFile {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mole will add one line to \(Text(rc.abbreviatingHome).font(.callout.monospaced().weight(.semibold))):")
                                .font(.callout)
                            if let snippet = preview.snippet { SettingsCodeBlock(text: snippet, maxHeight: 60) }
                        }
                    } else {
                        Label("Mole's dry run didn't say what it would change, so installing is disabled.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.moleWarn)
                    }
                } else if let previewError {
                    Label(previewError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.moleWarn)
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Checking your shell setup…").foregroundStyle(.secondary) }
                }
                HStack {
                    Spacer()
                    Button("Install Completion…", systemImage: "square.and.arrow.down") { confirming = true }
                        .buttonStyle(.hero(tint: .accentColor))
                        .disabled(!canInstall || run?.state.isRunning == true)
                }
                if let run {
                    RunStatusCard(run: run, theme: .settings)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section("Completion script") {
                Picker("Shell", selection: $shell) {
                    Text("zsh").tag("zsh")
                    Text("bash").tag("bash")
                    Text("fish").tag("fish")
                }
                .pickerStyle(.segmented)
                ZStack {
                    SettingsCodeBlock(text: script, maxHeight: 180)
                    if loadingScript { ProgressView().controlSize(.small) }
                }
                Text("To install it yourself, save this where your shell loads completions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await loadPreview() }
        .task(id: shell) { await loadScript() }
        .sheet(isPresented: $confirming) {
            ConfirmSheet(theme: .settings, title: "Install Shell Completion?",
                         message: confirmMessage,
                         confirmTitle: "Install", destructive: false,
                         onConfirm: install, onCancel: { confirming = false }) {
                if let preview, preview.isFish {
                    SettingsCodeBlock(text: preview.targets.map(\.abbreviatingHome).joined(separator: "\n"), maxHeight: 60)
                } else if let snippet = preview?.snippet {
                    SettingsCodeBlock(text: snippet, maxHeight: 60)
                }
            }
        }
    }

    private var confirmMessage: String {
        guard let preview else { return "Mole will update your shell config." }
        if preview.isFish {
            return preview.alreadyInstalled ? "Mole will rewrite its fish completion files." : "Mole will write these fish completion files."
        }
        return preview.rcFile.map { "Mole will update \($0.abbreviatingHome)." } ?? "Mole will update your shell config."
    }

    private func loadPreview() async {
        do {
            // --dry-run never prompts and never writes.
            let result = try await service.collect(["completion", "--dry-run"], timeout: 30)
            var parsed = CompletionPreview.parse(result.stdoutString + "\n" + result.stderrString)
            if !result.succeeded, parsed.message == nil {
                parsed.message = "Mole's dry run failed (exit code \(result.exitCode))."
            }
            previewError = nil
            preview = parsed
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
    }

    private func loadScript() async {
        loadingScript = true
        defer { loadingScript = false }
        // An explicit shell argument only prints the script.
        if let result = try? await service.collect(["completion", shell], timeout: 30) {
            script = result.succeeded ? result.stdoutString : result.stderrString
        }
    }

    private func install() {
        confirming = false
        // Bare `mo completion` treats EOF as "confirm", so keep stdin open and answer only its own prompt.
        final class Box { weak var run: CommandRun?; var answered = false }
        let box = Box()
        let run = service.start("Install shell completion", ["completion"], keepInputOpen: true, onPrompt: { prompt in
            guard !box.answered, prompt.contains("Enter confirm") else { return }
            box.answered = true
            box.run?.send("\n")
        })
        box.run = run
        run.onCompletion { _ in Task { await loadPreview() } }
        withAnimation(.smooth) { self.run = run }
    }
}
