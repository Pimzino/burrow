import SwiftUI

struct SettingsLogsPane: View {
    @State private var lines: [OutputLine] = []
    @State private var loaded = false
    @State private var sizes: [String: Int64] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(tab: .logs, subtitle: "Mole records every operation and deletion in ~/Library/Logs/mole.")
            HStack(spacing: 10) {
                logButton("Logs Folder", "folder", MolePaths.logs, reveal: true)
                logButton("Operations", "list.bullet.rectangle", MolePaths.operationsLog)
                logButton("Deletions", "trash", MolePaths.deletionsLog)
            }
            HStack {
                Text("Last 200 lines of operations.log").font(.headline)
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise", action: load)
                    .buttonStyle(.glass)
                    .keyboardShortcut("r", modifiers: .command)
            }
            if loaded && lines.isEmpty {
                EmptyStateView(symbol: "doc.text", title: "No operations yet",
                               message: "operations.log is created the first time Mole changes something.")
                    .frame(maxHeight: .infinity)
            } else {
                ConsoleView(lines: lines, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: load)
    }

    private func logButton(_ title: String, _ symbol: String, _ path: String, reveal: Bool = false) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        return Button {
            if reveal { Finder.open(path) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.title3).foregroundStyle(SettingsTab.logs.colors[0])
                Text(title).font(.callout.weight(.semibold))
                Text(exists ? (sizes[path].map { ByteFormat.string($0) } ?? (reveal ? "Open in Finder" : "—")) : "Not created yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .disabled(!exists)
        .contextMenu {
            Button("Reveal in Finder", systemImage: "finder") { Finder.reveal(path) }
            Button("Copy Path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
        .help(path.abbreviatingHome)
    }

    private func load() {
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([String], [String: Int64]) in
                var sizes: [String: Int64] = [:]
                for path in [MolePaths.operationsLog, MolePaths.deletionsLog] {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let size = attrs[.size] as? NSNumber {
                        sizes[path] = size.int64Value
                    }
                }
                guard let data = FileManager.default.contents(atPath: MolePaths.operationsLog) else { return ([], sizes) }
                // Only decode the tail: the log grows without bound.
                let tail = data.count > 400_000 ? data.suffix(400_000) : data
                let text = String(decoding: tail, as: UTF8.self)
                let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                return (Array(all.suffix(200)), sizes)
            }.value
            lines = result.0.enumerated().map { OutputLine(id: $0.offset, stream: .stdout, raw: $0.element) }
            sizes = result.1
            loaded = true
        }
    }
}
