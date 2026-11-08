import SwiftUI

// The Mac app's block-level markdown parser (Sources/Domestique/Views/MarkdownView.swift), with views
// sized for the phone. Inline formatting goes through AttributedString.

enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, code: String)
    case list(ordered: Bool, items: [ListItem])
    case quote(String)
    case rule
    case table(rows: [[String]])

    struct ListItem: Hashable {
        var text: String
        var checked: Bool?
        var indent: Int
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(language: lang, code: code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).first == " " {
                    flushParagraph()
                    blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level + 1))))
                    i += 1
                    continue
                }
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, lines[i + 1].contains("---") {
                flushParagraph()
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    let cells = row.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { rows.append(Array(cells)) }
                    i += 1
                }
                blocks.append(.table(rows: rows))
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                var items = [item.item]
                let ordered = item.ordered
                i += 1
                while i < lines.count {
                    if let next = listItem(lines[i]) {
                        items.append(next.item)
                        i += 1
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].hasPrefix("  ") {
                        items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func listItem(_ line: String) -> (item: MarkdownBlock.ListItem, ordered: Bool)? {
        let indent = line.prefix(while: { $0 == " " }).count / 2
        let t = line.trimmingCharacters(in: .whitespaces)
        var body: Substring
        var ordered = false
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            body = t.dropFirst(2)
        } else if let dot = t.firstIndex(where: { $0 == "." || $0 == ")" }), t[..<dot].allSatisfy(\.isNumber),
            !t[..<dot].isEmpty, t[t.index(after: dot)...].hasPrefix(" ")
        {
            body = t[t.index(dot, offsetBy: 2)...]
            ordered = true
        } else {
            return nil
        }
        var checked: Bool?
        if body.hasPrefix("[ ] ") {
            checked = false
            body = body.dropFirst(4)
        } else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
            checked = true
            body = body.dropFirst(4)
        }
        return (.init(text: String(body), checked: checked, indent: indent), ordered)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(s)
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text))
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .paragraph(let text):
            Text(MarkdownParser.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .code(let lang, let code):
            CodeBlock(language: lang, code: code)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                            } else {
                                Text(ordered ? "\(i + 1)." : "•")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 12, alignment: .trailing)
                        Text(MarkdownParser.inline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(.quaternary).frame(width: 3)
                Text(MarkdownParser.inline(text)).foregroundStyle(.secondary)
            }
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownParser.inline(cell)).fontWeight(r == 0 ? .semibold : .regular)
                            }
                        }
                        if r == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .font(.subheadline)
                .padding(12)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct CodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize()
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if !language.isEmpty {
                Text(language).font(.caption2).foregroundStyle(.tertiary).padding(6)
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }
        }
    }
}
