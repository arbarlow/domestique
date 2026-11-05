import Foundation

/// Parses `git diff` unified output (with `diff --git` headers) into structured file diffs.
public enum UnifiedDiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var builder: FileBuilder?
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if let h = hunk { builder?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let b = builder { files.append(b.build()) }
            builder = nil
        }

        // Split on "\n" but keep content exactly (no trimming of "\r" inside lines beyond a trailing one).
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        for raw in lines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw

            if line.hasPrefix("diff --git ") {
                flushFile()
                builder = FileBuilder(header: String(line.dropFirst("diff --git ".count)))
                continue
            }
            guard var b = builder else { continue }
            defer { builder = b }

            if hunk != nil {
                // Inside a hunk: content lines.
                if let first = line.first {
                    switch first {
                    case " ":
                        hunk!.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldLine: oldLine, newLine: newLine))
                        oldLine += 1
                        newLine += 1
                        continue
                    case "+":
                        hunk!.lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldLine: nil, newLine: newLine))
                        newLine += 1
                        b.additions += 1
                        continue
                    case "-":
                        hunk!.lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldLine: oldLine, newLine: nil))
                        oldLine += 1
                        b.deletions += 1
                        continue
                    case "\\":
                        hunk!.lines.append(DiffLine(kind: .noNewline, text: String(line.dropFirst(2))))
                        continue
                    default:
                        break
                    }
                } else {
                    // Empty line inside a hunk: some tools strip the leading space of blank context lines.
                    hunk!.lines.append(DiffLine(kind: .context, text: "", oldLine: oldLine, newLine: newLine))
                    oldLine += 1
                    newLine += 1
                    continue
                }
            }

            if line.hasPrefix("@@") {
                flushHunk()
                if let parsed = parseHunkHeader(line) {
                    hunk = parsed
                    oldLine = parsed.oldStart
                    newLine = parsed.newStart
                }
                continue
            }

            if line.hasPrefix("new file mode") {
                b.isNew = true
            } else if line.hasPrefix("deleted file mode") {
                b.isDeleted = true
            } else if line.hasPrefix("rename from ") {
                b.renameFrom = unquote(String(line.dropFirst("rename from ".count)))
            } else if line.hasPrefix("rename to ") {
                b.renameTo = unquote(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("copy from ") {
                b.renameFrom = unquote(String(line.dropFirst("copy from ".count)))
            } else if line.hasPrefix("copy to ") {
                b.renameTo = unquote(String(line.dropFirst("copy to ".count)))
            } else if line.hasPrefix("--- ") {
                b.minusPath = stripPrefix(unquote(String(line.dropFirst(4))))
            } else if line.hasPrefix("+++ ") {
                b.plusPath = stripPrefix(unquote(String(line.dropFirst(4))))
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                b.isBinary = true
            }
        }
        flushFile()
        return files
    }

    // MARK: helpers

    private struct FileBuilder {
        var header: String
        var isNew = false
        var isDeleted = false
        var isBinary = false
        var renameFrom: String?
        var renameTo: String?
        var minusPath: String?
        var plusPath: String?
        var additions = 0
        var deletions = 0
        var hunks: [DiffHunk] = []

        func build() -> FileDiff {
            let headerPaths = UnifiedDiffParser.parseGitHeader(header)
            let newPath = renameTo ?? nonNull(plusPath) ?? headerPaths.b ?? nonNull(minusPath) ?? headerPaths.a ?? header
            let oldPathCandidate = renameFrom ?? nonNull(minusPath) ?? headerPaths.a
            let status: FileStatus.Kind
            if isNew || minusPath == "/dev/null" {
                status = .added
            } else if isDeleted || plusPath == "/dev/null" {
                status = .deleted
            } else if renameFrom != nil, renameTo != nil, renameFrom != renameTo {
                status = .renamed
            } else {
                status = .modified
            }
            let path = status == .deleted ? (oldPathCandidate ?? newPath) : newPath
            let oldPath: String? = status == .renamed ? oldPathCandidate : nil
            return FileDiff(
                path: path, oldPath: oldPath, status: status, additions: additions, deletions: deletions,
                isBinary: isBinary, hunks: hunks)
        }

        private func nonNull(_ p: String?) -> String? {
            guard let p, p != "/dev/null" else { return nil }
            return p
        }
    }

    static func parseHunkHeader(_ line: String) -> DiffHunk? {
        // @@ -a,b +c,d @@ optional section
        let scanner = line.dropFirst(2).drop(while: { $0 == " " })
        guard scanner.first == "-" else { return nil }
        let parts = scanner.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        func range(_ s: Substring) -> (Int, Int) {
            let body = s.dropFirst()  // - or +
            let nums = body.split(separator: ",")
            let start = Int(nums.first ?? "0") ?? 0
            let count = nums.count > 1 ? (Int(nums[1]) ?? 1) : 1
            return (start, count)
        }
        let (os, oc) = range(parts[0])
        let (ns, nc) = range(parts[1])
        return DiffHunk(header: line, oldStart: os, oldCount: oc, newStart: ns, newCount: nc)
    }

    /// Splits "a/x b/x" (possibly quoted) into the two paths without prefixes.
    static func parseGitHeader(_ header: String) -> (a: String?, b: String?) {
        if header.hasPrefix("\"") || header.hasSuffix("\"") {
            // At least one side is quoted. Tokenise respecting quotes.
            var tokens: [String] = []
            var i = header.startIndex
            while i < header.endIndex {
                if header[i] == " " {
                    i = header.index(after: i)
                    continue
                }
                if header[i] == "\"" {
                    var j = header.index(after: i)
                    var escaped = false
                    while j < header.endIndex {
                        if escaped {
                            escaped = false
                        } else if header[j] == "\\" {
                            escaped = true
                        } else if header[j] == "\"" {
                            break
                        }
                        j = header.index(after: j)
                    }
                    let end = j < header.endIndex ? header.index(after: j) : j
                    tokens.append(unquote(String(header[i..<end])))
                    i = end
                } else {
                    // Unquoted token runs until " \"" or " a/"/" b/" boundary; take up to next space before b/.
                    var j = i
                    while j < header.endIndex {
                        if header[j] == " " {
                            let rest = header[header.index(after: j)...]
                            if rest.hasPrefix("\"") || rest.hasPrefix("b/") { break }
                        }
                        j = header.index(after: j)
                    }
                    tokens.append(String(header[i..<j]))
                    i = j
                }
            }
            guard tokens.count >= 2 else { return (nil, nil) }
            return (stripPrefix(tokens[0]), stripPrefix(tokens[1]))
        }
        // Unquoted: "a/<p> b/<q>". Prefer an even split where both sides match (paths with spaces).
        guard header.hasPrefix("a/") else { return (nil, nil) }
        let body = header.dropFirst(2)
        if (body.count - 3) % 2 == 0 {
            let half = (body.count - 3) / 2
            let left = body.prefix(half)
            let mid = body.dropFirst(half)
            if mid.hasPrefix(" b/"), mid.dropFirst(3) == left {
                return (String(left), String(left))
            }
        }
        if let r = header.range(of: " b/", options: .backwards) {
            return (String(header[header.index(header.startIndex, offsetBy: 2)..<r.lowerBound]), String(header[r.upperBound...]))
        }
        return (nil, nil)
    }

    static func stripPrefix(_ path: String) -> String {
        if path == "/dev/null" { return path }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    /// Git C-style quoting: "a/sp\303\251cial \"x\"" -> a/spécial "x"
    static func unquote(_ s: String) -> String {
        // Strip a trailing tab-separated timestamp (from non-git diffs).
        var s = s
        if let tab = s.firstIndex(of: "\t"), !s.hasPrefix("\"") { s = String(s[..<tab]) }
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        let inner = Array(s.utf8.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var i = 0
        while i < inner.count {
            let c = inner[i]
            if c == UInt8(ascii: "\\"), i + 1 < inner.count {
                let n = inner[i + 1]
                switch n {
                case UInt8(ascii: "n"): bytes.append(10); i += 2
                case UInt8(ascii: "t"): bytes.append(9); i += 2
                case UInt8(ascii: "r"): bytes.append(13); i += 2
                case UInt8(ascii: "a"): bytes.append(7); i += 2
                case UInt8(ascii: "b"): bytes.append(8); i += 2
                case UInt8(ascii: "f"): bytes.append(12); i += 2
                case UInt8(ascii: "v"): bytes.append(11); i += 2
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value: UInt32 = 0
                    var j = i + 1
                    var digits = 0
                    while j < inner.count, digits < 3, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[j]) {
                        value = value * 8 + UInt32(inner[j] - UInt8(ascii: "0"))
                        j += 1
                        digits += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                    i = j
                default:
                    bytes.append(n)
                    i += 2
                }
            } else {
                bytes.append(c)
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
