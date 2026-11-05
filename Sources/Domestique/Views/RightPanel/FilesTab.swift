import GitKit
import SwiftUI

/// Compact file tree with a filter field. Changed files get a coloured dot.
struct FilesTab: View {
    let model: WorkspaceModel
    @State private var filter = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                TextField("Filter files", text: $filter)
                    .textFieldStyle(.plain)
                    .font(Theme.ui)
                if !filter.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", help: "Clear", size: 11) { filter = "" }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Hairline()
            if model.files.isEmpty {
                PanelMessage(text: "Loading files…")
                    .onAppear { model.refreshFiles() }
            } else {
                let changed = Dictionary(model.diffFiles.map { ($0.path, $0.status) }, uniquingKeysWith: { a, _ in a })
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if filter.isEmpty {
                            ForEach(visibleRows(), id: \.node.path) { row in
                                treeRow(row.node, depth: row.depth, changed: changed)
                            }
                        } else {
                            let q = filter.lowercased()
                            ForEach(Array(model.files.lazy.filter { $0.lowercased().contains(q) }.prefix(500)), id: \.self) { path in
                                HoverRow(selected: model.openedFile?.path == path, height: 26) {
                                    model.openFile(path, diff: false)
                                } content: {
                                    HStack(spacing: 6) {
                                        PathText(path: path).lineLimit(1).truncationMode(.head)
                                        Spacer(minLength: 4)
                                        if let k = changed[path] { Circle().fill(statusColor(k)).frame(width: 6, height: 6) }
                                    }
                                    .font(Theme.ui)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private struct Row {
        let node: FileNode
        let depth: Int
    }

    /// Flatten only the expanded part of the tree; cost is proportional to what's visible.
    private func visibleRows() -> [Row] {
        var rows: [Row] = []
        func walk(_ nodes: [FileNode], depth: Int) {
            for n in nodes {
                rows.append(Row(node: n, depth: depth))
                if let children = n.children, expanded.contains(n.path) { walk(children, depth: depth + 1) }
            }
        }
        walk(model.fileTree, depth: 0)
        return rows
    }

    @ViewBuilder private func treeRow(_ node: FileNode, depth: Int, changed: [String: FileStatus.Kind]) -> some View {
        let isDir = node.children != nil
        let open = expanded.contains(node.path)
        HoverRow(selected: !isDir && model.openedFile?.path == node.path, height: 24) {
            if isDir {
                if open { expanded.remove(node.path) } else { expanded.insert(node.path) }
            } else {
                model.openFile(node.path, diff: false)
            }
        } content: {
            HStack(spacing: 5) {
                Group {
                    if isDir {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10)
                .foregroundStyle(Theme.text3)
                Image(systemName: isDir ? "folder" : "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 14)
                Text(node.name)
                    .font(Theme.ui)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !isDir, let k = changed[node.path] {
                    Circle().fill(statusColor(k)).frame(width: 6, height: 6)
                } else if isDir, changed.keys.contains(where: { $0.hasPrefix(node.path + "/") }), !open {
                    Circle().fill(Theme.text3).frame(width: 5, height: 5)
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
        }
    }
}
