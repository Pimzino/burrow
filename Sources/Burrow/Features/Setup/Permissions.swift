import AppKit
import CoreServices
import ServiceManagement

/// Permission to send Apple events to Finder. Mole asks Finder for accurate free-space figures and
/// uses it to move protected items to the Trash. macOS attributes those child-process events to Burrow.
enum FinderAutomation: Sendable {
    case granted
    case denied
    /// macOS hasn't asked yet (or Finder isn't running, so it can't tell).
    case notDetermined

    /// Never prompts. Cheap, but it is a system call, so keep it off the main thread.
    nonisolated static func status() async -> FinderAutomation {
        await Task.detached { determine(ask: false) }.value
    }

    /// Shows the macOS consent prompt if the user hasn't decided yet; returns their answer.
    nonisolated static func request() async -> FinderAutomation {
        await Task.detached { determine(ask: true) }.value
    }

    private nonisolated static func determine(ask: Bool) -> FinderAutomation {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return .notDetermined }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notDetermined   // errAEEventWouldRequireUserConsent, procNotFound
        }
    }

    @MainActor static func openSettings() { PrivacySettings.open("Privacy_Automation") }
}

/// "Open Burrow at login" through `SMAppService`.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters Burrow as a login item. Returns a message when it didn't take effect.
    static func set(_ enabled: Bool) -> String? {
        var message: String?
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = Bundle.main.bundleIdentifier == nil
                ? "Available when Burrow runs as an app bundle."
                : error.localizedDescription
        }
        if SMAppService.mainApp.status == .requiresApproval {
            message = "Approve Burrow in System Settings › General › Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
        return message
    }
}
