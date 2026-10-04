import SwiftUI

/// Installs the Mole CLI with Homebrew. Shared by first-run setup and the "Mole is missing" page.
@MainActor
@Observable
final class MoleInstaller {
    private(set) var running = false
    private(set) var error: String?

    var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func install(model: AppModel) {
        guard let brewPath, !running else { return }
        running = true
        error = nil
        Task {
            do {
                let process = try Subprocess(executable: brewPath, arguments: ["install", "mole"],
                                             environment: MoleLocator.environment(), stdinOpen: false)
                var last = ""
                for await event in process.events {
                    if case .line(let line) = event, !line.text.trimmingCharacters(in: .whitespaces).isEmpty { last = line.text }
                }
                await model.relocate()
                if !model.service.isAvailable { error = "Homebrew couldn’t install Mole. \(last)" }
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}

/// The install controls: Homebrew install, re-check, and what to do when Homebrew is missing.
struct MoleInstallCard: View {
    @Environment(AppModel.self) private var model
    @State private var installer = MoleInstaller()
    @State private var checking = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Install with Homebrew", systemImage: "shippingbox").font(.headline)
                Text("Burrow installs Mole for you with Homebrew. It takes about a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(installer.running ? "Installing…" : "Install Now") { installer.install(model: model) }
                        .buttonStyle(.hero(.setup))
                        .disabled(installer.running || installer.brewPath == nil)
                    Button("Check Again") {
                        checking = true
                        Task {
                            await model.relocate()
                            checking = false
                        }
                    }
                    .buttonStyle(.soft)
                    .disabled(installer.running || checking)
                    Spacer()
                    Link("Mole on GitHub", destination: URL(string: "https://github.com/tw93/mole")!)
                }
                if installer.brewPath == nil {
                    Text("Homebrew was not found. Install it from brew.sh, or use Mole's install script, then choose Check Again.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if installer.running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Installing Mole…").font(.callout).foregroundStyle(.secondary)
                    }
                } else if let error = installer.error {
                    ErrorBanner(message: error)
                }
            }
        }
    }
}

/// Shown in place of a feature when the Mole CLI cannot be found after setup (for example, it was uninstalled).
struct MoleMissingView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                SetupBadge(symbol: "shippingbox.fill", size: 88)
                    .padding(.top, 50)
                VStack(spacing: 8) {
                    Text("Mole isn’t installed").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Burrow does all of its work through the open-source Mole CLI. Install Mole to carry on.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                MoleInstallCard()
                    .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity)
            .padding(Metrics.pagePadding)
        }
        .background { AmbientBackground(theme: .setup) }
    }
}
