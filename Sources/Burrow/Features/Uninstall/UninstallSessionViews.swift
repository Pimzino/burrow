import SwiftUI

/// Inline card showing the live state of an uninstall run and its result.
struct UninstallSessionCard: View {
    let session: UninstallSession
    let theme: FeatureTheme
    let dismiss: () -> Void
    let showReview: () -> Void
    let openClean: () -> Void

    var body: some View {
        switch session.phase {
        case .checking, .starting, .scanning:
            FlowProgressCard(theme: theme, title: progressTitle, detail: progressDetail, run: session.run,
                             steps: ["Match apps", "Find leftovers", "Review", "Remove"],
                             currentStep: step, onCancel: { session.cancel() })
        case .review:
            VStack(alignment: .trailing, spacing: 10) {
                FlowProgressCard(theme: theme, title: progressTitle, detail: progressDetail, run: session.run,
                                 steps: ["Match apps", "Find leftovers", "Review", "Remove"],
                                 currentStep: step, onCancel: { session.cancel() })
                Button("Open Review…", systemImage: "list.bullet.rectangle", action: showReview)
                    .buttonStyle(.hero(.uninstall))
                    .help("Show the files Mole found and confirm or cancel")
            }
        case .cancelling:
            FlowProgressCard(theme: theme, title: "Cancelling…",
                             detail: "Waiting for Mole to stop. Nothing has been removed.",
                             run: session.run, steps: ["Match apps", "Find leftovers", "Review", "Remove"],
                             currentStep: step, cancelTitle: nil)
        case .removing:
            FlowProgressCard(theme: theme, title: session.dryRun ? "Simulating removal…" : "Removing \(appsText)…",
                             detail: session.dryRun ? "Dry run: Mole walks through every step without touching a file." : session.permanent ? "Deleting files permanently." : "Moving files to the Trash.",
                             run: session.run, steps: ["Match apps", "Find leftovers", "Review", "Remove"], currentStep: 3,
                             cancelTitle: nil)
        case .finished:
            resultCard
        case .failed(let message):
            GlassCard(tint: .moleWarn) {
                HStack(alignment: .top, spacing: 16) {
                    ResultBurst(style: .warning, theme: theme, size: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing was removed").font(.title3.weight(.semibold))
                        Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Dismiss", action: dismiss).buttonStyle(.soft)
                }
            }
        case .cancelled:
            EmptyView()
        }
    }

    private var appsText: String {
        session.apps.count == 1 ? session.apps[0].name : "\(session.apps.count) apps"
    }

    private var step: Int {
        switch session.phase {
        case .checking, .starting: 0
        case .scanning: 1
        case .review: 2
        case .cancelling: session.run == nil ? 0 : 1
        default: 3
        }
    }

    private var progressTitle: String {
        switch session.phase {
        case .checking: "Checking \(appsText)…"
        case .starting: session.run?.admin == true && session.run?.authenticated == false ? "Waiting for administrator access…" : "Matching \(appsText)…"
        case .scanning: "Finding everything \(appsText) left behind…"
        default: "Waiting for your review…"
        }
    }

    private var progressDetail: String {
        switch session.phase {
        case .checking: "Making sure Mole will match exactly the apps you selected."
        case .starting: "Mole is locating the selected app bundles."
        case .scanning: "Caches, preferences, containers, launch agents and support files. This can take a minute."
        default: "Nothing has been removed yet."
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        let summary = session.parser.summary
        let incomplete = summary?.isIncomplete ?? false
        GlassCard(tint: incomplete ? .moleWarn : .moleGood) {
            HStack(alignment: .top, spacing: 18) {
                ResultBurst(style: session.dryRun ? .info : incomplete ? .warning : .success, theme: theme, size: 50)
                VStack(alignment: .leading, spacing: 8) {
                    Text(headline(summary))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    if let freed = summary?.freed {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(ByteFormat.parse(freed).map { ByteFormat.string($0) } ?? freed)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.accent)
                                .contentTransition(.numericText())
                            Text(session.dryRun ? "would be freed" : "freed").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(summary?.failures ?? [], id: \.self) { failure in
                        Label(failure, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Color.moleBad)
                            .font(.callout)
                    }
                    ForEach(summary?.hints ?? [], id: \.self) { hint in
                        Label(hint, systemImage: "lightbulb")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.parser.executionNotes.filter { $0.hasPrefix("◎ Could not remove") }, id: \.self) { note in
                        Label(String(note.dropFirst(2)), systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(Color.moleWarn)
                    }
                    if session.dryRun {
                        Text("This was a preview. Nothing was removed.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if !incomplete {
                        Button("Look for other leftovers in Clean", systemImage: "sparkles", action: openClean)
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                Spacer()
                Button("Done", action: dismiss)
                    .buttonStyle(.soft)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func headline(_ summary: UninstallSummary?) -> String {
        guard let summary else { return session.dryRun ? "Preview complete" : "Uninstall finished" }
        if session.dryRun { return "Preview complete: \(summary.removedCount.map { "\($0) app\($0 == 1 ? "" : "s")" } ?? appsText) ready to remove" }
        if summary.nothingRemoved { return "No apps were uninstalled" }
        if summary.isIncomplete { return "Uninstall incomplete" }
        let count = summary.removedCount ?? session.apps.count
        return "Removed \(count) app\(count == 1 ? "" : "s")"
    }
}

/// The final review before Mole deletes anything: every file per app, sizes and warnings.
struct UninstallReviewSheet: View {
    let session: UninstallSession
    let theme: FeatureTheme
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let parser = session.parser
        let fileCount = parser.apps.reduce(0) { $0 + $1.removable.count }
        ConfirmSheet(theme: theme, title: title, message: message(fileCount: fileCount), confirmTitle: confirmTitle,
                     destructive: !session.dryRun, onConfirm: onConfirm, onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 12) {
                if session.confirmInfo?.running == true {
                    warning("A selected app is running. Mole will quit it before removing its files.", symbol: "play.circle.fill")
                }
                ForEach(parser.warnings, id: \.self) { warning($0, symbol: "exclamationmark.triangle.fill") }
                ForEach(parser.globalNotes, id: \.self) { note in
                    Label(note, systemImage: "mug.fill").font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(parser.apps) { app in appSection(app) }
                    }
                    .padding(14)
                }
                .frame(minHeight: 180, maxHeight: 360)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
                HStack {
                    Label(session.dryRun ? "Preview only: nothing will be removed" : session.permanent ? "Files will be deleted permanently" : "Files will be moved to the Trash",
                          systemImage: session.dryRun ? "eye" : session.permanent ? "flame.fill" : "trash")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(session.permanent && !session.dryRun ? Color.moleBad : .secondary)
                    Spacer()
                    Text("Total")
                        .foregroundStyle(.secondary)
                    Text(session.confirmInfo?.size.flatMap { ByteFormat.parse($0) }.map { ByteFormat.string($0) } ?? ByteFormat.string(session.totalPreviewBytes))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
            }
        }
    }

    private var title: String {
        let n = session.parser.apps.count
        let what = n == 1 ? "“\(session.parser.apps.first?.name ?? "")”" : "\(n) Apps"
        return session.dryRun ? "Preview Uninstall of \(what)" : "Uninstall \(what)?"
    }

    private func message(fileCount: Int) -> String {
        "Mole found \(fileCount) item\(fileCount == 1 ? "" : "s") to remove. Review them before continuing."
    }

    private var confirmTitle: String {
        session.dryRun ? "Run Preview" : session.permanent ? "Delete Permanently" : "Move to Trash"
    }

    private func warning(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(Color.moleWarn)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.moleWarn.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    private func appSection(_ app: UninstallPreviewApp) -> some View {
        let match = session.apps.first { $0.name == app.name || $0.app.matchName == app.name }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let match { FileIconView(path: match.app.path, size: 28) }
                Text(app.name).font(.headline)
                if app.isBrew { Pill(text: "Homebrew", symbol: "mug.fill", tint: .orange) }
                Spacer()
                Text(app.size).font(.callout.weight(.semibold).monospacedDigit())
            }
            ForEach(app.removable) { file in
                PathSizeRow(path: file.path, size: file.size,
                            symbol: file.path.hasSuffix(".app") ? "app" : file.path.hasSuffix(".plist") ? "doc.text" : "folder",
                            tint: .moleGood)
            }
            ForEach(app.reviewOnly) { file in
                PathSizeRow(path: file.path, size: file.size, symbol: "eye", tint: .moleWarn)
                    .help("System file shown for review only. Mole does not remove it.")
            }
            if !app.reviewOnly.isEmpty {
                Text("Items marked with an eye are system files Mole leaves in place.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(app.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
