import SwiftUI

struct SettingsUpdatesPane: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @State private var checking = false
    @State private var lastChecked: Date?
    @State private var confirming = false
    @State private var force = false
    @State private var nightly = false
    @State private var run: CommandRun?

    private var isHomebrew: Bool { service.installation?.isHomebrew ?? false }
    /// A manual install in a folder the user can't write to: Mole's `request_sudo_access` needs a
    /// terminal, so the update only works as an administrator run (the helper provides the pty).
    private var needsAdmin: Bool {
        guard let installation = service.installation, !installation.isHomebrew else { return false }
        return !UpdateInstallLocation.adminFolders(launcher: installation.launcher).isEmpty
    }
    private var installed: String { service.installation?.version ?? "—" }

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(tab: .updates, subtitle: "Keep Burrow and the Mole CLI current. Burrow never changes Mole's files directly.")
            }
            BurrowUpdateSection()
            Section("Mole CLI") {
                HStack(spacing: 16) {
                    versionColumn("Installed", installed, tint: .secondary)
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(model.availableUpdate == nil ? 0 : 1)
                    if let update = model.availableUpdate {
                        versionColumn("Available", update, tint: SettingsTab.updates.colors[0])
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(checking ? "Checking…" : "Up to date", systemImage: checking ? "arrow.triangle.2.circlepath" : "checkmark.seal.fill")
                                .font(.headline)
                                .foregroundStyle(checking ? Color.secondary : Color.moleGood)
                                .symbolEffect(.rotate, isActive: checking)
                            if let lastChecked {
                                Text("Checked \(lastChecked.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                LabeledContent("Install type") {
                    SettingsStatusPill(text: isHomebrew ? "Homebrew" : "Manual install", on: true, onColor: isHomebrew ? .orange : .blue)
                }
                HStack {
                    Button("Check Now", systemImage: "arrow.clockwise", action: check)
                        .buttonStyle(.glass)
                        .disabled(checking)
                        .keyboardShortcut("r", modifiers: .command)
                    Spacer()
                    Button("Update Now…", systemImage: "arrow.down.circle.fill") { confirming = true }
                        .buttonStyle(.glassProminent)
                        .disabled(run?.state.isRunning == true || !service.isAvailable || (model.availableUpdate == nil && !force && !nightly))
                }
            }
            if !isHomebrew {
                Section("Options") {
                    Toggle(isOn: $force) {
                        Text("Reinstall even if up to date")
                        Text("Passes --force.")
                    }
                    Toggle(isOn: $nightly) {
                        Text("Nightly build")
                        Text("Passes --nightly: the latest commit on main instead of the last release.")
                    }
                }
            } else {
                Section {
                    Label("Mole was installed with Homebrew, so updating runs “brew update” and “brew upgrade mole”.", systemImage: "mug.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let run {
                Section("Update") {
                    RunStatusCard(run: run, theme: .dashboard, showConsoleInitially: true)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $confirming) {
            ConfirmSheet(theme: .settings, title: "Update Mole?",
                         message: model.availableUpdate.map { "From \(installed) to \($0)." } ?? "Reinstall the latest Mole.",
                         confirmTitle: needsAdmin ? "Update (Admin)" : "Update", destructive: false,
                         onConfirm: update, onCancel: { confirming = false }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("mo " + updateArguments.joined(separator: " "))
                        .font(.callout.monospaced())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.2), in: .rect(cornerRadius: 10))
                    Label(isHomebrew ? "Homebrew downloads and installs the new version. This can take a minute."
                                     : "Mole downloads its installer from GitHub and replaces itself.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if needsAdmin, let launcher = service.installation?.launcher {
                        Label("\(UpdateInstallLocation.adminFolders(launcher: launcher).map(\.abbreviatingHome).joined(separator: ", ")) can only be changed by an administrator, so you'll be asked for your password.",
                              systemImage: "lock.shield")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var updateArguments: [String] {
        var args = ["update"]
        if !isHomebrew {
            if force { args.append("--force") }
            if nightly { args.append("--nightly") }
        }
        return args
    }

    private func versionColumn(_ title: String, _ version: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(version)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint == .secondary ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                .contentTransition(.numericText())
        }
    }

    private func check() {
        checking = true
        Task {
            await model.checkForUpdate()
            withAnimation(.smooth) {
                checking = false
                lastChecked = Date()
            }
        }
    }

    private func update() {
        confirming = false
        let run = service.start("Update Mole", updateArguments, admin: needsAdmin)
        withAnimation(.smooth) { self.run = run }
        run.onCompletion { run in
            guard run.succeeded else { return }
            Task {
                await model.relocate()
                await model.checkForUpdate()
                lastChecked = Date()
            }
        }
    }
}

/// Burrow's own updates, from GitHub Releases (the Software Update window does the work).
private struct BurrowUpdateSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var updater = model.updater
        Section("Burrow") {
            LabeledContent("Installed") {
                Text(updater.currentVersion?.description ?? "Development build").monospacedDigit()
            }
            LabeledContent("Status") {
                if let release = updater.newer {
                    SettingsStatusPill(text: "\(release.version) available", on: true, onColor: SettingsTab.updates.colors[0])
                } else if let checked = updater.lastChecked {
                    Text("Up to date · checked \(checked.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                } else {
                    Text("Not checked yet").foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $updater.automaticChecks) {
                Text("Check for updates automatically")
                Text("Once a day, from Burrow's GitHub Releases. Nothing about your Mac is sent.")
            }
            Toggle(isOn: $updater.includePrereleases) {
                Text("Include pre-releases")
                Text("Offer beta builds too. They may be less stable.")
            }
            HStack {
                Link("Release Notes", destination: UpdateConfig.releasesPage)
                Spacer()
                Button(updater.newer == nil ? "Check for Updates…" : "View Update…", systemImage: "sparkles") {
                    openWindow(id: UpdateWindow.id)
                    if updater.newer == nil { Task { await updater.check(userInitiated: true) } }
                }
                .buttonStyle(.glass)
                .disabled(updater.phase.isBusy)
            }
        }
    }
}

/// Mirrors `update_install_requires_sudo` (lib/manage/update.sh at V1.56.0): the install folder is the
/// folder of the invoked launcher (`MOLE_ENTRY_SCRIPT`, not symlink-resolved); when it exists only its
/// own writability counts, otherwise its parent's. The symlink-resolved folder is checked too, so a
/// launcher that links into a root-owned tree still gets administrator access.
enum UpdateInstallLocation {
    static func adminFolders(launcher: String,
                             isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) },
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        let invokedDir = (launcher as NSString).deletingLastPathComponent
        let resolvedDir = (URL(fileURLWithPath: launcher).resolvingSymlinksInPath().path as NSString).deletingLastPathComponent
        var seen = Set<String>()
        return [invokedDir, resolvedDir].filter { seen.insert($0).inserted }.filter { dir in
            exists(dir) ? !isWritable(dir) : !isWritable((dir as NSString).deletingLastPathComponent)
        }
    }
}
