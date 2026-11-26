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
    /// The header is `rows[0]`; every row has exactly `alignments.count` cells.
    case table(rows: [[String]], alignments: [ColumnAlignment])

    enum ColumnAlignment: Hashable { case leading, center, trailing }

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
            if trimmed.contains("|"), i + 1 < lines.count, var alignments = tableDelimiter(lines[i + 1]) {
                let header = tableCells(trimmed)
                // GFM wants the delimiter row to match the header exactly; while it streams in it can be short.
                if alignments.count <= header.count {
                    flushParagraph()
                    alignments += Array(repeating: .leading, count: header.count - alignments.count)
                    var rows = [header]
                    i += 2
                    while i < lines.count {
                        let row = lines[i].trimmingCharacters(in: .whitespaces)
                        guard row.contains("|"), !row.hasPrefix("```"), !row.hasPrefix("~~~") else { break }
                        let cells = tableCells(row)
                        rows.append(Array((cells + Array(repeating: "", count: max(0, header.count - cells.count))).prefix(header.count)))
                        i += 1
                    }
                    blocks.append(.table(rows: rows, alignments: alignments))
                    continue
                }
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

    /// The cells of a table row: outer pipes are optional, `\\|` is a literal pipe, and a pipe inside a code
    /// span doesn't split (agents write `a|b` far more often than they mean a column break there).
    static func tableCells(_ line: String) -> [String] {
        var row = Substring(line.trimmingCharacters(in: .whitespaces))
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row = row.dropLast() }

        func split(respectingCode: Bool) -> [String]? {
            var cells: [String] = []
            var cell = ""
            var escaped = false
            var inCode = false
            for ch in row {
                if escaped {
                    if ch != "|" { cell.append("\\") }
                    cell.append(ch)
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "`" {
                    inCode.toggle()
                    cell.append(ch)
                } else if ch == "|", !(respectingCode && inCode) {
                    cells.append(cell.trimmingCharacters(in: .whitespaces))
                    cell = ""
                } else {
                    cell.append(ch)
                }
            }
            if escaped { cell.append("\\") }
            if respectingCode, inCode { return nil }  // an unclosed backtick mustn't swallow the rest of the row
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            return cells
        }
        return split(respectingCode: true) ?? split(respectingCode: false) ?? []
    }

    /// The column alignments a delimiter row (`| :--- | :---: | ---: |`) declares, or nil if it isn't one.
    static func tableDelimiter(_ line: String) -> [MarkdownBlock.ColumnAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
        var alignments: [MarkdownBlock.ColumnAlignment] = []
        for cell in tableCells(trimmed) {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right && cell.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments
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
        VStack(alignment: .leading, spacing: compact ? 9 : 16) {
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

    private var bodySize: CGFloat { compact ? 13 : 14 }
    /// 14pt on a 24pt line (13 on 21 when compact), matching Conductor's prose rhythm.
    private var proseSpacing: CGFloat { Theme.lineSpacing(size: bodySize, lineHeight: compact ? 21 : 24) }

    private func inlineText(
        _ text: String, part: String = "", size: CGFloat, weight: NSFont.Weight = .regular, color: Color? = nil,
        lineSpacing: CGFloat = 0
    ) -> InlineText {
        InlineText(text: text, spanID: spanID.map { $0 + part }, size: size, weight: weight, color: color, lineSpacing: lineSpacing)
    }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text, size: level == 1 ? 18 : level == 2 ? 15.5 : 14.5, weight: .semibold, color: Theme.text)
                .padding(.top, compact ? 0 : 6)
        case .paragraph(let text):
            inlineText(text, size: bodySize, lineSpacing: proseSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code, spanID: spanID)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
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
                        inlineText(item.text, part: ".\(i)", size: bodySize, lineSpacing: proseSpacing)
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
        case .table(let rows, let alignments):
            TableBlockView(rows: rows, alignments: alignments, compact: compact, spanID: spanID)
        }
    }
}

/// One run of inline markdown: a selectable `SpanText` inside the transcript, plain `Text` elsewhere.
private struct InlineText: View {
    let text: String
    let spanID: String?
    let size: CGFloat
    var weight: NSFont.Weight = .regular
    var color: Color?
    var lineSpacing: CGFloat = 0

    var body: some View {
        if let spanID {
            let span = SpanText(
                id: spanID,
                text: SpanStyle.attributed(
                    MarkdownParser.inline(text), font: .systemFont(ofSize: size, weight: weight),
                    color: NSColor(color ?? Theme.text), lineSpacing: lineSpacing))
            span.spanBaseline(span)
        } else {
            Text(MarkdownParser.inline(text))
                .font(.system(size: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold))
                .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                .lineSpacing(lineSpacing)
        }
    }
}

// MARK: - Tables

/// A markdown table that fits the column it's in: columns wrap rather than run off the edge, and only when even
/// wrapped they can't fit (lots of columns) does the table scroll sideways.
private struct TableBlockView: View {
    let rows: [[String]]
    let alignments: [MarkdownBlock.ColumnAlignment]
    let compact: Bool
    let spanID: String?
    /// The width the table may use, measured outside the scroll view (which proposes no width to its content).
    @State private var available: CGFloat?
    @State private var contentWidth: CGFloat = 0

    private var overflows: Bool { contentWidth > (available ?? .infinity) + 0.5 }

