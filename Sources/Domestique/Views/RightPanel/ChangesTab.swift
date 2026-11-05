import GitKit
import SwiftUI

struct ChangesTab: View {
    let model: WorkspaceModel

    var body: some View {
        if let error = model.diffError {
            PanelMessage(text: error, isError: true)
        } else if model.diffFiles.isEmpty {
            PanelMessage(
                text: model.isLoadingDiff ? "Loading changes…" : "No changes yet",
                detail: "Changes against origin/\(model.workspace?.baseBranch ?? "main") show up here.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("\(model.diffFiles.count) file\(model.diffFiles.count == 1 ? "" : "s") changed")
                            .font(Theme.ui)
                            .foregroundStyle(Theme.text2)
                        Spacer()
                        DiffCount(additions: model.diffStat.additions, deletions: model.diffStat.deletions)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    ForEach(model.diffFiles) { file in
                        HoverRow(selected: false, height: 28) {
                            model.openFile(file.path, diff: true)
                        } content: {
                            ChangedFileRow(file: file)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
    }
}

struct ChangedFileRow: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 8) {
            PathText(path: file.path)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            Text(statusLetter(file.status))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor(file.status))
                .frame(width: 10)
            DiffCount(additions: file.additions, deletions: file.deletions)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .font(Theme.ui)
    }
}

/// "Sources/AgentKit/" dimmed + "ClaudeSession.swift" in primary text.
struct PathText: View {
    let path: String

    var body: some View {
        let slash = path.lastIndex(of: "/")
        let dir = slash.map { String(path[...$0]) } ?? ""
        let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
        Text(verbatim: dir).foregroundStyle(Theme.text2) + Text(verbatim: name).foregroundStyle(Theme.text)
    }
}

func statusLetter(_ kind: FileStatus.Kind) -> String {
    switch kind {
    case .added: "A"
    case .untracked: "U"
    case .deleted: "D"
    case .renamed: "R"
    case .conflicted: "!"
    case .modified: "M"
    }
}

func statusColor(_ kind: FileStatus.Kind) -> Color {
    switch kind {
    case .added, .untracked: Theme.added
    case .deleted, .conflicted: Theme.removed
    case .renamed: Theme.running
    case .modified: Theme.warning
    }
}

/// Centered muted message for empty/error states.
struct PanelMessage: View {
    let text: String
    var detail: String? = nil
    var isError = false

    var body: some View {
        VStack(spacing: 6) {
            Text(text)
                .font(Theme.ui)
                .foregroundStyle(isError ? Theme.removed : Theme.text2)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let detail {
                Text(detail)
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
