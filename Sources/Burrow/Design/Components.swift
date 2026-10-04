import AppKit
import SwiftUI

// MARK: - Backgrounds

/// Soft, slowly drifting colour fields behind a page so Liquid Glass surfaces have something to refract.
struct AmbientBackground: View {
    let theme: FeatureTheme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate / 14
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Circle()
                        .fill(theme.colors[0].opacity(scheme == .dark ? 0.30 : 0.20))
                        .frame(width: max(w, h) * 0.75)
                        .offset(x: w * (0.30 + 0.06 * sin(t)), y: -h * (0.30 + 0.05 * cos(t * 1.3)))
                    Circle()
                        .fill(theme.colors[1].opacity(scheme == .dark ? 0.22 : 0.16))
                        .frame(width: max(w, h) * 0.6)
                        .offset(x: -w * (0.32 + 0.05 * cos(t * 0.8)), y: h * (0.28 + 0.06 * sin(t * 1.1)))
                }
                .frame(width: w, height: h)
                .blur(radius: 90)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Cards

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    var radius: CGFloat = Metrics.cardRadius
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { .regular.tint($0.opacity(0.12)) } ?? .regular, in: .rect(cornerRadius: radius))
    }
}

struct SectionTitle: View {
    let title: String
    var symbol: String? = nil
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            Text(title).font(.headline)
            Spacer()
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

// MARK: - Page header

struct FeatureIcon: View {
    let theme: FeatureTheme
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(theme.gradient)
            .overlay {
                Image(systemName: theme.symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PageHeader<Trailing: View>: View {
    let theme: FeatureTheme
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            FeatureIcon(theme: theme, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? theme.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(subtitle ?? theme.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // Header actions share one size and shape: `.soft` for secondary, `.hero` for the primary.
            trailing
                .controlSize(.large)
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(theme: FeatureTheme, title: String? = nil, subtitle: String? = nil) {
        self.init(theme: theme, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Standard scrolling page with ambient background and header.
struct FeaturePage<Header: View, Content: View>: View {
    let theme: FeatureTheme
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                header
                content
            }
            .padding(Metrics.pagePadding)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background { AmbientBackground(theme: theme) }
    }
}

// MARK: - Gauges and tiles

struct RingGauge<Label: View>: View {
    /// 0...1
    let value: Double
    var colors: [Color]
    var lineWidth: CGFloat = 14
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(AngularGradient(colors: colors + [colors.last ?? .accentColor], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.001, min(1, value)))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label
        }
        .animation(.smooth(duration: 0.8), value: value)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var symbol: String
    var tint: Color = .accentColor
    /// Optional 0–1 fill shown as a thin bar.
    var fraction: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.15), in: .circle)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let fraction {
                CapsuleBar(fraction: fraction, tint: tint)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.tileRadius))
        .accessibilityElement(children: .combine)
    }
}

struct CapsuleBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * max(0, min(1, fraction))))
            }
        }
        .frame(height: height)
        .animation(.smooth, value: fraction)
    }
}

/// A pill-shaped badge.
struct Pill: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: .capsule)
    }
}

// MARK: - Empty / loading / error states

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(tint)
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// Working state: the feature icon, what is happening, and a progress spinner.
struct ScanningView: View {
    let theme: FeatureTheme
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 14) {
            FeatureIcon(theme: theme, size: 56)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(title).font(.title3.weight(.semibold))
            }
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.moleWarn).font(.title3)
            Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Try Again", action: retry).buttonStyle(.soft)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(Color.moleWarn.opacity(0.12)), in: .rect(cornerRadius: 16))
    }
}

struct InfoBanner: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .accentColor
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.soft)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(tint.opacity(0.10)), in: .rect(cornerRadius: 16))
    }
}

/// A quiet one-line explanation under a list or card. Use instead of a banner when nothing needs attention.
struct Footnote: View {
    let symbol: String
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
    }
}

// MARK: - Buttons

/// Shared metrics so primary and secondary buttons are the same height and shape at every control size.
private struct CapsuleButtonMetrics {
    let font: Font
    let horizontal: CGFloat
    let vertical: CGFloat

    init(_ size: ControlSize) {
        switch size {
        case .mini, .small: (font, horizontal, vertical) = (.caption.weight(.semibold), 11, 4)
        case .large, .extraLarge: (font, horizontal, vertical) = (.headline, 20, 9)
        default: (font, horizontal, vertical) = (.callout.weight(.semibold), 15, 7)
        }
    }
}

/// The solid, accent-coloured capsule used for a screen's primary action.
struct HeroButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let m = CapsuleButtonMetrics(controlSize)
        configuration.label
            .font(m.font)
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, m.horizontal)
            .padding(.vertical, m.vertical)
            .background {
                Capsule().fill(tint)
                    .overlay(Capsule().fill(.black.opacity(configuration.isPressed ? 0.15 : 0)))
            }
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The quiet capsule used for every secondary action. Same shape and metrics as `HeroButtonStyle`.
struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let m = CapsuleButtonMetrics(controlSize)
        configuration.label
            .font(m.font)
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(Color.moleBad) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, m.horizontal)
            .padding(.vertical, m.vertical)
            .background(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.10), in: .capsule)
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == HeroButtonStyle {
    static func hero(_ theme: FeatureTheme) -> HeroButtonStyle { HeroButtonStyle(tint: theme.accent) }
    static func hero(tint: Color) -> HeroButtonStyle { HeroButtonStyle(tint: tint) }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
}

// MARK: - Helpers

extension View {
    /// Reveals a path in Finder.
    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

enum Finder {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static func icon(for path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: (path as NSString).expandingTildeInPath)
    }
}

extension String {
    /// Replaces the home directory with `~`.
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }

    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
