import Foundation

/// One environment variable a project's sandboxes start with.
public struct EnvVariable: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var value: String
    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Reads `.env` files, with the conventions of the common dotenv libraries: comments, an optional
/// `export`, single, double and backtick quotes (quoted values can span lines), and `\n`-style escapes in
/// double quotes. `$VAR` is left as written. Lines that aren't assignments are skipped.
public enum DotEnv {
    public static func parse(_ text: String) -> [EnvVariable] {
        // "\r\n" is one Character in Swift, so it wouldn't match "\n" below.
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var out: [EnvVariable] = []
        var i = 0

        func skipLine() {
            while i < chars.count, chars[i] != "\n" { i += 1 }
        }

        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { break }
            if chars[i] == "#" {
                skipLine()
                continue
            }
            let start = i
            while i < chars.count, chars[i] != "=", chars[i] != "\n" { i += 1 }
            guard i < chars.count, chars[i] == "=", let key = parseKey(String(chars[start..<i])) else {
                skipLine()
                continue
            }
            i += 1
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            let value: String
            if i < chars.count, "'\"`".contains(chars[i]), let (text, end) = parseQuoted(chars, from: i) {
                value = text
                i = end
                skipLine()
            } else {
                let begin = i
                skipLine()
                value = parseUnquoted(chars[begin..<i])
            }
            if let existing = out.firstIndex(where: { $0.key == key }) {
                out[existing].value = value
            } else {
                out.append(EnvVariable(key: key, value: value))
            }
        }
        return out
    }

    /// The contents of a shell file that exports `variables`.
    public static func shellScript(_ variables: [EnvVariable]) -> String {
        let env = Dictionary(variables.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        return "# Written by Domestique: this project's environment variables.\n" + ShellQuote.exports(env) + "\n"
    }

    private static func parseKey(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "^export[ \\t]+", options: .regularExpression) { s.removeSubrange(r) }
        return s.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil ? s : nil
    }

    /// The value of the quote starting at `start` and the index after it; nil if it's never closed.
    private static func parseQuoted(_ chars: [Character], from start: Int) -> (String, Int)? {
        let mark = chars[start]
        var value = ""
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            if c == mark { return (value, i + 1) }
            if mark == "\"", c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                switch next {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "\"", "\\": value.append(next)
                default: value.append(c); value.append(next)
                }
                i += 2
                continue
            }
            value.append(c)
            i += 1
        }
        return nil
    }

    /// Everything up to a ` #` comment, trimmed. A `#` inside a word is part of the value.
    private static func parseUnquoted(_ chars: ArraySlice<Character>) -> String {
        var end = chars.endIndex
        for i in chars.indices where chars[i] == "#" && i > chars.startIndex && chars[i - 1].isWhitespace {
            end = i
            break
        }
        return String(chars[chars.startIndex..<end]).trimmingCharacters(in: .whitespaces)
    }
}
