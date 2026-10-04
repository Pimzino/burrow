import AppKit
import SwiftUI

/// Success / warning badge shown when a run finishes.
struct ResultBurst: View {
    enum Style { case success, warning, info }
    let style: Style
    let theme: FeatureTheme
    var size: CGFloat = 64

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: .circle)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch style {
        case .success: .moleGood
        case .warning: .moleWarn
        case .info: theme.accent
        }
    }

    private var symbol: String {
        switch style {
        case .success: "checkmark"
        case .warning: "exclamationmark"
        case .info: "eye"
        }
    }
}

/// Inline progress card for a running multi-step Mole task.
struct FlowProgressCard: View {
    let theme: FeatureTheme
    let title: String
    let detail: String
    var run: CommandRun?
    var steps: [String] = []
    var currentStep = 0
    var cancelTitle: String? = "Cancel"
    var onCancel: (() -> Void)? = nil

    var body: some View {
        GlassCard(tint: theme.accent) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: 0.28)
                            .stroke(theme.angular, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(spin ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                        Image(systemName: theme.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.gradient)
                    }
                    .frame(width: 44, height: 44)
                    .onAppear { spin = true }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            .contentTransition(.opacity)
                    }
                    Spacer()
                    if let run {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Duration.seconds(run.duration).formatted(.time(pattern: .minuteSecond)))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let cancelTitle, let onCancel {
                        Button(cancelTitle, role: .cancel, action: onCancel)
                            .buttonStyle(.soft)
                            .keyboardShortcut(.cancelAction)
                    }
                }
                if !steps.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(spacing: 6) {
                                Image(systemName: index < currentStep ? "checkmark.circle.fill" : index == currentStep ? "circle.dotted" : "circle")
                                    .foregroundStyle(index < currentStep ? AnyShapeStyle(Color.moleGood) : index == currentStep ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.tertiary))
                                Text(step)
                                    .font(.caption.weight(index == currentStep ? .semibold : .regular))
                                    .foregroundStyle(index <= currentStep ? .primary : .secondary)
                            }
                            if index < steps.count - 1 {
                                Capsule().fill(index < currentStep ? Color.moleGood.opacity(0.6) : Color.secondary.opacity(0.25))
                                    .frame(height: 2).frame(maxWidth: 40)
                            }
                        }
                    }
                    .animation(.smooth, value: currentStep)
                }
            }
        }
    }

    @State private var spin = false
}

/// A labelled row inside a confirmation sheet listing a path and its size.
struct PathSizeRow: View {
    let path: String
    let size: String?
    var symbol: String = "doc"
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(path)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: 8)
            if let size {
                Text(size).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { Finder.reveal(MoleHomeDir.expand(path)) }
            Button("Copy Path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MoleHomeDir.expand(path), forType: .string)
            }
        }
    }
}
