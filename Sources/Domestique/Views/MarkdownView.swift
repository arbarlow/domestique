import SwiftUI

/// Small, fast block-level markdown renderer. Inline formatting goes through AttributedString.
/// Streaming-friendly: parsing is cheap and an unterminated code fence renders as code.
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
    var compact = false
    /// Joins the transcript-wide selection under this ID; otherwise each block selects on its own.
    var spanID: String?

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: compact ? 6 : 11) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { b, block in
                BlockView(block: block, compact: compact, spanID: spanID.map { "\($0)#\(b)" })
            }
        }
        .textSelection(.enabled)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let compact: Bool
    let spanID: String?

    private var bodySize: CGFloat { compact ? 13 : 13.5 }

    @ViewBuilder
    private func inlineText(
        _ text: String, part: String = "", size: CGFloat, weight: NSFont.Weight = .regular, color: Color? = nil,
        lineSpacing: CGFloat = 0
    ) -> some View {
        if let spanID {
            SpanText(
                id: spanID + part,
                text: SpanStyle.attributed(
                    MarkdownParser.inline(text), font: .systemFont(ofSize: size, weight: weight),
                    color: NSColor(color ?? Theme.text), lineSpacing: lineSpacing))
        } else {
            Text(MarkdownParser.inline(text))
                .font(.system(size: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold))
                .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                .lineSpacing(lineSpacing)
        }
    }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text, size: level == 1 ? 19 : level == 2 ? 16 : 14, weight: .semibold, color: Theme.text)
                .padding(.top, compact ? 0 : 6)
        case .paragraph(let text):
            inlineText(text, size: bodySize, lineSpacing: 3.5)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code, spanID: spanID)
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
                        .foregroundStyle(Theme.text2)
                        .frame(minWidth: 12, alignment: .trailing)
                        inlineText(item.text, part: ".\(i)", size: bodySize, lineSpacing: 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: bodySize))
                    .padding(.leading, CGFloat(item.indent) * 18 + 4)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.border).frame(width: 3)
                inlineText(text, size: bodySize, color: Theme.text2)
            }
        case .rule:
            Hairline().padding(.vertical, 4)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                                inlineText(cell, part: ".\(r).\(c)", size: 13, weight: r == 0 ? .medium : .regular, color: Theme.text)
                            }
                        }
                        if r == 0 { Hairline().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(12)
            }
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 0.5))
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    var spanID: String?
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if let spanID {
                        SpanText(id: spanID, text: joinedLines, wraps: false)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(highlighted.enumerated()), id: \.offset) { _, line in
                                Text(line).font(Theme.mono).fixedSize()
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            HStack(spacing: 6) {
                if !language.isEmpty {
                    Text(language).font(Theme.small).foregroundStyle(Theme.text3)
                }
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy", size: 11) {
                    copy(code)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                }
            }
            .padding(4)
            .opacity(hovering ? 1 : 0)
        }
        .background(Theme.sunken.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        .onHover { hovering = $0 }
    }

    private var highlighted: [AttributedString] {
        CodeHighlight.lines(code, language: language)
    }

    private var joinedLines: NSAttributedString {
        var joined = AttributedString()
        for (i, line) in highlighted.enumerated() {
            if i > 0 { joined.append(AttributedString("\n")) }
            joined.append(line)
        }
        return SpanStyle.attributed(joined, font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: NSColor(Theme.text))
    }
}
