import Foundation

/// One task from Mole's optimize catalog (`lib/optimize/catalog.sh`).
struct OptimizeTask: Sendable, Equatable, Identifiable, Hashable {
    /// Action ID; also the whitelist key.
    let id: String
    /// Printed as `➤ <displayName>` while running.
    let displayName: String
    /// Label Mole's whitelist menu uses.
    let whitelistName: String
    let summary: String

    var symbol: String { OptimizeCatalog.symbols[id] ?? "wand.and.stars" }
    /// Whether a real run uses sudo for this task (research table).
    var needsAdmin: Bool { OptimizeCatalog.adminTasks.contains(id) }
    var note: String? { OptimizeCatalog.notes[id] }
}

enum OptimizeCatalog {
    static let adminTasks: Set<String> = [
        "system_maintenance", "network_optimization", "network_stack_optimize", "disk_permissions_repair",
        "spotlight_index_optimize", "periodic_maintenance",
    ]

    static let notes: [String: String] = [
        "spotlight_index_optimize": "Only rebuilds when search is slow",
        "network_stack_optimize": "Skipped while a VPN is active",
        "disk_verify": "Off unless disk verification is enabled",
        "login_items_audit": "Report only",
        "launch_agents_cleanup": "Report only",
        "saved_state_cleanup": "Older than 30 days",
    ]

    static let symbols: [String: String] = [
        "system_maintenance": "magnifyingglass.circle.fill",
        "cache_refresh": "photo.stack.fill",
        "saved_state_cleanup": "macwindow.on.rectangle",
        "fix_broken_configs": "wrench.and.screwdriver.fill",
        "network_optimization": "network",
        "sqlite_vacuum": "cylinder.split.1x2.fill",
        "prevent_network_dsstore": "externaldrive.badge.xmark",
        "legacy_overrides_audit": "clock.arrow.circlepath",
        "network_stack_optimize": "point.3.connected.trianglepath.dotted",
        "disk_permissions_repair": "lock.open.rotation",
        "spotlight_index_optimize": "sparkle.magnifyingglass",
        "spotlight_orphan_rules_cleanup": "line.3.horizontal.decrease.circle.fill",
        "periodic_maintenance": "calendar.badge.clock",
        "shared_file_list_repair": "sidebar.left",
        "disk_verify": "internaldrive.fill",
        "login_items_audit": "person.badge.key.fill",
        "quarantine_cleanup": "checkmark.shield.fill",
        "launch_agents_cleanup": "gearshape.2.fill",
        "notification_cleanup": "bell.badge.fill",
        "coreduet_cleanup": "chart.bar.doc.horizontal.fill",
    ]

