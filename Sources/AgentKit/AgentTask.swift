import DQCore
import Foundation

/// A subagent (Claude's Agent tool, foreground or background) tracked live.
public struct AgentTask: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable { case running, completed, failed, stopped }

    public struct Step: Sendable, Hashable {
        public var name: String
        public var summary: String
        public init(name: String, summary: String) {
            self.name = name
            self.summary = summary
        }
    }

    public var id: String
    /// The Agent tool call that spawned it (matches the transcript item id).
    public var toolUseID: String?
    public var description: String
    public var subagentType: String?
    public var prompt: String?
    public var isBackground: Bool
    public var status: Status
    public var startedAt: Date
    public var endedAt: Date?
    public var toolUses: Int
    public var totalTokens: Int
    /// Latest progress line ("Running List files…").
    public var activity: String?
    /// The subagent's recent tool calls (most recent last, capped).
    public var steps: [Step]
    /// The subagent's latest text output.
    public var output: String
    /// Final summary from the completion notification.
    public var summary: String?

    public var isRunning: Bool { status == .running }

    public init(id: String, description: String) {
        self.id = id
        self.description = description
        self.isBackground = false
        self.status = .running
        self.startedAt = .now
        self.toolUses = 0
        self.totalTokens = 0
        self.steps = []
        self.output = ""
    }
}
