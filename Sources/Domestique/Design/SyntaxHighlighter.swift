import Foundation
import SwiftUI

/// Fast, hand-written, line-oriented syntax highlighter. One pass over unicode scalars per line,
/// carrying block-comment / multi-line-string state across lines. Pure and deterministic, safe off-main.
enum SyntaxHighlighter {
    enum Token { case plain, keyword, string, comment, number, type, function, attr }

    // MARK: API

    static func highlightLines(_ code: String, language: String) -> [AttributedString] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        guard let spec = specs[language] else {
            return lines.map { AttributedString(String($0)) }
        }
        var state = ScanState()
        var out: [AttributedString] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            out.append(highlight(line: line, spec: spec, state: &state))
        }
        return out
    }

    static func language(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "makefile", "gemfile", "rakefile", "podfile": return name == "dockerfile" || name == "makefile" ? "sh" : "ruby"
        case ".gitignore", ".env", ".env.local", ".npmrc": return "sh"
        default: break
        }
        switch (name as NSString).pathExtension {
        case "swift": return "swift"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts": return "ts"
        case "go": return "go"
        case "py", "pyi": return "python"
        case "rs": return "rust"
        case "rb", "rake", "gemspec": return "ruby"
        case "json", "jsonc", "json5": return "json"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "sh", "bash", "zsh", "fish": return "sh"
        case "css", "scss", "sass", "less": return "css"
        case "html", "htm", "xml", "svg", "plist", "vue", "svelte": return "html"
        case "sql": return "sql"
        case "c", "h", "m", "mm", "cpp", "cc", "hpp", "java", "kt", "kts", "cs", "dart", "scala", "gradle", "groovy", "php":
            return "c"
        case "lua": return "lua"
        default: return "plain"
        }
    }

    static func language(forFence fence: String) -> String {
        let f = fence.lowercased().trimmingCharacters(in: .whitespaces)
        switch f {
        case "swift": return "swift"
        case "ts", "tsx", "typescript", "js", "jsx", "javascript", "node": return "ts"
        case "go", "golang": return "go"
        case "py", "python": return "python"
        case "rs", "rust": return "rust"
        case "rb", "ruby": return "ruby"
        case "json", "jsonc": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "sh", "bash", "zsh", "shell", "console", "shellscript": return "sh"
        case "css", "scss": return "css"
        case "html", "xml", "svg": return "html"
        case "sql", "postgres", "postgresql": return "sql"
        case "c", "cpp", "c++", "java", "kotlin", "objc", "csharp", "cs", "php": return "c"
        case "lua": return "lua"
        default: return language(forPath: "x.\(f)")
        }
    }

    // MARK: Language specs

    struct Spec {
        var keywords: Set<String> = []
        var caseInsensitive = false
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)? = nil
        var quotes: Set<Unicode.Scalar> = ["\"", "'"]
        /// Delimiters that may span lines (backtick template literals, triple quotes).
        var multiline: [String] = []
        var dollarVars = false
        var atAttributes = false
        /// Keys before ":" (json/yaml/css) or "=" (toml/html attrs) get the attr colour.
        var keyBeforeColon = false
        var keyBeforeEquals = false
        var tags = false
        var capitalizedTypes = true
    }

    private static let cFamilyComments: (open: String, close: String) = ("/*", "*/")

    static let specs: [String: Spec] = {
        var s: [String: Spec] = [:]
        s["swift"] = Spec(
            keywords: words("""
                let var func if else guard return import struct class enum protocol extension case switch default for in \
                while repeat break continue throw throws rethrows try catch async await actor static private public internal \
                fileprivate open init deinit self Self nil true false some any where as is inout mutating nonmutating \
                nonisolated defer do typealias associatedtype override final lazy weak unowned get set willSet didSet super \
                subscript operator convenience required indirect isolated sending consuming borrowing package macro
                """),
            lineComments: ["//"], blockComment: cFamilyComments, quotes: ["\""], multiline: ["\"\"\""], atAttributes: true)
        s["ts"] = Spec(
            keywords: words("""
                const let var function return if else for while do switch case default break continue new this class \
                extends import from export as async await try catch finally throw typeof instanceof in of null undefined \
                true false void delete yield interface type enum implements private public protected readonly static \
                abstract declare namespace keyof satisfies super get set
                """),
            lineComments: ["//"], blockComment: cFamilyComments, quotes: ["\"", "'"], multiline: ["`"], dollarVars: false,
            atAttributes: true, keyBeforeEquals: true, tags: true)
        s["go"] = Spec(
            keywords: words("""
                func package import var const type struct interface map chan go defer return if else for range switch case \
                default break continue fallthrough select nil true false make new len cap append error string int int64 \
                int32 uint float64 bool byte rune any
                """),
            lineComments: ["//"], blockComment: cFamilyComments, quotes: ["\"", "'"], multiline: ["`"])
        s["python"] = Spec(
            keywords: words("""
                def class return if elif else for while in not and or is None True False import from as with try except \
                finally raise pass break continue lambda yield global nonlocal async await self assert del match case
                """),
            lineComments: ["#"], quotes: ["\"", "'"], multiline: ["\"\"\"", "'''"], atAttributes: true)
        s["rust"] = Spec(
            keywords: words("""
                fn let mut pub struct enum impl trait use mod crate self Self super match if else loop while for in return \
                break continue as where move ref static const unsafe async await dyn type true false Some None Ok Err
                """),
            lineComments: ["//"], blockComment: cFamilyComments, quotes: ["\""])
        s["ruby"] = Spec(
            keywords: words("""
                def end class module if elsif else unless while until for in do return yield self nil true false require \
                require_relative begin rescue ensure raise then case when and or not attr_accessor attr_reader puts private
                """),
            lineComments: ["#"], quotes: ["\"", "'"], atAttributes: false)
        s["sh"] = Spec(
            keywords: words("""
                if then else elif fi for while do done case esac in function return export local echo exit set unset source \
                cd until shift trap eval exec readonly declare
                """),
            lineComments: ["#"], quotes: ["\"", "'"], multiline: [], dollarVars: true, capitalizedTypes: false)
        s["json"] = Spec(
            keywords: ["true", "false", "null"], lineComments: ["//"], quotes: ["\""], keyBeforeColon: true,
            capitalizedTypes: false)
        s["yaml"] = Spec(
            keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"], quotes: ["\"", "'"],
            keyBeforeColon: true, capitalizedTypes: false)
        s["toml"] = Spec(
            keywords: ["true", "false"], lineComments: ["#"], quotes: ["\"", "'"], multiline: ["\"\"\"", "'''"],
            keyBeforeEquals: true, capitalizedTypes: false)
        s["css"] = Spec(
            keywords: words("important media import from to and not only supports keyframes font-face"),
            blockComment: cFamilyComments, quotes: ["\"", "'"], atAttributes: true, keyBeforeColon: true,
            capitalizedTypes: false)
        s["html"] = Spec(
            keywords: [], blockComment: ("<!--", "-->"), quotes: ["\"", "'"], keyBeforeEquals: true, tags: true,
            capitalizedTypes: false)
        s["sql"] = Spec(
            keywords: words("""
                select from where insert into values update set delete create table alter drop index join left right inner \
                outer on and or not null as order by group having limit offset distinct primary key foreign references \
                default unique begin commit returning with case when then else end is in exists like asc desc union all \
                view trigger function returns language int integer text varchar boolean timestamp serial bigint
                """),
            caseInsensitive: true, lineComments: ["--"], blockComment: cFamilyComments, quotes: ["'", "\""],
            capitalizedTypes: false)
        s["c"] = Spec(
            keywords: words("""
                auto break case char const continue default do double else enum extern float for goto if inline int long \
                register return short signed sizeof static struct switch typedef union unsigned void volatile while class \
                public private protected new delete this namespace using template typename virtual override final bool \
                true false null nullptr import package interface extends implements throws throw try catch finally fun val \
                var when is object companion data suspend let self super nil
                """),
            lineComments: ["//"], blockComment: cFamilyComments, quotes: ["\"", "'"], atAttributes: true)
        s["lua"] = Spec(
            keywords: words("and break do else elseif end false for function if in local nil not or repeat return then true until while"),
            lineComments: ["--"], quotes: ["\"", "'"])
        return s
    }()

    private static func words(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    // MARK: Scanner

    struct ScanState {
        /// Inside a block comment that started on an earlier line.
        var inBlockComment = false
        /// Inside a multi-line string with this closing delimiter.
        var openString: String? = nil
    }

    private static func color(_ t: Token) -> Color? {
        switch t {
        case .plain: nil
        case .keyword: Theme.synKeyword
        case .string: Theme.synString
        case .comment: Theme.synComment
        case .number: Theme.synNumber
        case .type: Theme.synType
        case .function: Theme.synFunction
        case .attr: Theme.synAttr
        }
    }

    private static func isIdentStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_" || (c.value > 127 && c.properties.isAlphabetic)
    }

    private static func isIdent(_ c: Unicode.Scalar, dashes: Bool) -> Bool {
        isIdentStart(c) || (c >= "0" && c <= "9") || c == "$" || (dashes && c == "-")
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    private static func matches(_ s: [Unicode.Scalar], _ i: Int, _ token: [Unicode.Scalar]) -> Bool {
        guard i + token.count <= s.count else { return false }
        for k in 0..<token.count where s[i + k] != token[k] { return false }
        return true
    }

    private static func highlight(line: Substring, spec: Spec, state: inout ScanState) -> AttributedString {
        let s = Array(line.unicodeScalars)
        let n = s.count
        var out = AttributedString()
        var pendingStart = 0  // start of pending plain run
        var i = 0

        func flushPlain(upTo end: Int) {
            guard end > pendingStart else { return }
            out.append(AttributedString(String(String.UnicodeScalarView(s[pendingStart..<end]))))
        }
        func emit(_ a: Int, _ b: Int, _ t: Token) {
            flushPlain(upTo: a)
            var piece = AttributedString(String(String.UnicodeScalarView(s[a..<b])))
            if let c = color(t) { piece.foregroundColor = c }
            out.append(piece)
            pendingStart = b
        }

        let blockOpen = spec.blockComment.map { Array($0.open.unicodeScalars) }
        let blockClose = spec.blockComment.map { Array($0.close.unicodeScalars) }
        let lineComments = spec.lineComments.map { Array($0.unicodeScalars) }
        let multis = spec.multiline.map { Array($0.unicodeScalars) }
        let dashes = spec.keyBeforeColon && spec.capitalizedTypes == false  // css/yaml keys may contain '-'
        var lastSignificant: Unicode.Scalar? = nil
        var lineStartKey = true  // yaml/toml: still at the key position of the line
        var inTag = false  // jsx/html: between "<Name" and ">"

        // Continue an open block comment / multi-line string.
        if state.inBlockComment, let close = blockClose {
            var j = 0
            while j < n, !matches(s, j, close) { j += 1 }
            if j < n {
                emit(0, j + close.count, .comment)
                i = j + close.count
                state.inBlockComment = false
            } else {
                emit(0, n, .comment)
                return out
            }
        } else if let close = state.openString {
            let c = Array(close.unicodeScalars)
            var j = 0
            while j < n, !matches(s, j, c) {
                if s[j] == "\\" { j += 1 }
                j += 1
            }
            if j < n {
                emit(0, min(n, j + c.count), .string)
                i = j + c.count
                state.openString = nil
            } else {
                emit(0, n, .string)
                return out
            }
        }

        while i < n {
            let c = s[i]

            // Whitespace
            if c == " " || c == "\t" {
                i += 1
                continue
            }

            // Comments
            if let open = blockOpen, matches(s, i, open), let close = blockClose {
                var j = i + open.count
                while j < n, !matches(s, j, close) { j += 1 }
                if j < n {
                    emit(i, j + close.count, .comment)
                    i = j + close.count
                } else {
                    emit(i, n, .comment)
                    state.inBlockComment = true
                    return out
                }
                continue
            }
            if lineComments.contains(where: { matches(s, i, $0) }) {
                // '#' in css/shell after a non-space char (e.g. url#frag, $#) isn't a comment in practice.
                if c == "#", spec.dollarVars, i > 0, s[i - 1] != " ", s[i - 1] != "\t" {
                    // fallthrough to plain
                } else {
                    emit(i, n, .comment)
                    return out
                }
            }

            // Multi-line string delimiters (``` ` ```, """)
            if let m = multis.first(where: { matches(s, i, $0) }) {
                var j = i + m.count
                while j < n, !matches(s, j, m) {
                    if s[j] == "\\" { j += 1 }
                    j += 1
                }
                if j < n {
                    emit(i, min(n, j + m.count), .string)
                    i = j + m.count
                } else {
                    emit(i, n, .string)
                    state.openString = String(String.UnicodeScalarView(m))
                    return out
                }
                lastSignificant = "\""
                lineStartKey = false
                continue
            }

            // Strings
            if spec.quotes.contains(c) {
                var j = i + 1
                while j < n, s[j] != c {
                    if s[j] == "\\" { j += 1 }
                    j += 1
                }
                let end = min(n, j + 1)
                var token: Token = .string
                if spec.keyBeforeColon {
                    var k = end
                    while k < n, s[k] == " " { k += 1 }
                    if k < n, s[k] == ":" { token = .attr }
                }
                emit(i, end, token)
                i = end
                lastSignificant = "\""
                lineStartKey = false
                continue
            }

            // Numbers
            if isDigit(c) || (c == "." && i + 1 < n && isDigit(s[i + 1]) && !(lastSignificant.map { isIdent($0, dashes: false) } ?? false)) {
                var j = i + 1
                while j < n, isIdent(s[j], dashes: false) || s[j] == "." {
                    if s[j] == ".", j + 1 < n, s[j + 1] == "." { break }
                    j += 1
                }
                emit(i, j, .number)
                i = j
                lastSignificant = "0"
                lineStartKey = false
                continue
            }

            // $VAR / ${VAR}
            if spec.dollarVars, c == "$", i + 1 < n {
                var j = i + 1
                if s[j] == "{" {
                    while j < n, s[j] != "}" { j += 1 }
                    j = min(n, j + 1)
                } else {
                    while j < n, isIdent(s[j], dashes: false) { j += 1 }
                }
                if j > i + 1 {
                    emit(i, j, .attr)
                    i = j
                    lastSignificant = "a"
                    continue
                }
            }

            // @attributes / decorators
            if spec.atAttributes, c == "@", i + 1 < n, isIdentStart(s[i + 1]) {
                var j = i + 1
                while j < n, isIdent(s[j], dashes: false) || s[j] == "." { j += 1 }
                emit(i, j, .attr)
                i = j
                lastSignificant = "a"
                continue
            }

            // Identifiers
            if isIdentStart(c) || (dashes && c == "-" && i + 1 < n && isIdentStart(s[i + 1]) && lineStartKey) {
                var j = i + 1
                while j < n, isIdent(s[j], dashes: dashes) { j += 1 }
                let word = String(String.UnicodeScalarView(s[i..<j]))
                var k = j
                while k < n, s[k] == " " { k += 1 }
                let next: Unicode.Scalar? = k < n ? s[k] : nil
                let afterTagOpen = spec.tags && (lastSignificant == "<" || (lastSignificant == "/" && i >= 2 && s[i - 2] == "<"))

                var token: Token = .plain
                if afterTagOpen {
                    token = isUpper(s[i]) ? .type : .keyword
                    inTag = true
                } else if spec.keyBeforeColon && next == ":" && (lineStartKey || spec.specsJSONLike) {
                    token = .attr
                } else if spec.keyBeforeEquals && next == "=" && (k + 1 >= n || s[k + 1] != "=")
                    && (spec.tags ? inTag : lineStartKey)
                {
                    token = .attr
                } else if spec.keywords.contains(spec.caseInsensitive ? word.lowercased() : word) {
                    token = .keyword
                } else if next == "(" {
                    token = .function
                } else if spec.capitalizedTypes, isUpper(s[i]) {
                    token = .type
                }
                if token == .plain {
                    i = j
                } else {
                    emit(i, j, token)
                    i = j
                }
                lastSignificant = "a"
                lineStartKey = false
                continue
            }

            // TOML [section] headers
            if spec.keyBeforeEquals, !spec.tags, c == "[", lineStartKey {
                var j = i
                while j < n, s[j] != "]" { j += 1 }
                emit(i, min(n, j + 1), .type)
                i = min(n, j + 1)
                lineStartKey = false
                continue
            }

            // Punctuation
            if c == "-" && lineStartKey && spec.keyBeforeColon {
                // yaml list item "- key: value": key position continues
            } else if c != "/" || !spec.tags {
                lineStartKey = false
            }
            if c == ">" { inTag = false }
            lastSignificant = c
            i += 1
        }
        flushPlain(upTo: n)
        return out
    }

    private static func isUpper(_ c: Unicode.Scalar) -> Bool { c >= "A" && c <= "Z" }
}

private extension SyntaxHighlighter.Spec {
    /// JSON/CSS keys appear mid-line (`{"a": 1, "b": 2}`, `a { color: red }`), YAML keys only at line start.
    var specsJSONLike: Bool { keyBeforeColon && !lineComments.contains("#") }
}
