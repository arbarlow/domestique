import DQCore
import Foundation

/// Events a provider session emits. The UI folds these into an ordered transcript.
public enum AgentEvent: Sendable {
    /// Provider assigned/confirmed its session id (Claude session_id / Codex thread id).
    case started(sessionID: String, model: String?)
    /// Insert or replace a transcript item by id.
    case upsert(TranscriptItem)
    /// Streaming text appended to an existing item (assistant/reasoning text, or tool output).
    case appendText(itemID: String, delta: String)
    case turnStarted
    case turnEnded(TurnSummary)
    /// Transient status line ("Retrying 2/10…"). nil clears.
    case status(String?)
    case models([ModelOption])
    /// The underlying process went away. Next `send` restarts and resumes.
    case exited(message: String?)
    /// Subscription usage window update.
    case rateLimit(RateLimitInfo)
    /// A subagent started / progressed / finished.
    case task(AgentTask)
    /// The agent started a turn on its own (e.g. a background subagent finished). `reason` is user-facing.
    case autoTurnStarted(reason: String)
}

public struct RateLimitInfo: Sendable, Hashable {
    /// 0...1 of the window used.
    public var usedFraction: Double
    /// "5-hour", "Weekly", …
    public var window: String
    public var resetsAt: Date?

    public init(usedFraction: Double, window: String, resetsAt: Date?) {
        self.usedFraction = usedFraction
        self.window = window
        self.resetsAt = resetsAt
    }

    static func windowLabel(minutes: Int?) -> String {
        guard let m = minutes else { return "Usage" }
        if m <= 300 { return "\(m / 60)-hour" }
        if m >= 10080 { return "Weekly" }
        return "\(m / 60)h"
    }

    static func windowLabel(_ key: String) -> String {
        switch key {
        case "five_hour": "5-hour"
        case "seven_day", "seven_day_opus", "seven_day_sonnet": "Weekly"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public struct AgentSessionConfig: Sendable {
    public var cwd: String
    public var model: String?
    /// Thinking / reasoning effort ("low"…"max"); nil = model default.
    public var effort: String?
    public var permissionMode: AgentPermissionMode
    /// Resume this provider session (Claude session id / Codex thread id).
    public var resumeSessionID: String?
    /// Extra environment on top of the login environment (workspace ports etc).
    public var environment: [String: String]
    /// Extra writable roots for sandboxed modes (e.g. the main repo's .git dir, which worktrees write into).
    public var extraWritableRoots: [String]
    public var appendSystemPrompt: String?

    public init(
        cwd: String, model: String? = nil, effort: String? = nil, permissionMode: AgentPermissionMode = .bypass,
        resumeSessionID: String? = nil, environment: [String: String] = [:], extraWritableRoots: [String] = [],
        appendSystemPrompt: String? = nil
    ) {
        self.cwd = cwd
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.resumeSessionID = resumeSessionID
        self.environment = environment
        self.extraWritableRoots = extraWritableRoots
        self.appendSystemPrompt = appendSystemPrompt
    }
}

public struct AgentAttachment: Sendable {
    public var data: Data
    public var mediaType: String
    public var filename: String
    public init(data: Data, mediaType: String, filename: String) {
        self.data = data
        self.mediaType = mediaType
        self.filename = filename
    }
}

public protocol AgentSession: AnyObject, Sendable {
    var provider: ProviderKind { get }
    var events: AsyncStream<AgentEvent> { get }
    /// Sends a user message. Starts (or resumes) the provider process if needed.
    /// If a turn is running the message is queued/steered into it.
    func send(_ text: String, attachments: [AgentAttachment]) async throws
    func interrupt() async
    func respond(requestID: String, decision: ApprovalDecision) async
    func answer(requestID: String, answers: [String: String]) async
    func setPermissionMode(_ mode: AgentPermissionMode) async
    func setModel(_ model: String?) async
    func setEffort(_ effort: String?) async
    func shutdown() async
}

public enum AgentFactory {
    public static func makeSession(provider: ProviderKind, config: AgentSessionConfig) -> any AgentSession {
        switch provider {
        case .claude: ClaudeSession(config: config)
        case .codex: CodexSession(config: config)
        }
    }

    /// Models we can offer before a session has started.
    public static func defaultModels(_ provider: ProviderKind) async -> [ModelOption] {
        switch provider {
        case .claude: ClaudeSession.fallbackModels
        case .codex: (try? await CodexAppServer.shared.listModels()) ?? []
        }
    }
}

public struct AgentError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
