import AppKit
import SwiftUI

/// First-run setup. It takes over the main window until the user finishes it; see `SetupModel`.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var setup: SetupModel { model.setup }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView {
                    stepContent
                        .id(setup.step)
                        .transition(stepTransition)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            footer
        }
        .background { AmbientBackground(theme: .setup) }
        .animation(.smooth(duration: 0.3), value: setup.step)
        .task {
            // Permissions change in System Settings while Burrow is in the background, so keep looking.
            while !Task.isCancelled {
                await model.refreshPermissionsFromChild()
                await setup.refreshFinderAutomation()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: setup.step) { await automate() }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch setup.step {
        case .welcome: SetupWelcomeStep()
        case .mole: SetupMoleStep()
        case .access: SetupAccessStep()
        case .ready: SetupReadyStep()
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let forward = setup.movedForward
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 24 : -24)),
                           removal: .opacity.combined(with: .offset(x: forward ? -24 : 24)))
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            SetupProgressDots(count: setup.steps.count, index: setup.index)
            HStack(spacing: 10) {
                if setup.isFirst {
                    Button("Skip Setup") { model.finishSetup() }
                        .buttonStyle(.soft)
                } else {
                    Button("Back") { setup.back() }
                        .buttonStyle(.soft)
                }
                Spacer()
                if setup.step == .mole, !service.isAvailable {
                    Button("Skip for Now") { setup.advance() }
                        .buttonStyle(.soft)
                }
                Button(primaryTitle) { primaryAction() }
                    .buttonStyle(.hero(.setup))
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.step == .mole && !service.isAvailable)
            }
        }
        .controlSize(.large)
        .frame(maxWidth: 560)
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 14)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
    }

    private var primaryTitle: String {
        switch setup.step {
        case .welcome: "Get Started"
        case .mole, .access: "Continue"
        case .ready: "Open Burrow"
        }
    }

    private func primaryAction() {
        if setup.step == .ready {
            model.finishSetup()
        } else {
            setup.advance()
        }
    }

    // MARK: Automation

    /// E2E (scripts/setup-e2e.sh): records each step as it appears; with `-BurrowSetupWalk YES` it also
    /// steps through to the end the way the Continue button does. Nothing is requested or changed.
    private func automate() async {
        guard model.automation.reportDir != nil else { return }
        let step = setup.step
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        model.automation.record("setup-\(step.rawValue)", passed: true,
                                detail: "Step \(setup.index + 1) of \(setup.steps.count)",
                                metrics: ["steps": setup.steps.map(\.rawValue).joined(separator: ","),
                                          "mole": service.installation?.version ?? "missing",
                                          "fullDiskAccess": model.hasFullDiskAccess ? "granted" : "not granted",
                                          "finderAutomation": "\(setup.finderAutomation)"])
        guard UserDefaults.standard.bool(forKey: "BurrowSetupWalk") else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        primaryAction()
        if step == .ready {
            model.automation.record("setup-finish", passed: !setup.isActive,
                                    detail: setup.isActive ? "Setup is still showing" : "Setup closed and the app opened")
        }
    }
}

// MARK: - Steps

private struct SetupWelcomeStep: View {
    var body: some View {
        VStack(spacing: 26) {
            SetupHeader(title: "Welcome to Burrow",
                        subtitle: "A calm, careful way to clean and look after your Mac.") {
                SetupAppIcon(size: 104)
            }
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    SetupRow(symbol: "eye.fill", title: "You see it first",
                             detail: "Every clean, uninstall and purge starts with a preview. Nothing is removed until you confirm.")
                    Divider().padding(.leading, 64)
                    SetupRow(symbol: "terminal.fill", title: "Powered by Mole",
                             detail: "All the work is done by the open-source Mole CLI, with its safety rules and your protected paths.")
                    Divider().padding(.leading, 64)
                    SetupRow(symbol: "hand.raised.fill", title: "Private by design",
                             detail: "No account and no analytics. Burrow only goes online to check GitHub for updates.")
                }
            }
            Text("Setup takes about a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SetupMoleStep: View {
    @Environment(MoleService.self) private var service

    var body: some View {
        VStack(spacing: 26) {
            SetupHeader(title: service.isAvailable ? "Mole is installed" : "Install Mole",
                        subtitle: "Burrow is the window; Mole is the engine. It’s free, open source and installs with Homebrew.") {
                SetupBadge(symbol: "shippingbox.fill", size: 88)
            }
            if let installation = service.installation {
                GlassCard(padding: 0) {
                    SetupRow(symbol: "checkmark", tint: .moleGood, title: "Mole \(installation.version)",
                             detail: installation.launcher.abbreviatingHome) {
                        SetupStatus(text: "Ready", good: true)
                    }
                }
            } else if service.isLocating {
                ProgressView().controlSize(.small)
            } else {
                MoleInstallCard()
            }
        }
    }
}

private struct SetupAccessStep: View {
    @Environment(AppModel.self) private var model
    @State private var openedPrivacySettings = false
    @State private var requesting = false
    private var setup: SetupModel { model.setup }

