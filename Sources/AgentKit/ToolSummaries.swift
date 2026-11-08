import DQCore
import Foundation

/// Turns provider-specific tool calls into one-line summaries the transcript can show.
enum ToolSummaries {
    static func claudeTool(name: String, input: JSONValue) -> ToolCall {
        let summary: String
        var displayName = name
        func s(_ key: String) -> String? { input[key]?.string }
        switch name {
        case "Bash":
            summary = s("command") ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            summary = shortPath(s("file_path") ?? s("notebook_path") ?? "")
        case "Grep":
            summary = [s("pattern").map { "\"\($0)\"" }, s("path").map(shortPath), s("glob")].compactMap { $0 }
                .joined(separator: " in ")
        case "Glob":
            summary = s("pattern") ?? ""
        case "WebFetch":
            summary = s("url") ?? ""
        case "WebSearch":
            summary = s("query") ?? ""
        case "Task", "Agent":
            displayName = "Agent"
            summary = s("description") ?? s("prompt").map { String($0.prefix(80)) } ?? ""
        case "TodoWrite":
            displayName = "Todos"
            let todos = input["todos"]?.array ?? []
            summary = todos.map { t -> String in
                let mark =
                    switch t["status"]?.string {
                    case "completed": "✓"
                    case "in_progress": "→"
                    default: "○"
                    }
                return "\(mark) \(t["content"]?.string ?? "")"
            }.joined(separator: "\n")
        case "Skill":
            summary = s("skill") ?? s("command") ?? ""
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                displayName = "MCP"
                summary = parts.dropFirst().joined(separator: ".")
            } else {
                summary = firstString(in: input) ?? ""
            }
        }
        let inputText: String =
            switch name {
            case "Bash": s("command") ?? input.prettyString
            default: input.prettyString
            }
        let description = name == "Bash" ? s("description").flatMap { $0.isEmpty ? nil : $0 } : nil
        return ToolCall(name: displayName, summary: summary, input: inputText, description: description)
    }

    static func firstString(in value: JSONValue) -> String? {
        guard let o = value.object else { return nil }
        for key in o.keys.sorted() { if let s = o[key]?.string { return String(s.prefix(120)) } }
        return nil
    }

    static func shortPath(_ path: String) -> String {
        let home = URL.homeDirectory.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func flattenToolResult(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let s = content.string { return s }
        if let arr = content.array {
            return arr.compactMap { block -> String? in
                if block["type"]?.string == "text" { return block["text"]?.string }
                if block["type"]?.string == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
        }
        return content.prettyString
    }

    /// Claude's `tool_use_result` for Edit/Write carries a structuredPatch we can show as a diff.
    static func claudeFileChanges(toolName: String, input: String, result: JSONValue) -> [FileChange] {
        guard let path = result["filePath"]?.string else { return [] }
        if let hunks = result["structuredPatch"]?.array, !hunks.isEmpty {
            var diff = ""
            for h in hunks {
                let os = h["oldStart"]?.int ?? 0
                let ol = h["oldLines"]?.int ?? 0
                let ns = h["newStart"]?.int ?? 0
                let nl = h["newLines"]?.int ?? 0
                diff += "@@ -\(os),\(ol) +\(ns),\(nl) @@\n"
                for line in h["lines"]?.array ?? [] { diff += (line.string ?? "") + "\n" }
            }
            return [FileChange(path: path, diff: diff)]
        }
        if result["type"]?.string == "create", let content = result["content"]?.string {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var diff = "@@ -0,0 +1,\(lines.count) @@\n"
            for l in lines { diff += "+\(l)\n" }
            return [FileChange(path: path, diff: diff)]
        }
        return []
    }

    // MARK: Codex

    static func codexItem(_ item: JSONValue) -> TranscriptItem.Kind? {
        guard let type = item["type"]?.string else { return nil }
        switch type {
        case "userMessage", "hookPrompt":
            return nil
        case "agentMessage":
            return .assistant(text: item["text"]?.string ?? "")
        case "reasoning":
            let summary = (item["summary"]?.array ?? []).compactMap(\.string).joined(separator: "\n\n")
            let content = (item["content"]?.array ?? []).compactMap(\.string).joined(separator: "\n\n")
            return .reasoning(text: summary.isEmpty ? content : summary)
        case "plan":
            return .assistant(text: item["text"]?.string ?? "")
        case "commandExecution":
            let raw = item["command"]?.string ?? ""
            let action = item["commandActions"]?[0]
            let display = action?["command"]?.string ?? unwrapShell(raw)
            var call = ToolCall(
                name: "Bash", summary: display, input: raw, output: item["aggregatedOutput"]?.string ?? "",
                status: codexStatus(item["status"]?.string))
            if let code = item["exitCode"]?.int, code != 0, call.status == .completed { call.status = .failed }
            if let path = action?["path"]?.string, action?["type"]?.string == "read" {
                call.name = "Read"
                call.summary = shortPath(path)
            }
            return .tool(call)
        case "fileChange":
            let changes = (item["changes"]?.array ?? []).map { change -> FileChange in
                let path = change["path"]?.string ?? ""
                let diff = change["diff"]?.string ?? ""
                return FileChange(path: path, diff: normalizeCodexDiff(diff, kind: change["kind"]?["type"]?.string))
            }
            let summary = changes.map { shortPath($0.path) }.joined(separator: ", ")
            return .tool(
                ToolCall(
                    name: "Edit", summary: summary, status: codexStatus(item["status"]?.string),
                    fileChanges: changes))
        case "mcpToolCall":
            let server = item["server"]?.string ?? ""
            let tool = item["tool"]?.string ?? ""
            var output = ""
            if let result = item["result"] {
                output = (result["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                if output.isEmpty { output = result.prettyString }
            }
            if let err = item["error"]?["message"]?.string { output = err }
            return .tool(
                ToolCall(
                    name: "MCP", summary: "\(server).\(tool)", input: item["arguments"]?.prettyString ?? "",
                    output: output, status: codexStatus(item["status"]?.string)))
        case "dynamicToolCall":
            return .tool(
                ToolCall(
                    name: item["tool"]?.string ?? "Tool", summary: firstString(in: item["arguments"] ?? .null) ?? "",
                    input: item["arguments"]?.prettyString ?? "", status: codexStatus(item["status"]?.string)))
        case "webSearch":
            return .tool(
                ToolCall(
                    name: "WebSearch", summary: item["query"]?.string ?? item["action"]?["query"]?.string ?? "",
                    status: .completed))
        case "collabAgentToolCall", "subAgentActivity":
            return .tool(
                ToolCall(
                    name: "Agent", summary: item["prompt"]?.string.map { String($0.prefix(80)) } ?? type,
                    status: codexStatus(item["status"]?.string)))
        case "contextCompaction":
            return .notice(text: "Context compacted")
        case "imageView":
            return .tool(ToolCall(name: "Image", summary: shortPath(item["path"]?.string ?? ""), status: .completed))
        case "enteredReviewMode":
            return .notice(text: "Entered review mode")
        case "exitedReviewMode":
            return .assistant(text: item["review"]?.string ?? "")
        default:
            return nil
        }
    }

    /// Codex sends whole-file content (not a unified diff) for added/deleted files.
    static func normalizeCodexDiff(_ diff: String, kind: String?) -> String {
        guard kind == "add" || kind == "delete", !diff.contains("@@") else { return diff }
        var lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        let sign = kind == "add" ? "+" : "-"
        let header = kind == "add" ? "@@ -0,0 +1,\(lines.count) @@" : "@@ -1,\(lines.count) +0,0 @@"
        return ([header] + lines.map { sign + $0 }).joined(separator: "\n") + "\n"
    }

    static func codexStatus(_ s: String?) -> ToolCall.Status {
        switch s {
        case "completed": .completed
        case "failed": .failed
        case "declined": .declined
        default: .running
        }
    }

    /// `/bin/zsh -lc "foo"` -> `foo`
    static func unwrapShell(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where command.hasPrefix(prefix) {
            var rest = String(command.dropFirst(prefix.count))
            if (rest.hasPrefix("\"") && rest.hasSuffix("\"")) || (rest.hasPrefix("'") && rest.hasSuffix("'")),
                rest.count >= 2
            {
                rest = String(rest.dropFirst().dropLast())
            }
            return rest
        }
        return command
    }
}
