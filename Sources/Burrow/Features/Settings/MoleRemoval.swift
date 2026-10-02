import Foundation

/// Pure parsing for `mo remove` (lib/manage/remove.sh at V1.56.0).
///
/// The dry run prints `• Would run: brew uninstall --force mole`, `• Would remove: <path>`,
/// `• Would move to Trash: <path>` and `• <path> (kept for manual review)`, then
/// "Dry run complete, no changes made". The real run lists `• Mole via Homebrew`, `• <binary path>`,
/// `• ~/.config/mole (to Trash)`, `• ~/.cache/mole`, `• ~/Library/Logs/mole` before its
/// "Press Enter to confirm, ESC to cancel" prompt, and always exits 0: failures only show up as
/// "Mole uninstalled with some errors".
enum MoleRemoval {
    /// `$HOME` as the Mole child process sees it (MoleLocator passes the app's HOME through).
    static var childHome: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }

    enum Item: Hashable {
        case homebrew
        /// A launcher, alias, cache or log path Mole deletes permanently.
        case remove(String)
        case trash(String)
        case kept(String)

        var path: String? {
            switch self {
            case .homebrew: nil
            case .remove(let p), .trash(let p), .kept(let p): p
            }
        }
    }

    struct Preview: Equatable {
        var items: [Item] = []
        /// "Dry run complete, no changes made" was printed.
        var completed = false
        /// "No Mole installation detected".
        var nothingInstalled = false

        var usesHomebrew: Bool { items.contains(.homebrew) }

        /// Launchers and aliases (the `Would remove:` rows that aren't Mole's own cache or log folders).
        func binaries(home: String = MoleRemoval.childHome) -> [String] {
            let owned = Set([home + "/.cache/mole", home + "/Library/Logs/mole"])
            return items.compactMap { item in
                if case .remove(let p) = item, !owned.contains(p) { return p }
                return nil
            }
        }

        /// Binaries whose folder the user can't write to. remove.sh deletes those with `sudo rm -f`
        /// (`[[ ! -w "$(dirname "$install")" ]]`), which only works in an administrator run.
        func binariesNeedingAdmin(home: String = MoleRemoval.childHome,
                                  isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }) -> [String] {
            binaries(home: home).filter { !isWritable(($0 as NSString).deletingLastPathComponent) }
        }
    }

    static func parsePreview(_ text: String) -> Preview {
        var preview = Preview()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = ANSI.strip(String(raw)).trimmingCharacters(in: .whitespaces)
            if t.contains("No Mole installation detected") { preview.nothingInstalled = true }
            if t.contains("Dry run complete") { preview.completed = true }
            guard t.hasPrefix("•") else { continue }
            let body = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("Would run: brew uninstall") {
                preview.items.append(.homebrew)
            } else if let path = body.dropPrefix("Would remove: ") {
                preview.items.append(.remove(path))
            } else if let path = body.dropPrefix("Would move to Trash: ") {
                preview.items.append(.trash(path))
            } else if body.hasSuffix(" (kept for manual review)") {
                preview.items.append(.kept(String(body.dropLast(" (kept for manual review)".count))))
            }
        }
        return preview
    }

    /// What the real run says it will delete, read from the list printed before its prompt.
    struct ConfirmList: Equatable {
        var homebrew = false
        /// Absolute launcher and alias paths.
        var binaries: [String] = []
    }

    /// Collects the real run's list: the `•` rows after "will delete the following:".
    static func parseConfirmList(_ lines: [String]) -> ConfirmList? {
        guard let header = lines.lastIndex(where: { $0.contains("will delete the following:") }) else { return nil }
        var list = ConfirmList()
        for raw in lines[(header + 1)...] {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("•") else { continue }
            let body = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            if body == "Mole via Homebrew" {
                list.homebrew = true
            } else if body.hasPrefix("/"), !body.hasSuffix("(kept for manual review)") {
                list.binaries.append(body)
            }
        }
        return list
    }

    /// The real run may only touch what the preview showed. Anything else (a new install appeared,
    /// Homebrew state changed) means the user never confirmed it, so the app declines the prompt.
    static func confirmListMatchesPreview(_ list: ConfirmList, _ preview: Preview, home: String = MoleRemoval.childHome) -> Bool {
        list.homebrew == preview.usesHomebrew && Set(list.binaries) == Set(preview.binaries(home: home))
    }

    enum Outcome: Equatable {
        case removed
        /// "Mole uninstalled with some errors": exit code is still 0.
        case partial(leftovers: [String])
        /// The app declined the prompt because the real list differed from the preview.
        case declined
        /// Mole stopped before removing anything (cancelled prompt, nothing installed, failure).
        case failed(String)
    }

    static func outcome(lines: [String], exitCode: Int32?, declined: Bool, leftovers: [String]) -> Outcome {
        if declined { return .declined }
        if lines.contains(where: { $0.contains("uninstalled with some errors") }) { return .partial(leftovers: leftovers) }
        if lines.contains(where: { $0.contains("uninstalled successfully") }) {
            return leftovers.isEmpty ? .removed : .partial(leftovers: leftovers)
        }
        if let exitCode, exitCode != 0 {
            let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            return .failed(last.isEmpty ? "Mole stopped with exit code \(exitCode)." : last)
        }
        if lines.contains(where: { $0.contains("No Mole installation detected") }) {
            return .failed("Mole found no installation to remove.")
        }
        return .failed("Mole stopped before removing anything.")
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }
}
