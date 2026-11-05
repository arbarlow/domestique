import Foundation

/// A TOML value with tables that remember insertion order.
public indirect enum TOMLValue: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table(TOMLTable)

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var integer: Int? { if case .integer(let i) = self { i } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [TOMLValue]? { if case .array(let a) = self { a } else { nil } }
    public var table: TOMLTable? { if case .table(let t) = self { t } else { nil } }

    public var json: JSONValue {
        switch self {
        case .string(let s): .string(s)
        case .integer(let i): .number(Double(i))
        case .float(let d): .number(d)
        case .bool(let b): .bool(b)
        case .array(let a): .array(a.map(\.json))
        case .table(let t): t.json
        }
    }
}

/// Ordered key/value table.
public struct TOMLTable: Sendable, Hashable {
    public private(set) var keys: [String] = []
    public private(set) var values: [String: TOMLValue] = [:]

    public init() {}

    public subscript(key: String) -> TOMLValue? {
        get { values[key] }
        set {
            if let newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    /// Entries in insertion order.
    public var entries: [(key: String, value: TOMLValue)] { keys.map { ($0, values[$0]!) } }

    public var json: JSONValue { .object(values.mapValues(\.json)) }
}

public struct TOMLError: Error, LocalizedError, Sendable, Hashable {
    public var line: Int
    public var message: String
    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
    public var errorDescription: String? { "TOML error on line \(line): \(message)" }
}

/// Parser for the subset of TOML that config files need (everything except dates are typed;
/// dates/times are kept as strings).
public enum TOML {
    public static func parse(_ text: String) throws -> JSONValue {
        try parseTable(text).json
    }

    public static func parseTable(_ text: String) throws -> TOMLTable {
        var parser = Parser(text)
        return try parser.parseDocument()
    }
}

// MARK: - Implementation

/// Mutable tree used while parsing (reference semantics make header navigation easy).
private final class Node {
    enum Kind { case table, arrayOfTables, value }
    var keys: [String] = []
    var children: [String: Node] = [:]
    /// For `.value`.
    var value: TOMLValue?
    /// For `.arrayOfTables`.
    var elements: [Node] = []
    let kind: Kind
    /// Explicitly defined via [header] or key/value (not just implied by a dotted path).
    var defined = false

    init(_ kind: Kind) { self.kind = kind }

    func child(_ key: String) -> Node? { children[key] }

    func set(_ key: String, _ node: Node) {
        if children[key] == nil { keys.append(key) }
        children[key] = node
    }

    func toTable() -> TOMLTable {
        var t = TOMLTable()
        for k in keys {
            guard let c = children[k] else { continue }
            t[k] = c.toValue()
        }
        return t
    }

    func toValue() -> TOMLValue {
        switch kind {
        case .value: value ?? .string("")
        case .table: .table(toTable())
        case .arrayOfTables: .array(elements.map { .table($0.toTable()) })
        }
    }
}

private struct Parser {
    let chars: [Character]
    var i = 0
    var line = 1

    init(_ text: String) {
        // Normalise CRLF so "\r\n" is a single newline grapheme we can treat uniformly.
        chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    var atEnd: Bool { i >= chars.count }
    var peek: Character? { i < chars.count ? chars[i] : nil }

    func peek(_ offset: Int) -> Character? {
        let j = i + offset
        return j < chars.count ? chars[j] : nil
    }

    func error(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

    mutating func advance() {
        if chars[i] == "\n" { line += 1 }
        i += 1
    }

    mutating func skipSpaces() {
        while let c = peek, c == " " || c == "\t" { advance() }
    }

    mutating func skipComment() {
        if peek == "#" { while let c = peek, c != "\n" { advance() } }
    }

    /// Skips whitespace, newlines and comments.
    mutating func skipTrivia() {
        while let c = peek {
            if c == " " || c == "\t" || c == "\n" {
                advance()
            } else if c == "#" {
                skipComment()
            } else {
                break
            }
        }
    }

    mutating func expectLineEnd() throws {
        skipSpaces()
        skipComment()
        if let c = peek, c != "\n" { throw error("Unexpected '\(c)' after value") }
    }

    func starts(with s: String) -> Bool {
        var j = i
        for c in s {
            guard j < chars.count, chars[j] == c else { return false }
            j += 1
        }
        return true
    }

    // MARK: document

    mutating func parseDocument() throws -> TOMLTable {
        let root = Node(.table)
        var current = root
        while true {
            skipTrivia()
            guard let c = peek else { break }
            if c == "[" {
                if peek(1) == "[" {
                    advance()
                    advance()
                    skipSpaces()
                    let path = try parseKeyPath()
                    skipSpaces()
                    guard peek == "]", peek(1) == "]" else { throw error("Expected ']]'") }
                    advance()
                    advance()
                    try expectLineEnd()
                    current = try appendArrayTable(root, path)
                } else {
                    advance()
                    skipSpaces()
                    let path = try parseKeyPath()
                    skipSpaces()
                    guard peek == "]" else { throw error("Expected ']'") }
                    advance()
                    try expectLineEnd()
                    current = try openTable(root, path)
                }
            } else {
                try parseKeyValue(into: current)
                try expectLineEnd()
            }
        }
        return root.toTable()
    }

    /// Walks/creates intermediate tables; array-of-tables resolve to their last element.
    mutating func descend(_ start: Node, _ path: ArraySlice<String>) throws -> Node {
        var node = start
        for key in path {
            if let existing = node.child(key) {
                switch existing.kind {
                case .table: node = existing
                case .arrayOfTables:
                    guard let last = existing.elements.last else { throw error("Empty array of tables '\(key)'") }
                    node = last
                case .value: throw error("Key '\(key)' is already a value, not a table")
                }
            } else {
                let t = Node(.table)
                node.set(key, t)
                node = t
            }
        }
        return node
    }

    mutating func openTable(_ root: Node, _ path: [String]) throws -> Node {
        let parent = try descend(root, path.dropLast())
        let key = path.last!
        if let existing = parent.child(key) {
            switch existing.kind {
            case .table:
                existing.defined = true
                return existing
            case .arrayOfTables:
                guard let last = existing.elements.last else { throw error("Empty array of tables '\(key)'") }
                return last
            case .value:
                throw error("Key '\(key)' is already a value, not a table")
            }
        }
        let t = Node(.table)
        t.defined = true
        parent.set(key, t)
        return t
    }

    mutating func appendArrayTable(_ root: Node, _ path: [String]) throws -> Node {
        let parent = try descend(root, path.dropLast())
        let key = path.last!
        let arr: Node
        if let existing = parent.child(key) {
            guard existing.kind == .arrayOfTables else { throw error("Key '\(key)' is not an array of tables") }
            arr = existing
        } else {
            arr = Node(.arrayOfTables)
            parent.set(key, arr)
        }
        let element = Node(.table)
        arr.elements.append(element)
        return element
    }

    // MARK: keys

    mutating func parseKeyPath() throws -> [String] {
        var parts = [try parseSimpleKey()]
        while true {
            skipSpaces()
            guard peek == "." else { break }
            advance()
            skipSpaces()
            parts.append(try parseSimpleKey())
        }
        return parts
    }

    mutating func parseSimpleKey() throws -> String {
        guard let c = peek else { throw error("Expected key") }
        if c == "\"" {
            advance()
            return try parseBasicString()
        }
        if c == "'" {
            advance()
            return try parseLiteralString()
        }
        var s = ""
        while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" {
            s.append(c)
            advance()
        }
        if s.isEmpty { throw error("Expected key, found '\(c)'") }
        return s
    }

    mutating func parseKeyValue(into table: Node) throws {
        let path = try parseKeyPath()
        skipSpaces()
        guard peek == "=" else { throw error("Expected '=' after key '\(path.joined(separator: "."))'") }
        advance()
        skipSpaces()
        let value = try parseValue()
        let parent = try descend(table, path.dropLast())
        let leaf = Node(.value)
        leaf.value = value
        leaf.defined = true
        parent.set(path.last!, leaf)
    }

    // MARK: values

    mutating func parseValue() throws -> TOMLValue {
        guard let c = peek else { throw error("Expected value") }
        switch c {
        case "\"":
            if starts(with: "\"\"\"") {
                i += 3
                return .string(try parseMultilineBasic())
            }
            advance()
            return .string(try parseBasicString())
        case "'":
            if starts(with: "'''") {
                i += 3
                return .string(try parseMultilineLiteral())
            }
            advance()
            return .string(try parseLiteralString())
        case "[":
            advance()
            return try parseArray()
        case "{":
            advance()
            return try parseInlineTable()
        default:
            return try parseBare()
        }
    }

    mutating func parseBasicString() throws -> String {
        var s = ""
        while true {
            guard let c = peek else { throw error("Unterminated string") }
            if c == "\n" { throw error("Newline in single-line string") }
            advance()
            if c == "\"" { return s }
            if c == "\\" { s += try parseEscape() } else { s.append(c) }
        }
    }

    mutating func parseEscape() throws -> String {
        guard let e = peek else { throw error("Unterminated escape") }
        advance()
        switch e {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "e": return "\u{1B}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u", "U":
            let n = e == "u" ? 4 : 8
            var hex = ""
            for _ in 0..<n {
                guard let h = peek else { throw error("Bad unicode escape") }
                hex.append(h)
                advance()
            }
            guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else {
                throw error("Bad unicode escape \\\(e)\(hex)")
            }
            return String(Character(scalar))
        default:
            throw error("Unknown escape \\\(e)")
        }
    }

    mutating func parseLiteralString() throws -> String {
        var s = ""
        while true {
            guard let c = peek else { throw error("Unterminated string") }
            if c == "\n" { throw error("Newline in single-line string") }
            advance()
            if c == "'" { return s }
            s.append(c)
        }
    }

    mutating func parseMultilineBasic() throws -> String {
        if peek == "\n" { advance() }
        var s = ""
        while true {
            guard let c = peek else { throw error("Unterminated multi-line string") }
            if starts(with: "\"\"\"") {
                i += 3
                // Up to two extra quotes may belong to the content.
                while peek == "\"" {
                    s.append("\"")
                    advance()
                }
                return s
            }
            advance()
            if c == "\\" {
                // Line-ending backslash trims the newline and following whitespace.
                if let n = peek, n == " " || n == "\t" || n == "\n" {
                    var j = i
                    while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                    if j < chars.count, chars[j] == "\n" {
                        while let w = peek, w == " " || w == "\t" || w == "\n" { advance() }
                        continue
                    }
                }
                s += try parseEscape()
            } else {
                s.append(c)
            }
        }
    }

    mutating func parseMultilineLiteral() throws -> String {
        if peek == "\n" { advance() }
        var s = ""
        while true {
            guard let c = peek else { throw error("Unterminated multi-line string") }
            if starts(with: "'''") {
                i += 3
                while peek == "'" {
                    s.append("'")
                    advance()
                }
                return s
            }
            advance()
            s.append(c)
        }
    }

    mutating func parseArray() throws -> TOMLValue {
        var items: [TOMLValue] = []
        while true {
            skipTrivia()
            guard let c = peek else { throw error("Unterminated array") }
            if c == "]" {
                advance()
                return .array(items)
            }
            items.append(try parseValue())
            skipTrivia()
            if peek == "," {
                advance()
            } else if peek == "]" {
                advance()
                return .array(items)
            } else {
                throw error("Expected ',' or ']' in array")
            }
        }
    }

    mutating func parseInlineTable() throws -> TOMLValue {
        let node = Node(.table)
        skipTrivia()
        if peek == "}" {
            advance()
            return .table(node.toTable())
        }
        while true {
            skipTrivia()
            try parseKeyValue(into: node)
            skipTrivia()
            guard let c = peek else { throw error("Unterminated inline table") }
            advance()
            if c == "}" { return .table(node.toTable()) }
            if c != "," { throw error("Expected ',' or '}' in inline table") }
            skipTrivia()
            // Trailing comma (lenient).
            if peek == "}" {
                advance()
                return .table(node.toTable())
            }
        }
    }

    mutating func parseBare() throws -> TOMLValue {
        var token = ""
        while let c = peek, !(c == "," || c == "]" || c == "}" || c == "\n" || c == "#" || c == " " || c == "\t") {
            token.append(c)
            advance()
        }
        // Dates with a space separator: "1979-05-27 07:32:00".
        if token.count == 10, token.filter({ $0 == "-" }).count == 2, peek == " ", let d = peek(1), d.isNumber {
            advance()
            while let c = peek, !(c == "," || c == "]" || c == "}" || c == "\n" || c == "#" || c == " ") {
                token.append(c)
                advance()
            }
        }
        if token.isEmpty { throw error("Expected value") }
        switch token {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        let clean = token.replacingOccurrences(of: "_", with: "")
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where clean.hasPrefix(prefix) {
            if let v = Int(clean.dropFirst(2), radix: radix) { return .integer(v) }
            throw error("Invalid number '\(token)'")
        }
        if let v = Int(clean) { return .integer(v) }
        let looksNumeric = clean.first.map { $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." } ?? false
        if looksNumeric, clean.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), !clean.contains(":"),
            let d = Double(clean)
        {
            return .float(d)
        }
        // Dates / times: keep as strings.
        if let f = token.first, f.isNumber, token.contains("-") || token.contains(":") {
            return .string(token)
        }
        throw error("Invalid value '\(token)'")
    }
}
