import SwiftUI

struct SettingsLogsPane: View {
    @State private var sizes: [String: Int64] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(tab: .logs, subtitle: "Mole records every operation and deletion in ~/Library/Logs/mole.")
            HStack(spacing: 10) {
                logButton("Logs Folder", "folder", MolePaths.logs, reveal: true)
                logButton("Operations", "list.bullet.rectangle", MolePaths.operationsLog)
                logButton("Deletions", "trash", MolePaths.deletionsLog)
            }
            Label("The History page shows these records as sessions. The files open in Console.", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.callout)
                .foregroundStyle(.secondary)
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
            sizes = await Task.detached(priority: .userInitiated) { () -> [String: Int64] in
                var sizes: [String: Int64] = [:]
                for path in [MolePaths.operationsLog, MolePaths.deletionsLog] {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let size = attrs[.size] as? NSNumber {
                        sizes[path] = size.int64Value
                    }
                }
                return sizes
            }.value
        }
    }
}