    var body: some View {
        VStack(spacing: 26) {
            SetupHeader(title: "Give Burrow access",
                        subtitle: "macOS protects parts of your disk. Choose what Burrow may reach; everything here is optional.") {
                SetupBadge(symbol: "lock.shield.fill", size: 88)
            }
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    fullDiskAccess
                    Divider().padding(.leading, 64)
                    finder
                    Divider().padding(.leading, 64)
                    SetupRow(symbol: "key.fill", title: "Administrator password",
                             detail: "Only system-level tasks need it. Burrow asks at that moment, passes it straight to macOS, and never stores it.") {
                        Text("Asked when needed").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("You can change any of this later in Settings › General.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var fullDiskAccess: some View {
        SetupRow(symbol: "internaldrive.fill", title: "Full Disk Access", badge: "Recommended",
                 detail: "Lets Mole measure and clean protected folders such as Mail, Safari and Messages data. Without it, scans skip them.",
                 note: fullDiskAccessNote) {
            if model.hasFullDiskAccess {
                SetupStatus(text: "On", good: true)
            } else if model.fullDiskAccessNeedsRelaunch {
                Button("Quit & Reopen") { model.relaunch() }
                    .buttonStyle(.soft)
            } else {
                Button("Open System Settings") {
                    openedPrivacySettings = true
                    FullDiskAccess.openSettings()
                }
                .buttonStyle(.soft)
            }
        }
    }

    private var fullDiskAccessNote: String? {
        if model.hasFullDiskAccess { return nil }
        if model.fullDiskAccessNeedsRelaunch {
            return "It’s on. Reopen Burrow to finish; setup carries on from here."
        }
        return openedPrivacySettings
            ? "Turn on Burrow in the list, or add it with the + button. If macOS offers Quit & Reopen, accept: setup carries on from here."
            : nil
    }

    private var finder: some View {
        SetupRow(symbol: "macwindow", title: "Finder",
                 detail: "Mole asks Finder for accurate free-space figures and uses it to move protected items to the Trash.",
                 note: setup.finderAutomation == .denied
                    ? "Burrow is turned off under Automation. Turn on Finder for Burrow in System Settings." : nil) {
            switch setup.finderAutomation {
            case .granted:
                SetupStatus(text: "Allowed", good: true)
            case .denied:
                Button("Open System Settings") { FinderAutomation.openSettings() }
                    .buttonStyle(.soft)
            case .notDetermined:
                Button("Allow…") {
                    requesting = true
                    Task {
                        await setup.requestFinderAutomation()
                        requesting = false
                    }
                }
                .buttonStyle(.soft)
                .disabled(requesting)
            }
        }
    }
}

private struct SetupReadyStep: View {
    @Environment(AppModel.self) private var model
    @Environment(MoleService.self) private var service
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginMessage: String?
    private var setup: SetupModel { model.setup }

    private var everythingInPlace: Bool {
        service.isAvailable && (model.hasFullDiskAccess || model.fullDiskAccessNeedsRelaunch) && setup.finderAutomation == .granted
    }

    var body: some View {
        VStack(spacing: 26) {
            SetupHeader(title: everythingInPlace ? "You’re all set" : "Burrow is ready",
                        subtitle: "Start with Status to see how your Mac is doing, then preview a Clean.") {
                SetupAppIcon(size: 104)
            }
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    if let installation = service.installation {
                        summary("Mole \(installation.version)", "Installed and ready.", state: .good)
                    } else {
                        summary("Mole isn’t installed", "Burrow will offer to install it when you open the app.", state: .attention)
                    }
                    Divider().padding(.leading, 64)
                    if model.hasFullDiskAccess {
                        summary("Full Disk Access", "On. Scans cover protected folders.", state: .good)
                    } else if model.fullDiskAccessNeedsRelaunch {
                        summary("Full Disk Access", "On. Burrow itself picks it up the next time it opens.", state: .good)
                    } else {
                        summary("Full Disk Access", "Off. Scans skip protected folders such as Mail and Safari data.", state: .neutral)
                    }
                    Divider().padding(.leading, 64)
                    switch setup.finderAutomation {
                    case .granted: summary("Finder", "Allowed.", state: .good)
                    case .denied: summary("Finder", "Off. Free-space figures are estimates until you allow it.", state: .neutral)
                    case .notDetermined: summary("Finder", "macOS will ask the first time Burrow needs it.", state: .neutral)
                    }
                }
            }
            GlassCard(padding: 16) {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Burrow at login").font(.callout.weight(.semibold))
                        Text(loginMessage ?? "Keeps the menu bar monitor available after you sign in.")
                            .font(.callout)
                            .foregroundStyle(loginMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.moleWarn))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
            }
        }
    }

