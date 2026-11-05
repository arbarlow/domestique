import GitKit
import SwiftUI

/// Codex-style file viewer: breadcrumb bar + line-numbered, highlighted code or a unified diff.
struct FileViewer: View {
    let model: WorkspaceModel
    let opened: OpenedFile
    @State private var loaded: Loaded?

    enum Loaded: Sendable {
        case code([AttributedString])
        case diff([DiffRow])
        case message(String)
    }

    struct DiffRow: Sendable {
        enum Kind: Sendable { case line(DiffLine.Kind, old: Int?, new: Int?), gap(Int) }
        var kind: Kind
        var text: AttributedString
    }

    private var diffFile: FileDiff? { model.diffFiles.first { $0.path == opened.path } }
    private var absolutePath: String { (model.workspace?.path ?? "") + "/" + opened.path }

    private var loadKey: String {
        let d = diffFile
        return "\(opened.path)|\(opened.showDiff)|\(d?.additions ?? -1)|\(d?.deletions ?? -1)|\(d?.hunks.count ?? -1)"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Hairline()
            Group {
                switch loaded {
                case .none:
                    Color.clear
                case .message(let m):
                    PanelMessage(text: m)
                case .code(let lines):
                    CodeLinesView(lines: lines)
                case .diff(let rows):
                    DiffRowsView(rows: rows)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .task(id: loadKey) { loaded = await load() }
    }

    // MARK: bar

    private var topBar: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", help: "Back") { model.openedFile = nil }
            Breadcrumb(path: opened.path)
            Spacer(minLength: 6)
            if diffFile != nil {
                Button {
                    model.openedFile = OpenedFile(path: opened.path, showDiff: !opened.showDiff)
                } label: {
                    Label(opened.showDiff ? "Show file" : "Show changes", systemImage: opened.showDiff ? "doc.text" : "plusminus")
                }
                .buttonStyle(.softCompact)
                .disabled(diffFile?.status == .deleted && opened.showDiff)
            }
            IconButton(symbol: "doc.on.doc", help: "Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(opened.path, forType: .string)
            }
            Button("Open") { model.openInEditor(path: absolutePath) }
                .buttonStyle(.softCompact)
                .help("Open in editor")
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    // MARK: loading

    private func load() async -> Loaded {
        let path = absolutePath
        let language = SyntaxHighlighter.language(forPath: opened.path)
        if opened.showDiff, let file = diffFile {
            if file.isBinary { return .message("Binary file changed") }
            if file.isTooLarge { return .message("Diff too large to display") }
            return .diff(await Task.detached(priority: .userInitiated) { Self.diffRows(file, language: language) }.value)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attrs else { return .message("File not found") }
        let size = (attrs[.size] as? Int) ?? 0
        if size > 2_000_000 { return .message("File too large to preview (\(size / 1024) KB)") }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(mtime)|\(language)"
        if let hit = HighlightCache.get(key) { return .code(hit) }
        let result: Loaded = await Task.detached(priority: .userInitiated) {
            guard let data = FileManager.default.contents(atPath: path) else { return .message("Couldn't read file") }
            if data.prefix(8000).contains(0) { return .message("Binary file") }
            let text = String(decoding: data, as: UTF8.self)
            var lines = SyntaxHighlighter.highlightLines(text, language: language)
            if lines.count > 1, lines.last.map({ $0.characters.isEmpty }) == true { lines.removeLast() }
            return .code(lines)
        }.value
        if case .code(let lines) = result { HighlightCache.put(key, lines) }
        return result
    }

    nonisolated static func diffRows(_ file: FileDiff, language: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var prevOldEnd = 1
        for hunk in file.hunks {
            let gap = hunk.oldStart - prevOldEnd
            if gap > 0, hunk.oldStart > 0 { rows.append(DiffRow(kind: .gap(gap), text: AttributedString())) }
            let highlighted = SyntaxHighlighter.highlightLines(hunk.lines.map(\.text).joined(separator: "\n"), language: language)
            for (i, line) in hunk.lines.enumerated() {
                let text = i < highlighted.count ? highlighted[i] : AttributedString(line.text)
                rows.append(DiffRow(kind: .line(line.kind, old: line.oldLine, new: line.newLine), text: text))
            }
            prevOldEnd = hunk.oldStart + max(hunk.oldCount, 0)
        }
        return rows
    }
}

/// Small LRU-ish cache of highlighted files keyed by path + mtime + language.
@MainActor
enum HighlightCache {
    private static var store: [String: [AttributedString]] = [:]
    private static var order: [String] = []

    static func get(_ key: String) -> [AttributedString]? { store[key] }

    static func put(_ key: String, _ value: [AttributedString]) {
        if store[key] == nil { order.append(key) }
        store[key] = value
        while order.count > 24 { store[order.removeFirst()] = nil }
    }
}

/// "src › features › calendar › row.tsx"
private struct Breadcrumb: View {
    let path: String

    var body: some View {
        let parts = path.split(separator: "/").map(String.init)
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                Text(part)
                    .font(i == parts.count - 1 ? Theme.uiMedium : Theme.ui)
                    .foregroundStyle(i == parts.count - 1 ? Theme.text : Theme.text2)
                    .lineLimit(1)
                    .layoutPriority(i == parts.count - 1 ? 1 : 0)
            }
        }
        .truncationMode(.head)
        .help(path)
    }
}

// MARK: - Rows

private let codeFont = Font.system(size: 11.5, design: .monospaced)
private let codeLineHeight: CGFloat = 19

private func gutterWidth(maxNumber: Int) -> CGFloat {
    CGFloat(max(2, String(maxNumber).count)) * 7.2 + 14
}

private struct CodeLinesView: View {
    let lines: [AttributedString]

