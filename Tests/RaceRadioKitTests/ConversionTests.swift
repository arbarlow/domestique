import AgentKit
import DQCore
import Foundation
import Testing
@testable import RaceRadioKit

/// Whole milliseconds, so ms <-> Date round-trips exactly.
private let t0 = Date(radioMs: 1_762_380_000_123)

@Suite struct ConversionTests {
    @Test func uuidIDs() {
        let id = UUID()
        #expect(id.radioID == id.uuidString.lowercased())
        #expect(UUID(radioID: id.radioID) == id)
        #expect(UUID(radioID: id.uuidString) == id)
        #expect(UUID(radioID: "nope") == nil)
    }

    @Test func timestamps() {
        #expect(Date(radioMs: 1500).timeIntervalSince1970 == 1.5)
        #expect(t0.radioMs == 1_762_380_000_123)
        #expect(Date(radioMs: t0.radioMs) == t0)
    }

    @Test func enums() {
        for p in ProviderKind.allCases { #expect(ProviderKind(radio: p.radio) == p) }
        #expect(ProviderKind(radio: .unspecified) == .claude)
        for m in AgentPermissionMode.allCases { #expect(AgentPermissionMode(radio: m.radio) == m) }
        #expect(AgentPermissionMode(radio: .unspecified) == .bypass)
        for s in [ToolCall.Status.running, .completed, .failed, .declined] { #expect(ToolCall.Status(radio: s.radio) == s) }
        for r in [ApprovalRequest.Resolution.pending, .approved, .approvedForSession, .denied, .answered, .cancelled] {
            #expect(ApprovalRequest.Resolution(radio: r.radio) == r)
        }
        #expect(ApprovalRequest.Resolution(radio: .unspecified) == .pending)
        for s in [AgentTask.Status.running, .completed, .failed, .stopped] { #expect(AgentTask.Status(radio: s.radio) == s) }
    }

    @Test func approvalDecisions() {
        #expect(ApprovalDecision.approve.radio == (.approve, ""))
        #expect(ApprovalDecision.approveForSession.radio == (.approveForSession, ""))
        #expect(ApprovalDecision.deny(message: "no").radio == (.deny, "no"))
        #expect(ApprovalDecision.deny(message: nil).radio == (.deny, ""))
    }

    static let items: [TranscriptItem] = [
        .init(id: "u", timestamp: t0, kind: .user(text: "hi")),
        .init(id: "a", timestamp: t0, kind: .assistant(text: "**hello**")),
        .init(id: "r", timestamp: t0, kind: .reasoning(text: "hmm")),
        .init(id: "t", timestamp: t0, kind: .tool(ToolCall(
            name: "Edit", summary: "a.swift", input: "{}", output: "ok", status: .completed,
            fileChanges: [FileChange(path: "a.swift", diff: "@@ -1 +1 @@\n-a\n+b\n"), FileChange(path: "b", diff: "")]))),
        .init(id: "t2", timestamp: t0, kind: .tool(ToolCall(name: "Bash", summary: "ls", status: .declined))),
        .init(id: "ap", timestamp: t0, kind: .approval(ApprovalRequest(
            requestID: "req1", title: "Run rm?", detail: "rm -rf build", resolution: .approvedForSession))),
        .init(id: "q", timestamp: t0, kind: .approval(ApprovalRequest(
            requestID: "req2", title: "Question", detail: "", resolution: .answered,
            questions: [
                AgentQuestion(id: "q1", header: "Color", question: "Which?", options: [
                    .init(label: "Red", description: "warm"), .init(label: "Blue"),
                ], multiSelect: true),
                AgentQuestion(id: "q2", header: "", question: "Why?", options: []),
            ],
            answers: ["q1": "Red, Blue", "q2": "because"]))),
        .init(id: "n", timestamp: t0, kind: .notice(text: "compacted")),
        .init(id: "e", timestamp: t0, kind: .error(text: "boom")),
        .init(id: "s", timestamp: t0, kind: .turnSummary(TurnSummary(
            durationMs: 1234, costUSD: 0.05, inputTokens: 10, outputTokens: 20, isError: true, message: "limit"))),
        .init(id: "s2", timestamp: t0, kind: .turnSummary(TurnSummary())),
        .init(id: "s3", timestamp: t0, kind: .turnSummary(TurnSummary(durationMs: 0, costUSD: 0))),
        .init(id: "g", timestamp: t0, kind: .trigger(text: "background task finished")),
    ]

    @Test(arguments: items) func transcriptItemRoundTrip(_ item: TranscriptItem) throws {
        let radio = item.radio
        #expect(TranscriptItem(radio: radio) == item)
        // And through the wire.
        let decoded = try Radio_TranscriptItem(serializedBytes: radio.serializedData())
        #expect(TranscriptItem(radio: decoded) == item)
    }

    @Test func transcriptItemWireShape() {
        let r = Self.items[3].radio
        guard case .tool(let tool) = r.kind else { Issue.record("not a tool"); return }
        #expect(tool.status == .completed)
        #expect(tool.fileChanges.map(\.path) == ["a.swift", "b"])
        #expect(r.timestampMs == t0.radioMs)

        let s = Self.items[10].radio.turnSummary
        #expect(!s.hasDurationMs && !s.hasCostUsd && !s.hasInputTokens && !s.hasOutputTokens)
        let s3 = Self.items[11].radio.turnSummary
        #expect(s3.hasDurationMs && s3.hasCostUsd && s3.durationMs == 0)
    }

    @Test func transcriptItemWithoutKind() {
        var r = Radio_TranscriptItem()
        r.id = "x"
        #expect(TranscriptItem(radio: r) == nil)
    }

    @Test func agentTask() {
        var r = Radio_AgentTask()
        r.id = "task1"
        r.toolUseID = "tool9"
        r.description_p = "Explore"
        r.subagentType = "Explore"
        r.prompt = "find it"
        r.isBackground = true
        r.status = .completed
        r.startedAtMs = t0.radioMs
        r.endedAtMs = t0.radioMs + 5000
        r.toolUses = 3
        r.totalTokens = 4567
        r.activity = "Reading"
        r.output = "found"
        r.summary = "done"
        let t = AgentTask(radio: r)
        #expect(t.id == "task1" && t.toolUseID == "tool9" && t.description == "Explore" && t.subagentType == "Explore")
        #expect(t.prompt == "find it" && t.isBackground && t.status == .completed)
        #expect(t.startedAt == t0 && t.endedAt == Date(radioMs: t0.radioMs + 5000))
        #expect(t.toolUses == 3 && t.totalTokens == 4567 && t.activity == "Reading" && t.output == "found" && t.summary == "done")
        #expect(t.radio == r)

        var empty = Radio_AgentTask()
        empty.id = "t"
        let e = AgentTask(radio: empty)
        #expect(e.toolUseID == nil && e.subagentType == nil && e.prompt == nil && e.endedAt == nil && e.summary == nil)
        #expect(e.status == .running)
    }

    @Test func rateLimitWindows() {
        var w1 = Radio_RateLimitWindow()
        w1.id = "five_hour"
        w1.label = "Current session"
        w1.duration = "5 hours"
        w1.usedFraction = 0.25
        w1.resetsAtMs = t0.radioMs
        w1.status = "allowed"
        var w2 = Radio_RateLimitWindow()
        w2.id = "seven_day"
        w2.label = "Weekly"
        w2.usedFraction = 0.75
        var r = Radio_RateLimit()
        r.windows = [w1, w2]
        r.usedFraction = 0.75
        r.window = "Weekly"
        r.usingOverage = true
        r.overageStatus = "allowed"
        r.overageDisabledReason = "org"
        r.plan = "pro"
        let info = RateLimitInfo(radio: r)
        #expect(info.windows.count == 2)
        #expect(info.windows[0] == RateLimitWindow(
            id: "five_hour", label: "Current session", duration: "5 hours", usedFraction: 0.25, resetsAt: t0, status: "allowed"))
        #expect(info.windows[1].duration == nil && info.windows[1].resetsAt == nil && info.windows[1].status == nil)
        #expect(info.usingOverage && info.overageStatus == "allowed" && info.overageDisabledReason == "org" && info.plan == "pro")
        #expect(info.worst?.id == "seven_day")
        #expect(RateLimitInfo(radio: info.radio) == info)
        #expect(info.radio.window == "Weekly" && info.radio.usedFraction == 0.75)
    }

    @Test func rateLimitLegacy() {
        var r = Radio_RateLimit()
        r.usedFraction = 0.5
        r.window = "5-hour"
        r.resetsAtMs = t0.radioMs
        let info = RateLimitInfo(radio: r)
        #expect(info.windows.count == 1)
        #expect(info.windows[0].label == "5-hour" && info.windows[0].usedFraction == 0.5 && info.windows[0].resetsAt == t0)
        #expect(info.usedFraction == 0.5 && info.window == "5-hour" && info.resetsAt == t0)
        #expect(!info.usingOverage && info.overageStatus == nil && info.plan == nil)
        #expect(RateLimitInfo(radio: info.radio) == info)

        let blank = RateLimitInfo(radio: Radio_RateLimit())
        #expect(blank.windows.count == 1 && blank.windows[0].label == "Usage" && blank.windows[0].resetsAt == nil)
    }

    @Test func modelOptions() {
        let full = ModelOption(
            id: "opus", displayName: "Opus", description: "big", efforts: ["low", "high"], defaultEffort: "high", isDefault: true)
        #expect(ModelOption(radio: full.radio) == full)
        let bare = ModelOption(id: "x", displayName: "X")
        #expect(ModelOption(radio: bare.radio) == bare)
        #expect(bare.radio.description_p == "" && bare.radio.defaultEffort == "")
    }

    @Test func endpoints() {
        #expect(TeamCarEndpoint.url(URL(string: "ws://h:1")!).webSocketURL?.absoluteString == "ws://h:1/radio/v1")
        #expect(TeamCarEndpoint.url(URL(string: "wss://h/")!).webSocketURL?.absoluteString == "wss://h/radio/v1")
        #expect(TeamCarEndpoint.url(URL(string: "https://h:2/custom")!).webSocketURL?.absoluteString == "wss://h:2/custom")
        #expect(TeamCarEndpoint.url(URL(string: "ftp://h")!).webSocketURL == nil)
        #expect(TeamCarEndpoint.unix(path: "/tmp/x.sock").webSocketURL == nil)
    }
}