    /// Mole v1.56.0's catalog, used when the libraries cannot be read.
    static let fallback: [OptimizeTask] = [
        .init(id: "system_maintenance", displayName: "DNS & Spotlight Check", whitelistName: "DNS & Spotlight Check", summary: "Refresh DNS cache & verify Spotlight status"),
        .init(id: "cache_refresh", displayName: "Finder Cache Refresh", whitelistName: "Finder Cache Refresh", summary: "Refresh QuickLook thumbnails & icon services cache"),
        .init(id: "saved_state_cleanup", displayName: "App State Cleanup", whitelistName: "App State Cleanup", summary: "Remove old saved application states (30+ days)"),
        .init(id: "fix_broken_configs", displayName: "Broken Config Repair", whitelistName: "Broken Config Repair", summary: "Fix corrupted preferences files"),
        .init(id: "network_optimization", displayName: "Network Cache Refresh", whitelistName: "Network Cache Refresh", summary: "Optimize DNS cache & restart mDNSResponder"),
        .init(id: "sqlite_vacuum", displayName: "Database Optimization", whitelistName: "Database Optimization", summary: "Compress SQLite databases for Mail, Safari & Messages (skips if apps are running)"),
        .init(id: "prevent_network_dsstore", displayName: "Prevent Finder .DS_Store", whitelistName: "Prevent Finder .DS_Store", summary: "Set a persistent Finder preference to stop writing .DS_Store on SMB/AFP/NFS and USB volumes"),
        .init(id: "legacy_overrides_audit", displayName: "Legacy Overrides", whitelistName: "Legacy Overrides", summary: "Remove hidden App Nap and disk-image verification overrides left by old tweak tools"),
        .init(id: "network_stack_optimize", displayName: "Network Stack Refresh", whitelistName: "Network Stack Refresh", summary: "Flush routing table and ARP cache to resolve network issues"),
        .init(id: "disk_permissions_repair", displayName: "Permission Repair", whitelistName: "Permission Repair", summary: "Fix user directory permission issues"),
        .init(id: "spotlight_index_optimize", displayName: "Spotlight Optimization", whitelistName: "Spotlight Optimization", summary: "Rebuild index if search is slow (smart detection)"),
        .init(id: "spotlight_orphan_rules_cleanup", displayName: "Spotlight Orphan Rules", whitelistName: "Spotlight Orphan Rules", summary: "Remove Spotlight search-rule entries for apps that are no longer installed"),
        .init(id: "periodic_maintenance", displayName: "Periodic Maintenance", whitelistName: "Periodic Maintenance", summary: "Run macOS daily/weekly/monthly maintenance scripts if stale"),
        .init(id: "shared_file_list_repair", displayName: "Shared File Lists", whitelistName: "Shared File Lists", summary: "Repair corrupted Finder favorites and recent documents"),
        .init(id: "disk_verify", displayName: "Disk Health", whitelistName: "Disk Health", summary: "Verify filesystem integrity"),
        .init(id: "login_items_audit", displayName: "Login Items", whitelistName: "Login Items Audit", summary: "Audit login items for broken entries"),
        .init(id: "quarantine_cleanup", displayName: "Quarantine Database Cleanup", whitelistName: "Quarantine Database Cleanup", summary: "Clear Gatekeeper download tracking history"),
        .init(id: "launch_agents_cleanup", displayName: "Launch Agents Cleanup", whitelistName: "Launch Agents Cleanup", summary: "Report LaunchAgents whose binaries no longer exist"),
        .init(id: "notification_cleanup", displayName: "Notifications", whitelistName: "Notifications", summary: "Clean old delivered notifications to reduce database bloat"),
        .init(id: "coreduet_cleanup", displayName: "Usage Data", whitelistName: "Usage Data", summary: "Clean old usage tracking data"),
    ]

    /// Parses `action|display|whitelist name|description` rows.
    static func parse(_ output: String) -> [OptimizeTask] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, !parts[0].isEmpty else { return nil }
            return OptimizeTask(id: parts[0], displayName: parts[1], whitelistName: parts[2], summary: parts[3])
        }
    }

    /// Loads the catalog from Mole's own `catalog.sh` (common.sh is already sourced by `MoleService.bash`).
    @MainActor
    static func load(service: MoleService) async -> (tasks: [OptimizeTask], fromMole: Bool) {
        guard let libexec = service.installation?.libexec else { return (fallback, false) }
        let script = """
        source "\(libexec)/lib/optimize/catalog.sh" || exit 3
        for i in "${!MOLE_OPTIMIZE_ACTIONS[@]}"; do
          printf '%s|%s|%s|%s\\n' "${MOLE_OPTIMIZE_ACTIONS[$i]}" "${MOLE_OPTIMIZE_HEALTH_NAMES[$i]}" "${MOLE_OPTIMIZE_WHITELIST_NAMES[$i]}" "${MOLE_OPTIMIZE_DESCRIPTIONS[$i]}"
        done
        """
        guard let result = try? await service.bash(script), result.succeeded else { return (fallback, false) }
        let tasks = parse(result.stdoutString)
        return tasks.isEmpty ? (fallback, false) : (tasks, true)
    }
}