    var body: some View {
        let gutter = gutterWidth(maxNumber: lines.count)
        BidirectionalScroll {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<lines.count, id: \.self) { i in
                    HStack(spacing: 0) {
                        Text(verbatim: "\(i + 1)")
                            .foregroundStyle(Theme.text3)
                            .frame(width: gutter, alignment: .trailing)
                            .padding(.trailing, 14)
                        Text(lines[i])
                            .foregroundStyle(Theme.text)
                            .fixedSize()
                        Spacer(minLength: 16)
                    }
                    .font(codeFont)
                    .frame(height: codeLineHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }
}

private struct DiffRowsView: View {
    let rows: [FileViewer.DiffRow]

    var body: some View {
        let maxLine = rows.reduce(0) { m, r in
            if case .line(_, let o, let n) = r.kind { return max(m, o ?? 0, n ?? 0) }
            return m
        }
        let gutter = gutterWidth(maxNumber: maxLine)
        BidirectionalScroll {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rows.count, id: \.self) { i in
                    row(rows[i], gutter: gutter)
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private func row(_ r: FileViewer.DiffRow, gutter: CGFloat) -> some View {
        switch r.kind {
        case .gap(let n):
            HStack(spacing: 8) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: gutter * 2, alignment: .center)
                Text(verbatim: "\(n) unmodified line\(n == 1 ? "" : "s")")
                Spacer(minLength: 0)
            }
            .font(Theme.small)
            .foregroundStyle(Theme.text3)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sunken)
        case .line(let kind, let old, let new):
            HStack(spacing: 0) {
                Text(verbatim: old.map(String.init) ?? "")
                    .frame(width: gutter, alignment: .trailing)
                Text(verbatim: new.map(String.init) ?? "")
                    .frame(width: gutter, alignment: .trailing)
                Text(verbatim: sign(kind))
                    .foregroundStyle(signColor(kind))
                    .frame(width: 20)
                Text(r.text)
                    .foregroundStyle(Theme.text)
                    .fixedSize()
                Spacer(minLength: 16)
            }
            .foregroundStyle(Theme.text3)
            .font(codeFont)
            .frame(height: codeLineHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(kind))
        }
    }

    private func sign(_ k: DiffLine.Kind) -> String {
        switch k {
        case .added: "+"
        case .removed: "-"
        case .context: ""
        case .noNewline: "↵"
        }
    }

    private func signColor(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: Theme.added
        case .removed: Theme.removed
        default: Theme.text3
        }
    }

    private func background(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: Theme.addedBG
        case .removed: Theme.removedBG
        default: .clear
        }
    }
}
