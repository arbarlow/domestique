import DQCore
import Foundation

/// Short names for a workspace and a chat, written by a small, fast model from a first prompt.
/// The server does this for its own sessions (server/internal/agent/claude/names.go, same prompt);
/// this is for chats the app runs itself.
public enum ChatNamer {
    static let systemPrompt = """
        You name pieces of coding work. Read the user's request and reply with JSON only, no prose or code fences: {"workspace": "...", "chat": "..."}.
        workspace: 2-5 words naming the overall piece of work, sentence case, no trailing period.
        chat: 2-6 words naming this conversation, sentence case, no trailing period.
        Be specific (name the feature, bug or area), not generic ("Code changes", "Help request"). No quotes, emoji or branch-style slugs.
        """

    /// Reads the {"workspace", "chat"} reply, tolerating code fences or text around it.
    public static func parse(_ reply: String) -> (workspace: String, chat: String)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
            let v = try? JSONValue.parse(String(reply[start...end]))
        else { return nil }
        let ws = clean(v["workspace"]?.string ?? ""), chat = clean(v["chat"]?.string ?? "")
        return ws.isEmpty && chat.isEmpty ? nil : (ws, chat)
    }

    /// One short line, without wrapping quotes or a final period.
    public static func clean(_ s: String, max: Int = 48) -> String {
        var s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        if s.hasSuffix(".") { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > max { s = String(s.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" }
        return s
    }
}

#if os(macOS)
extension ChatNamer {
    /// Runs the local `claude` once (Haiku, no tools, MCP servers or settings). nil if it isn't
    /// installed, fails, or takes longer than a minute.
    public static func names(for prompt: String) async -> (workspace: String, chat: String)? {
        guard let exe = try? await LoginEnvironment.shared.resolve("claude") else { return nil }
        var env = await LoginEnvironment.shared.environment()
        env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-swift"
        let args = [
            "-p", "--model", "haiku", "--output-format", "text", "--tools", "", "--no-session-persistence",
            "--strict-mcp-config", "--setting-sources", "", "--system-prompt", systemPrompt,
        ]
        guard
            let result = try? await Shell.runRaw(
                exe, args, cwd: NSTemporaryDirectory(), env: env, stdinData: Data(String(prompt.prefix(4000)).utf8),
                killAfter: .seconds(60)),
            result.succeeded
        else { return nil }
        return parse(result.stdout)
    }
}
#endif
