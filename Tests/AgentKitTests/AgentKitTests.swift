import DQCore
import Testing

@testable import AgentKit

@Suite struct ToolSummaryTests {
    @Test func unwrapsShellWrapper() {
        #expect(ToolSummaries.unwrapShell(#"/bin/zsh -lc "printf 'yo' > c.txt""#) == "printf 'yo' > c.txt")
        #expect(ToolSummaries.unwrapShell("ls -la") == "ls -la")
    }

    @Test func codexAddedFileBecomesUnifiedDiff() {
        let diff = ToolSummaries.normalizeCodexDiff("a\nb\n", kind: "add")
        #expect(diff == "@@ -0,0 +1,2 @@\n+a\n+b\n")
        let update = "@@ -1 +1 @@\n-a\n+b\n"
        #expect(ToolSummaries.normalizeCodexDiff(update, kind: "update") == update)
    }

    @Test func mapsCodexCommandExecution() throws {
        let item = try JSONValue.parse(
            #"{"type":"commandExecution","id":"x","command":"/bin/zsh -lc \"npm test\"","status":"completed","exitCode":1,"aggregatedOutput":"boom","commandActions":[{"type":"unknown","command":"npm test"}]}"#
        )
        guard case .tool(let call) = ToolSummaries.codexItem(item) else { Issue.record("not a tool"); return }
        #expect(call.name == "Bash")
        #expect(call.summary == "npm test")
        #expect(call.status == .failed)
        #expect(call.output == "boom")
    }

    @Test func mapsClaudeTools() throws {
        let bash = ToolSummaries.claudeTool(name: "Bash", input: ["command": "git status"])
        #expect(bash.summary == "git status")
        let mcp = ToolSummaries.claudeTool(name: "mcp__linear__list_issues", input: [:])
        #expect(mcp.name == "MCP")
        let todos = ToolSummaries.claudeTool(
            name: "TodoWrite", input: ["todos": [["content": "a", "status": "completed"], ["content": "b", "status": "pending"]]])
        #expect(todos.summary == "✓ a\n○ b")
    }

    @Test func claudeStructuredPatchBecomesDiff() throws {
        let result = try JSONValue.parse(
            #"{"filePath":"/x/a.py","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-a","+b"]}]}"#)
        let changes = ToolSummaries.claudeFileChanges(toolName: "Edit", input: "", result: result)
        #expect(changes == [FileChange(path: "/x/a.py", diff: "@@ -1,1 +1,1 @@\n-a\n+b\n")])
    }
}