    private enum SummaryState { case good, neutral, attention }

    private func summary(_ title: String, _ detail: String, state: SummaryState) -> some View {
        let (symbol, tint): (String, Color) = switch state {
        case .good: ("checkmark", .moleGood)
        case .neutral: ("minus", .secondary)
        case .attention: ("exclamationmark", .moleWarn)
        }
        return SetupRow(symbol: symbol, tint: tint, title: title, detail: detail)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginMessage = LoginItem.set(enabled)
        launchAtLogin = LoginItem.isEnabled
    }
}

// MARK: - Pieces

/// The icon, title and one-line purpose at the top of each step.
private struct SetupHeader<Icon: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var icon: Icon

    var body: some View {
        VStack(spacing: 18) {
            icon
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
        }
    }
}

struct SetupAppIcon: View {
    let size: CGFloat

    var body: some View {
        Group {
            if Bundle.main.bundleIdentifier != nil {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
            } else {
                // Running unbundled (swift run): no app icon to show.
                SetupBadge(symbol: FeatureTheme.setup.symbol, size: size * 0.85)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A brand-coloured symbol tile, the setup counterpart of `FeatureIcon`.
struct SetupBadge: View {
    let symbol: String
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(FeatureTheme.setup.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
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

/// One line of a setup list: what it is, why it matters, and its state or action on the right.
private struct SetupRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = FeatureTheme.setup.accent
    let title: String
    var badge: String? = nil
    let detail: String
    /// What to do next, shown once the user has started on this row.
    var note: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.callout.weight(.semibold))
                    if let badge { Pill(text: badge, tint: FeatureTheme.setup.accent) }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Label(note, systemImage: "arrow.turn.down.right")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .animation(.smooth(duration: 0.25), value: note)
    }
}

extension SetupRow where Trailing == EmptyView {
    init(symbol: String, tint: Color = FeatureTheme.setup.accent, title: String, badge: String? = nil,
         detail: String, note: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, badge: badge, detail: detail, note: note) { EmptyView() }
    }
}

/// The settled state of a row ("On", "Allowed").
private struct SetupStatus: View {
    let text: String
    let good: Bool

    var body: some View {
        Label(text, systemImage: good ? "checkmark.circle.fill" : "circle")
            .font(.callout.weight(.semibold))
            .foregroundStyle(good ? Color.moleGood : .secondary)
            .transition(.opacity)
    }
}

private struct SetupProgressDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? AnyShapeStyle(FeatureTheme.setup.accent) : AnyShapeStyle(.tertiary))
                    .frame(width: i == index ? 18 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.3), value: index)
        .accessibilityElement()
        .accessibilityLabel("Step \(index + 1) of \(count)")
    }
}
