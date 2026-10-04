import AppKit
import SwiftUI

/// Visual vocabulary shared by the Clean screens.
enum CleanStyle {
    static let palette: [Color] = [
        Color(red: 0.06, green: 0.74, blue: 0.62), Color(red: 0.26, green: 0.62, blue: 0.98),
        Color(red: 0.55, green: 0.42, blue: 0.98), Color(red: 0.98, green: 0.55, blue: 0.22),
        Color(red: 0.93, green: 0.36, blue: 0.56), Color(red: 0.40, green: 0.82, blue: 0.36),
        Color(red: 0.98, green: 0.78, blue: 0.20), Color(red: 0.20, green: 0.80, blue: 0.86),
        Color(red: 0.62, green: 0.52, blue: 0.40), Color(red: 0.52, green: 0.58, blue: 0.70),
    ]

    static let knownSections = ["System", "User essentials", "App caches", "Browsers", "Cloud & Office", "Developer tools",
                                "Apps & utilities", "Virtualization", "Application Support", "App leftovers",
                                "Apple Silicon updates", "Device backups & firmware", "Time Machine", "Large files",
                                "Project artifacts", "External volume"]

    static func color(for section: String) -> Color {
        let index = knownSections.firstIndex(of: section) ?? abs(section.hashValue)
        return palette[index % palette.count]
    }

    static func symbol(for section: String) -> String {
        switch section {
        case "System": "gearshape.2.fill"
        case "User essentials": "person.crop.circle.fill"
        case "App caches": "square.stack.3d.up.fill"
        case "Browsers": "safari.fill"
        case "Cloud & Office": "icloud.fill"
        case "Developer tools": "hammer.fill"
        case "Apps & utilities": "wrench.and.screwdriver.fill"
        case "Virtualization": "server.rack"
        case "Application Support": "folder.fill.badge.gearshape"
        case "App leftovers": "app.dashed"
        case "Apple Silicon updates": "cpu.fill"
        case "Device backups & firmware": "iphone.gen3"
        case "Time Machine": "clock.arrow.circlepath"
        case "Large files": "doc.viewfinder.fill"
        case "Project artifacts": "shippingbox.fill"
        case "External volume": "externaldrive.fill"
        default: "folder.fill"
        }
    }

    static func rowSymbol(_ kind: CleanReport.Row.Kind) -> (String, Color) {
        switch kind {
        case .wouldClean: ("arrow.right.circle.fill", FeatureTheme.clean.accent)
        case .cleaned: ("checkmark.circle.fill", .moleGood)
        case .warning: ("exclamationmark.circle.fill", .moleWarn)
        case .review: ("eye.circle.fill", .blue)
        case .alert: ("exclamationmark.triangle.fill", .moleWarn)
        }
    }

    /// "7.51GB" → "7.51 GB" using the app's formatter when the size parses.
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return bytes == 0 ? "0 MB" : ByteFormat.string(bytes)
    }

    /// Mole's "2026-10-03 23:22:22" → "yesterday at 23:22"; leaves unparseable text as is.
    static func friendlyDate(_ text: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = parser.date(from: text) else { return text }
        let out = DateFormatter()
        out.doesRelativeDateFormatting = true
        out.dateStyle = .medium
        out.timeStyle = .short
        // "Today at 00:41" reads mid-sentence, so the relative word is lowercased.
        let text = out.string(from: date)
        return Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date)
            ? text.prefix(1).lowercased() + text.dropFirst() : text
    }

    /// Mole's "92.22GB" → "92.22 GB"; leaves unparseable text as is.
    static func human(_ text: String) -> String {
        guard let bytes = ByteFormat.parse(text) else { return text }
        return (text.hasPrefix("At least") ? "At least " : "") + ByteFormat.string(bytes)
    }
}

/// Copies text to the general pasteboard.
enum TidyPasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A subtle rounded highlight under a row while the pointer is over it.
struct TidyHover: ViewModifier {
    var radius: CGFloat = 10
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

extension View {
    func tidyHover(radius: CGFloat = 10) -> some View { modifier(TidyHover(radius: radius)) }

    /// Standard file context menu: Reveal in Finder, Copy Path.
    func tidyFileMenu(_ path: String, @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        let expanded = path.expandingTilde
        return contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(expanded) }
            Button("Copy Path", systemImage: "doc.on.doc") { TidyPasteboard.copy(expanded) }
            extra()
        }
    }
}

/// Small circular glyph used at the start of cards and rows.
struct TidyGlyph: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: .circle)
            .accessibilityHidden(true)
    }
}

/// An option row with an icon, title, explanation and trailing control.
struct TidyOptionRow<Control: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TidyGlyph(symbol: symbol, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Automation aid: when `-MoleE2EScrollTo <id>` is passed, scrolls the page to that anchor once `ready`
/// becomes true, so end-to-end screenshots can capture content below the fold.
struct TidyAutomationScroll: ViewModifier {
    let ready: Bool
    private let anchor = UserDefaults.standard.string(forKey: "MoleE2EScrollTo")

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: ready) { _, isReady in scroll(proxy, isReady) }
                .onAppear { scroll(proxy, ready) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, _ isReady: Bool) {
        guard isReady, let anchor else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            withAnimation { proxy.scrollTo(anchor, anchor: .top) }
        }
    }
}

extension View {
    func tidyAutomationScroll(ready: Bool) -> some View { modifier(TidyAutomationScroll(ready: ready)) }
}
