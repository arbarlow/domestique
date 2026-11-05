import Foundation
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

@Suite struct ClaudeModelTests {
    @Test func defaultIsNamedAfterResolvedModel() throws {
        let resp = try JSONValue.parse(Data(#"""
            {"models":[
              {"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5 · Best for everyday, complex tasks","supportedEffortLevels":["low","high"]},
              {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","description":"For complex work"},
              {"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5"}
            ]}
            """#.utf8))
        let models = ClaudeSession.parseModels(resp)
        #expect(models.map(\.displayName) == ["Opus 5.5", "Opus 5.5", "Haiku 4.5"])
        #expect(models[0].isDefault && models[0].description == "Best for everyday, complex tasks")
        #expect(models[0].defaultEffort == "high")
    }
}

@Suite struct RateLimitTests {
    @Test func claudeKeepsEveryWindow() throws {
        let json = #"""
            {"status":"allowed","isUsingOverage":false,"overageStatus":"rejected","overageDisabledReason":"out_of_credits",
             "unifiedWindows":{"seven_day":{"utilization":0.15,"resetsAt":1794344400,"status":"allowed"},
                               "five_hour":{"utilization":0.42,"resetsAt":1794300000,"status":"allowed"},
                               "seven_day_opus":{"utilization":0.3,"resetsAt":1794344400}}}
            """#
        let info = try #require(ClaudeSession.rateLimit(try JSONValue.parse(Data(json.utf8))))
        #expect(info.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(info.windows.map(\.label) == ["Current session", "Weekly · all models", "Weekly · Opus"])
        #expect(info.worst?.id == "five_hour")
        #expect(info.overageDisabledReason == "out_of_credits")
    }
}
