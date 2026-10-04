import AppKit
import SwiftUI

struct SettingsAboutPane: View {
    @Environment(MoleService.self) private var service

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String {
            let build = info?["CFBundleVersion"] as? String
            return build.map { "\(short) (\($0))" } ?? short
        }
        return "Development build"
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 10)
            Group {
                if Bundle.main.bundleIdentifier != nil {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 112, height: 112)
                        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                } else {
                    // Running unbundled (swift run): no app icon to show, so use the app's mark.
                    FeatureIcon(theme: .clean, size: 96).padding(8)
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Burrow").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("A beautiful home for Mole").font(.title3).foregroundStyle(.secondary)
                Text("Burrow \(appVersion) · Mole \(service.installation?.version ?? "not installed")")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 12) {
                credit("terminal.fill", "Mole CLI by tw93",
                       "Every clean, scan and optimization is performed by Mole itself. Burrow only drives it.")
                credit("building.columns.fill", "GPL-3.0 licensed",
                       "Burrow and Mole are free, open-source software under the GNU General Public License v3.")
                credit("sparkles", "Built with SwiftUI",
                       "Liquid Glass, Swift Charts and SF Symbols. No third-party packages.")
            }
            .padding(18)
            .frame(maxWidth: 440)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            HStack(spacing: 10) {
                Link(destination: URL(string: "https://github.com/tw93/mole")!) {
                    Label("Mole on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.soft)
                Link(destination: URL(string: "https://github.com/tw93/mole/releases")!) {
                    Label("Mole Releases", systemImage: "newspaper")
                }
                .buttonStyle(.soft)
                Link(destination: URL(string: "https://github.com/tw93/mole/blob/main/LICENSE")!) {
                    Label("License", systemImage: "doc.plaintext")
                }
                .buttonStyle(.soft)
            }
            Spacer(minLength: 10)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: SettingsTab.about.colors.map { $0.opacity(0.12) } + [.clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    private func credit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: SettingsTab.about.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
