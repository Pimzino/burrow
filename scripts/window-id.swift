// Prints the largest on-screen window id owned by a pid: swift scripts/window-id.swift <pid>
import CoreGraphics
// Optional second argument "smallest" picks the smallest window instead (e.g. the Settings window).
let pid = Int(CommandLine.arguments[1])!
let wantSmallest = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "smallest"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
let ordered: ([[String: Any]], ([String: Any], [String: Any]) -> Bool) -> [String: Any]? = { list, less in
    wantSmallest ? list.min(by: less) : list.max(by: less)
}
let best = ordered(windows) { a, b in
    let ba = a[kCGWindowBounds as String] as? [String: Double] ?? [:], bb = b[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (ba["Width"] ?? 0) * (ba["Height"] ?? 0) < (bb["Width"] ?? 0) * (bb["Height"] ?? 0)
}
if let id = best?[kCGWindowNumber as String] { print(id) }
