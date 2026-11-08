import ServerKit
import SwiftUI

/// The workspace's changes against its merge base.
struct DiffView: View {
    let server: ServerConnection
    let workspaceID: String
    @State private var diff: Proto_Diff?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if let diff {
                if diff.files.isEmpty {
                    Text("No changes yet").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(diff.files, id: \.path) { file in
                            NavigationLink {
                                ScrollView {
                                    PatchView(path: file.path, patch: file.binary ? "Binary file" : file.patch)
                                        .padding()
                                }
                                .navigationTitle((file.path as NSString).lastPathComponent)
                                .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                FileDiffRow(file: file)
                            }
                        }
                    } header: {
                        Text(summary(diff))
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            diff = try await server.ready().diff(workspaceID: workspaceID)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func summary(_ d: Proto_Diff) -> String {
        let add = d.files.reduce(0) { $0 + Int($1.additions) }
        let del = d.files.reduce(0) { $0 + Int($1.deletions) }
        var s = "\(d.files.count) file\(d.files.count == 1 ? "" : "s") · +\(add) −\(del)"
        if d.ahead > 0 { s += " · \(d.ahead) commit\(d.ahead == 1 ? "" : "s") ahead" }
        return s
    }
}

private struct FileDiffRow: View {
    let file: Proto_FileDiff

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text((file.path as NSString).lastPathComponent).font(.subheadline.weight(.medium))
                let dir = (file.path as NSString).deletingLastPathComponent
                if !dir.isEmpty {
                    Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Text("+\(file.additions)").foregroundStyle(Palette.added)
            Text("−\(file.deletions)").foregroundStyle(Palette.removed)
        }
        .font(.caption.monospacedDigit())
    }

    private var icon: String {
        switch file.status {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .renamed: "arrow.right.square"
        default: "pencil"
        }
    }

    private var color: Color {
        switch file.status {
        case .added: Palette.added
        case .deleted: Palette.removed
        default: .secondary
        }
    }
}

/// A unified diff, coloured per line, scrolling sideways for long lines.
struct PatchView: View {
    let path: String
    let patch: String
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(foreground(line))
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Rectangle().fill(background(line)))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: width, alignment: .leading)
                .padding(.vertical, 6)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var lines: [String] {
        patch.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ") && !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") }
    }

    private func foreground(_ l: String) -> Color {
        if l.hasPrefix("@@") { return .secondary }
        if l.hasPrefix("+") { return Palette.added }
        if l.hasPrefix("-") { return Palette.removed }
        return .primary
    }

    private func background(_ l: String) -> Color {
        if l.hasPrefix("+") { return Palette.addedBG }
        if l.hasPrefix("-") { return Palette.removedBG }
        return .clear
    }
}
