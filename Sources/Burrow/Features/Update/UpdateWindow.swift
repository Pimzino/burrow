import AppKit
import SwiftUI

/// The "Software Update" window: checking, the offer with release notes, download progress, and errors.
struct UpdateWindow: View {
    static let id = "burrow-update"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    private var updater: AppUpdater { model.updater }
    private let theme = FeatureTheme.dashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)   // clear of the traffic lights (the title bar is hidden)
        .padding(.bottom, 22)
        .frame(width: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            LinearGradient(colors: theme.colors.map { $0.opacity(0.10) } + [.clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .animation(.smooth(duration: 0.25), value: updater.phase)
        .onDisappear { updater.dismiss() }
        .task {
            // Opened from the menu with nothing to show yet: check right away.
            if updater.phase == .idle { await updater.check(userInitiated: true) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.system(size: 20, weight: .bold, design: .rounded))
                Text(subheadline).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var current: String { updater.currentVersion?.description ?? "unknown" }

    private var headline: String {
        switch updater.phase {
        case .idle, .checking: "Checking for Updates…"
        case .upToDate: "Burrow is up to date"
        case .available(let r): r.isPrerelease ? "A Burrow pre-release is available" : "A new version of Burrow is available"
        case .downloading(let r, _): "Downloading Burrow \(r.version)…"
        case .verifying(let r): "Verifying Burrow \(r.version)…"
        case .installing(let r): "Installing Burrow \(r.version)…"
        case .failed(_, let r): r == nil ? "Couldn't check for updates" : "The update didn't install"
        }
    }

    private var subheadline: String {
        switch updater.phase {
        case .idle, .checking: "Asking GitHub for the latest release."
        case .upToDate: "You have Burrow \(current), the newest version\(updater.includePrereleases ? " (including pre-releases)" : "")."
        case .available(let r):
            "Burrow \(r.version) is available. You have \(current)."
                + (r.publishedAt.map { " Released \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "")
        case .downloading: "Burrow checks the download's signature before installing it."
        case .verifying: "Checking the signature and the new app."
        case .installing: "Burrow will reopen in a moment."
        case .failed(_, nil): "Burrow couldn't reach the list of releases."
        case .failed(_, .some): "Your current version is unchanged."
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .upToDate:
            footer { Spacer(); Button("OK") { close() }.keyboardShortcut(.defaultAction) }
        case .available(let release):
            available(release)
        case .downloading(_, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fraction).tint(theme.accent)
                Text(fraction > 0 ? "\(Int(fraction * 100))%" : "Starting…")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            footer { Spacer(); Button("Cancel", role: .cancel) { updater.cancelInstall() }.keyboardShortcut(.cancelAction) }
        case .verifying, .installing:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .failed(let message, let release):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.moleWarn)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            footer {
                Link("Open Releases Page", destination: release?.page ?? UpdateConfig.releasesPage)
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    if let release { updater.install(release) } else { Task { await updater.check(userInitiated: true) } }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func available(_ release: AppRelease) -> some View {
        let blocker = updater.blocker(for: release)
        // Permanent reasons (no signing key, translocated, …) offer the download; running tasks only wait.
        let permanent = UpdateInstaller.blocker(for: release) != nil
        ReleaseNotesView(release: release)
            .frame(height: 230)
        if let blocker {
            Label(blocker, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        footer {
            Button("Skip This Version") { updater.skip(release); close() }
            Spacer()
            Button("Remind Me Later") { close() }.keyboardShortcut(.cancelAction)
            if permanent {
                Link(destination: release.page) { Text("Download from GitHub") }
                    .buttonStyle(.hero(theme))
            } else {
                Button("Install and Relaunch") { updater.install(release) }
                    .buttonStyle(.hero(theme))
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocker != nil)
            }
        }
    }

    private func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
    }

    private func close() { dismissWindow(id: Self.id) }
}

/// GitHub release notes, rendered from the small Markdown subset GitHub's generated notes use:
/// headings, bullet lists and paragraphs with inline formatting and links.
struct ReleaseNotesView: View {
    let release: AppRelease

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(release.title).font(.headline)
                if blocks.isEmpty {
                    Text("No release notes.").foregroundStyle(.secondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let text):
                        Text(inline(text)).font(.subheadline.weight(.semibold)).padding(.top, 4)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(inline(text))
                        }
                    case .paragraph(let text):
                        Text(inline(text))
                    }
                }
                Link("View on GitHub", destination: release.page).font(.callout).padding(.top, 4)
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .background(.background.opacity(0.5), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    enum Block { case heading(String), bullet(String), paragraph(String) }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in release.notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("<!--") {
                flush()
            } else if let match = line.firstMatch(of: /^#{1,6}\s+(.*)$/) {
                flush(); result.append(.heading(String(match.1)))
            } else if let match = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
                flush(); result.append(.bullet(String(match.1)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