    var body: some View {
        let columns = alignments.count
        let size: CGFloat = compact ? 12.5 : 13
        let spacing = Theme.lineSpacing(size: size, lineHeight: compact ? 18 : 19)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { available = $0 }
            ScrollView(.horizontal) {
                TableLayout(columns: columns, alignments: alignments, available: available) {
                    Rectangle().fill(Theme.sunken.opacity(0.7))
                        .layoutValue(key: TableSlotKey.self, value: .header)
                    ForEach(0..<rows.count * columns, id: \.self) { i in
                        let r = i / columns, c = i % columns
                        InlineText(
                            text: rows[r][c], spanID: spanID.map { "\($0).\(r).\(c)" }, size: size,
                            weight: r == 0 ? .medium : .regular, color: Theme.text, lineSpacing: spacing
                        )
                        .layoutValue(key: TableSlotKey.self, value: .cell(row: r, column: c))
                    }
                    ForEach(0..<max(rows.count - 1, 0), id: \.self) { r in
                        Rectangle().fill(r == 0 ? Theme.border : Theme.hairline)
                            .layoutValue(key: TableSlotKey.self, value: .rule(below: r))
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { contentWidth = $0 }
            }
            .scrollIndicators(overflows ? .automatic : .hidden)
            .scrollDisabled(!overflows)
            .frame(width: available.map { contentWidth > 0 ? min(contentWidth, $0) : $0 })
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 0.5))
        }
    }
}

private enum TableSlot: Equatable {
    case header
    case cell(row: Int, column: Int)
    case rule(below: Int)
}

private struct TableSlotKey: LayoutValueKey {
    static let defaultValue = TableSlot.header
}

/// Lays cells out in a grid whose columns share the width the way an HTML table's do: columns that fit at their
/// natural width keep it, the rest split what's left and wrap. Also places the header fill and row rules.
struct TableLayout: Layout {
    let columns: Int
    let alignments: [MarkdownBlock.ColumnAlignment]
    var available: CGFloat?
    var padding = CGSize(width: 12, height: 7)
    /// Below this a column stops getting narrower and the table overflows instead.
    var minimumColumn: CGFloat = 64

    private struct Geometry {
        var widths: [CGFloat]
        var heights: [CGFloat]
        var size: CGSize
    }

    private func geometry(_ subviews: Subviews, proposedWidth: CGFloat?) -> Geometry {
        var cells: [(row: Int, column: Int, view: LayoutSubview)] = []
        for view in subviews {
            if case .cell(let r, let c) = view[TableSlotKey.self] { cells.append((r, c, view)) }
        }
        let rowCount = (cells.map(\.row).max() ?? -1) + 1
        var ideal = Array(repeating: CGFloat(0), count: columns)
        for cell in cells { ideal[cell.column] = max(ideal[cell.column], cell.view.sizeThatFits(.unspecified).width) }

        let limit = (available ?? proposedWidth ?? .infinity) - CGFloat(columns) * padding.width * 2
        let widths = Self.fit(ideal, into: limit, minimum: minimumColumn)
        var heights = Array(repeating: CGFloat(0), count: rowCount)
        for cell in cells {
            let height = cell.view.sizeThatFits(ProposedViewSize(width: widths[cell.column], height: nil)).height
            heights[cell.row] = max(heights[cell.row], ceil(height))
        }
        let size = CGSize(
            width: widths.reduce(0, +) + CGFloat(columns) * padding.width * 2,
            height: heights.reduce(0, +) + CGFloat(rowCount) * padding.height * 2)
        return Geometry(widths: widths, heights: heights, size: size)
    }

    /// Water-filling: columns no wider than an even share of the room keep their natural width; the others split
    /// what remains evenly, but never below `minimum` (or their natural width, if that's narrower).
    static func fit(_ ideal: [CGFloat], into limit: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard ideal.reduce(0, +) > limit else { return ideal }
        var widths = ideal
        var open = Set(ideal.indices)
        var remaining = max(limit, 0)
        while !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            let fitting = open.filter { ideal[$0] <= share }
            if fitting.isEmpty {
                for c in open { widths[c] = share }
                break
            }
            for c in fitting {
                remaining -= ideal[c]
                open.remove(c)
            }
        }
        return widths.indices.map { max(floor(widths[$0]), min(ideal[$0], minimum)) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        geometry(subviews, proposedWidth: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let g = geometry(subviews, proposedWidth: proposal.width)
        var xs: [CGFloat] = [0], ys: [CGFloat] = [0]
        for w in g.widths { xs.append(xs.last! + w + padding.width * 2) }
        for h in g.heights { ys.append(ys.last! + h + padding.height * 2) }

        for view in subviews {
            switch view[TableSlotKey.self] {
            case .header:
                guard g.heights.count > 0 else { continue }
                view.place(
                    at: bounds.origin, proposal: ProposedViewSize(width: g.size.width, height: ys[1]))
            case .rule(let r):
                guard r + 1 < ys.count else { continue }
                view.place(
                    at: CGPoint(x: bounds.minX, y: bounds.minY + ys[r + 1]), anchor: .leading,
                    proposal: ProposedViewSize(width: g.size.width, height: 1))
            case .cell(let r, let c):
                let width = g.widths[c]
                let used = min(view.sizeThatFits(ProposedViewSize(width: width, height: nil)).width, width)
                let slack = width - used
                let offset = alignments[c] == .trailing ? slack : alignments[c] == .center ? slack / 2 : 0
                view.place(
                    at: CGPoint(x: bounds.minX + xs[c] + padding.width + offset, y: bounds.minY + ys[r] + padding.height),
                    proposal: ProposedViewSize(width: width, height: nil))
            }
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
