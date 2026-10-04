import Foundation
import Observation

enum SetupStep: String, CaseIterable, Sendable {
    case welcome, mole, access, ready
}

/// First-run setup: what it shows, where the user is, and whether it has been finished.
///
/// The flow is Welcome → Install Mole (only when Mole is missing) → Access → Ready. Nothing in it is
/// mandatory except Mole itself; every permission can be granted later from Settings › General.
/// The current step is saved so setup resumes after macOS quits and reopens Burrow to apply
/// Full Disk Access.
@MainActor
@Observable
final class SetupModel {
    enum Presentation: Equatable {
        /// First launch: waiting for the Mole lookup before deciding.
        case pending
        case shown
        case hidden
    }

    /// Bump when setup gains a step existing users should see.
    static let version = 1
    private static let completedKey = "BurrowSetupCompleted"
    private static let stepKey = "BurrowSetupStep"

    private(set) var presentation: Presentation
    private(set) var steps: [SetupStep] = [.welcome, .access, .ready]
    private(set) var step: SetupStep = .welcome
    /// Direction of the last move, for the step transition.
    private(set) var movedForward = true
    var finderAutomation: FinderAutomation = .notDetermined

    @ObservationIgnored private let defaults: UserDefaults
    /// `-BurrowSetup <step>` shows setup at that step without saving anything (screenshots, E2E).
    @ObservationIgnored private let forced: SetupStep?

    init(automationActive: Bool, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        forced = defaults.string(forKey: "BurrowSetup").flatMap(SetupStep.init(rawValue:))
        if forced != nil {
            presentation = .pending
        } else if automationActive || defaults.integer(forKey: Self.completedKey) >= Self.version {
            presentation = .hidden
        } else {
            presentation = .pending
        }
    }

    var isActive: Bool { presentation != .hidden }
    var index: Int { steps.firstIndex(of: step) ?? 0 }
    var isFirst: Bool { index == 0 }

    /// Decides whether to show setup once the Mole lookup has finished.
    func resolve(moleAvailable: Bool, fullDiskAccess: Bool) async {
        guard presentation == .pending else { return }
        finderAutomation = await FinderAutomation.status()
        if let forced {
            steps = Self.steps(moleAvailable: moleAvailable && forced != .mole)
            step = forced
            presentation = .shown
            return
        }
        // Someone who already uses Burrow with everything in place has nothing to set up.
        if moleAvailable, fullDiskAccess, finderAutomation == .granted {
            defaults.set(Self.version, forKey: Self.completedKey)
            presentation = .hidden
            return
        }
        steps = Self.steps(moleAvailable: moleAvailable)
        let saved = defaults.string(forKey: Self.stepKey).flatMap(SetupStep.init(rawValue:))
        step = saved.flatMap { steps.contains($0) ? $0 : nil } ?? .welcome
        presentation = .shown
    }

    /// Settings › General › Show Setup Again.
    func restart(moleAvailable: Bool) {
        steps = Self.steps(moleAvailable: moleAvailable)
        movedForward = true
        step = .welcome
        presentation = .shown
    }

    func advance() {
        guard index + 1 < steps.count else { return finish() }
        move(to: steps[index + 1], forward: true)
    }

    func back() {
        guard index > 0 else { return }
        move(to: steps[index - 1], forward: false)
    }

    func finish() {
        if forced == nil {
            defaults.set(Self.version, forKey: Self.completedKey)
            defaults.removeObject(forKey: Self.stepKey)
        }
        presentation = .hidden
    }

    func refreshFinderAutomation() async {
        finderAutomation = await FinderAutomation.status()
    }

    func requestFinderAutomation() async {
        finderAutomation = await FinderAutomation.request()
    }

    private func move(to next: SetupStep, forward: Bool) {
        movedForward = forward
        step = next
        if forced == nil { defaults.set(next.rawValue, forKey: Self.stepKey) }
    }

    private static func steps(moleAvailable: Bool) -> [SetupStep] {
        moleAvailable ? [.welcome, .access, .ready] : [.welcome, .mole, .access, .ready]
    }
}
