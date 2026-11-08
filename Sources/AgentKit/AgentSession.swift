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

/// One usage window (5-hour session, weekly, weekly per-model, …).
public struct RateLimitWindow: Sendable, Hashable, Identifiable {
    /// Stable key ("five_hour", "seven_day_opus", "primary", …), used to merge partial updates.
    public var id: String
    /// "Current session", "Weekly", "Weekly · Opus", …
    public var label: String
    /// Window length, e.g. "5 hours" / "7 days", when known.
    public var duration: String?
    /// 0...1 of the window used.
    public var usedFraction: Double
    public var resetsAt: Date?
    /// Provider status for this window ("allowed", "allowed_warning", "rejected").
    public var status: String?

    public init(
        id: String, label: String, duration: String? = nil, usedFraction: Double, resetsAt: Date?,
        status: String? = nil
    ) {
        self.id = id
        self.label = label
        self.duration = duration
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.status = status
    }

    /// Sort order: session first, then weekly, then per-model weeklies.
    public var order: Int {
        switch id {
        case "five_hour", "primary": 0
        case "seven_day", "secondary": 1
        default: 2
        }
    }
}

public struct RateLimitInfo: Sendable, Hashable {
    /// Every window this update reported. Updates can be partial; merge by `RateLimitWindow.id`.
    public var windows: [RateLimitWindow]
    /// Claude: currently drawing on extra usage / overage credits.
    public var usingOverage: Bool
    /// Claude: overage availability ("allowed", "rejected", …) and why it's unavailable.
    public var overageStatus: String?
    public var overageDisabledReason: String?
    /// Codex: plan name, when reported.
    public var plan: String?

    public init(
        windows: [RateLimitWindow], usingOverage: Bool = false, overageStatus: String? = nil,
        overageDisabledReason: String? = nil, plan: String? = nil
    ) {
        self.windows = windows
        self.usingOverage = usingOverage
        self.overageStatus = overageStatus
        self.overageDisabledReason = overageDisabledReason
        self.plan = plan
    }

    /// The most-used window.
    public var worst: RateLimitWindow? { windows.max { $0.usedFraction < $1.usedFraction } }
    public var usedFraction: Double { worst?.usedFraction ?? 0 }
    public var window: String { worst?.label ?? "Usage" }
    public var resetsAt: Date? { worst?.resetsAt }

    static func windowLabel(minutes: Int?) -> String {
        guard let m = minutes else { return "Usage" }
        if m <= 300 { return "Current session" }
        if m >= 10080 { return "Weekly" }
        return "\(m / 60)-hour"
    }

    static func duration(minutes: Int?) -> String? {
        guard let m = minutes else { return nil }
        if m % 1440 == 0 { return m == 1440 ? "1 day" : "\(m / 1440) days" }
        if m % 60 == 0 { return m == 60 ? "1 hour" : "\(m / 60) hours" }
        return "\(m) min"
    }

    static func windowLabel(_ key: String) -> String {
        switch key {
        case "five_hour": "Current session"
        case "seven_day": "Weekly · all models"
        case "seven_day_opus": "Weekly · Opus"
        case "seven_day_sonnet": "Weekly · Sonnet"
        default:
            key.hasPrefix("seven_day_")
                ? "Weekly · " + key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized
                : key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func duration(_ key: String) -> String? {
        if key.hasPrefix("five_hour") { return "5 hours" }
        if key.hasPrefix("seven_day") { return "7 days" }
        return nil
    }
}

#if os(macOS)
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
    /// Where the agent process runs (this Mac, or `ssh` into a cloud machine).
    public var host: any ExecutionHost
    /// Runs before each Claude process starts: puts the MCP servers on the host and returns the
    /// `--mcp-config` path (nil = none). A closure so that edits apply at the next restart or resume.
    public var mcpConfig: (@Sendable () async -> String?)?

    public init(
        cwd: String, model: String? = nil, effort: String? = nil, permissionMode: AgentPermissionMode = .bypass,
        resumeSessionID: String? = nil, environment: [String: String] = [:], extraWritableRoots: [String] = [],
        appendSystemPrompt: String? = nil, host: any ExecutionHost = LocalHost.shared
    ) {
        self.host = host
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

#endif

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

#if os(macOS)
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

#endif

public struct AgentError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
