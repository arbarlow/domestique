import AgentKit
import DQCore
import Foundation

// Mappings between the Domestique protocol messages and the app's models. Empty strings on the wire map to nil for
// optional model fields, and 0 ms timestamps to nil dates.

// MARK: - Ids and times

extension UUID {
    /// Server ids are lowercase UUID strings.
    public var protoID: String { uuidString.lowercased() }

    /// Parses a server id (any case). Disfavored so unapplied `UUID.init` (e.g. `flatMap(UUID.init)`) still
    /// means Foundation's `init(uuidString:)` in files that import this module.
    @_disfavoredOverload
    public init?(protoID: String) { self.init(uuidString: protoID) }
}

extension Date {
    /// A Domestique protocol `*_ms` timestamp (Unix epoch milliseconds).
    public init(protoMs: Int64) { self.init(timeIntervalSince1970: TimeInterval(protoMs) / 1000) }

    /// Unix epoch milliseconds, rounded.
    public var protoMs: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    /// nil for 0 (unset).
    static func proto(_ ms: Int64) -> Date? { ms == 0 ? nil : Date(protoMs: ms) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Enums

extension ProviderKind {
    /// Unspecified / unknown map to `.claude`, the server's default.
    public init(proto: Proto_Provider) {
        switch proto {
        case .codex: self = .codex
        default: self = .claude
        }
    }

    public var proto: Proto_Provider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

extension AgentPermissionMode {
    /// Unspecified / unknown map to `.bypass`, the protocol's default.
    public init(proto: Proto_PermissionMode) {
        switch proto {
        case .auto: self = .auto
        case .ask: self = .ask
        default: self = .bypass
        }
    }

    public var proto: Proto_PermissionMode {
        switch self {
        case .bypass: .bypass
        case .auto: .auto
        case .ask: .ask
        }
    }
}

extension ApprovalDecision {
    /// The decision and the optional message (sent to the agent on deny) for `RespondApproval`.
    public var proto: (decision: Proto_Decision, message: String) {
        switch self {
        case .approve: (.approve, "")
        case .approveForSession: (.approveForSession, "")
        case .deny(let message): (.deny, message ?? "")
        }
    }
}

// MARK: - Transcript

extension TranscriptItem {
    /// nil when the item has no kind (e.g. a kind added in a newer protocol revision).
    public init?(proto: Proto_TranscriptItem) {
        let kind: Kind
        switch proto.kind {
        case .user(let t): kind = .user(text: t)
        case .assistant(let t): kind = .assistant(text: t)
        case .reasoning(let t): kind = .reasoning(text: t)
        case .tool(let t): kind = .tool(ToolCall(proto: t))
        case .approval(let a): kind = .approval(ApprovalRequest(proto: a))
        case .notice(let t): kind = .notice(text: t)
        case .error(let t): kind = .error(text: t)
        case .turnSummary(let s): kind = .turnSummary(TurnSummary(proto: s))
        case .trigger(let t): kind = .trigger(text: t)
        case nil: return nil
        }
        self.init(id: proto.id, timestamp: Date(protoMs: proto.timestampMs), kind: kind)
    }

    public var proto: Proto_TranscriptItem {
        var r = Proto_TranscriptItem()
        r.id = id
        r.timestampMs = timestamp.protoMs
        switch kind {
        case .user(let t): r.user = t
        case .assistant(let t): r.assistant = t
        case .reasoning(let t): r.reasoning = t
        case .tool(let t): r.tool = t.proto
        case .approval(let a): r.approval = a.proto
        case .notice(let t): r.notice = t
        case .error(let t): r.error = t
        case .turnSummary(let s): r.turnSummary = s.proto
        case .trigger(let t): r.trigger = t
        }
        return r
    }
}

extension ToolCall.Status {
    /// Unspecified / unknown map to `.running`.
    public init(proto: Proto_ToolStatus) {
        switch proto {
        case .completed: self = .completed
        case .failed: self = .failed
        case .declined: self = .declined
        default: self = .running
        }
    }

    public var proto: Proto_ToolStatus {
        switch self {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .declined: .declined
        }
    }
}

extension ToolCall {
    public init(proto: Proto_ToolCall) {
        self.init(
            name: proto.name, summary: proto.summary, input: proto.input, output: proto.output,
            status: Status(proto: proto.status), fileChanges: proto.fileChanges.map(FileChange.init(proto:)),
            description: proto.description_p.isEmpty ? nil : proto.description_p)
    }

    public var proto: Proto_ToolCall {
        var r = Proto_ToolCall()
        r.name = name
        r.summary = summary
        r.input = input
        r.output = output
        r.status = status.proto
        r.fileChanges = fileChanges.map(\.proto)
        r.description_p = description ?? ""
        return r
    }
}

extension FileChange {
    public init(proto: Proto_FileChange) { self.init(path: proto.path, diff: proto.diff) }

    public var proto: Proto_FileChange {
        var r = Proto_FileChange()
        r.path = path
        r.diff = diff
        return r
    }
}

extension ApprovalRequest.Resolution {
    /// Unspecified / unknown map to `.pending`.
    public init(proto: Proto_ApprovalResolution) {
        switch proto {
        case .approved: self = .approved
        case .approvedForSession: self = .approvedForSession
        case .denied: self = .denied
        case .answered: self = .answered
        case .cancelled: self = .cancelled
        default: self = .pending
        }
    }

    public var proto: Proto_ApprovalResolution {
        switch self {
        case .pending: .pending
        case .approved: .approved
        case .approvedForSession: .approvedForSession
        case .denied: .denied
        case .answered: .answered
        case .cancelled: .cancelled
        }
    }
}

extension ApprovalRequest {
    public init(proto: Proto_ApprovalRequest) {
        self.init(
            requestID: proto.requestID, title: proto.title, detail: proto.detail,
            resolution: Resolution(proto: proto.resolution), questions: proto.questions.map(AgentQuestion.init(proto:)),
            answers: proto.answers)
    }

    public var proto: Proto_ApprovalRequest {
        var r = Proto_ApprovalRequest()
        r.requestID = requestID
        r.title = title
        r.detail = detail
        r.resolution = resolution.proto
        r.questions = questions.map(\.proto)
        r.answers = answers
        return r
    }
}

extension AgentQuestion {
    public init(proto: Proto_AgentQuestion) {
        self.init(
            id: proto.id, header: proto.header, question: proto.question,
            options: proto.options.map { Option(label: $0.label, description: $0.description_p.nilIfEmpty) },
            multiSelect: proto.multiSelect)
    }

    public var proto: Proto_AgentQuestion {
        var r = Proto_AgentQuestion()
        r.id = id
        r.header = header
        r.question = question
        r.options = options.map { o in
            var q = Proto_QuestionOption()
            q.label = o.label
            q.description_p = o.description ?? ""
            return q
        }
        r.multiSelect = multiSelect
        return r
    }
}

extension TurnSummary {
    public init(proto: Proto_TurnSummary) {
        self.init(
            durationMs: proto.hasDurationMs ? Int(proto.durationMs) : nil,
            costUSD: proto.hasCostUsd ? proto.costUsd : nil,
            inputTokens: proto.hasInputTokens ? Int(proto.inputTokens) : nil,
            outputTokens: proto.hasOutputTokens ? Int(proto.outputTokens) : nil,
            isError: proto.isError, message: proto.message.nilIfEmpty)
    }

    public var proto: Proto_TurnSummary {
        var r = Proto_TurnSummary()
        if let durationMs { r.durationMs = Int64(durationMs) }
        if let costUSD { r.costUsd = costUSD }
        if let inputTokens { r.inputTokens = Int64(inputTokens) }
        if let outputTokens { r.outputTokens = Int64(outputTokens) }
        r.isError = isError
        r.message = message ?? ""
        return r
    }
}

// MARK: - Live session state

extension AgentTask.Status {
    /// Unspecified / unknown map to `.running`.
    public init(proto: Proto_AgentTaskStatus) {
        switch proto {
        case .completed: self = .completed
        case .failed: self = .failed
        case .stopped: self = .stopped
        default: self = .running
        }
    }

    public var proto: Proto_AgentTaskStatus {
        switch self {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .stopped: .stopped
        }
    }
}

extension AgentTask {
    public init(proto: Proto_AgentTask) {
        self.init(id: proto.id, description: proto.description_p)
        toolUseID = proto.toolUseID.nilIfEmpty
        subagentType = proto.subagentType.nilIfEmpty
        prompt = proto.prompt.nilIfEmpty
        isBackground = proto.isBackground
        status = Status(proto: proto.status)
        if let started = Date.proto(proto.startedAtMs) { startedAt = started }
        endedAt = Date.proto(proto.endedAtMs)
        toolUses = Int(proto.toolUses)
        totalTokens = Int(proto.totalTokens)
        activity = proto.activity.nilIfEmpty
        output = proto.output
        summary = proto.summary.nilIfEmpty
        steps = proto.steps.map { Step(name: $0.name, summary: $0.summary) }
    }

    public var proto: Proto_AgentTask {
        var r = Proto_AgentTask()
        r.id = id
        r.toolUseID = toolUseID ?? ""
        r.description_p = description
        r.subagentType = subagentType ?? ""
        r.prompt = prompt ?? ""
        r.isBackground = isBackground
        r.status = status.proto
        r.startedAtMs = startedAt.protoMs
        r.endedAtMs = endedAt?.protoMs ?? 0
        r.toolUses = Int32(clamping: toolUses)
        r.totalTokens = Int64(totalTokens)
        r.activity = activity ?? ""
        r.steps = steps.map { s in
            var step = Proto_AgentTaskStep()
            step.name = s.name
            step.summary = s.summary
            return step
        }
        r.output = output
        r.summary = summary ?? ""
        return r
    }
}

extension RateLimitWindow {
    public init(proto: Proto_RateLimitWindow) {
        self.init(
            id: proto.id, label: proto.label, duration: proto.duration.nilIfEmpty, usedFraction: proto.usedFraction,
            resetsAt: Date.proto(proto.resetsAtMs), status: proto.status.nilIfEmpty)
    }

    public var proto: Proto_RateLimitWindow {
        var r = Proto_RateLimitWindow()
        r.id = id
        r.label = label
        r.duration = duration ?? ""
        r.usedFraction = usedFraction
        r.resetsAtMs = resetsAt?.protoMs ?? 0
        r.status = status ?? ""
        return r
    }
}

extension RateLimitInfo {
    /// Uses `windows` when present; otherwise builds one window from the legacy single-window fields.
    public init(proto: Proto_RateLimit) {
        let windows: [RateLimitWindow]
        if !proto.windows.isEmpty {
            windows = proto.windows.map(RateLimitWindow.init(proto:))
        } else {
            let label = proto.window.isEmpty ? "Usage" : proto.window
            windows = [RateLimitWindow(
                id: proto.window.isEmpty ? "primary" : proto.window, label: label, usedFraction: proto.usedFraction,
                resetsAt: Date.proto(proto.resetsAtMs))]
        }
        self.init(
            windows: windows, usingOverage: proto.usingOverage, overageStatus: proto.overageStatus.nilIfEmpty,
            overageDisabledReason: proto.overageDisabledReason.nilIfEmpty, plan: proto.plan.nilIfEmpty)
    }

    /// Fills both `windows` and the legacy fields (from the most-used window).
    public var proto: Proto_RateLimit {
        var r = Proto_RateLimit()
        r.windows = windows.map(\.proto)
        if let worst {
            r.usedFraction = worst.usedFraction
            r.window = worst.label
            r.resetsAtMs = worst.resetsAt?.protoMs ?? 0
        }
        r.usingOverage = usingOverage
        r.overageStatus = overageStatus ?? ""
        r.overageDisabledReason = overageDisabledReason ?? ""
        r.plan = plan ?? ""
        return r
    }
}

extension ModelOption {
    public init(proto: Proto_ModelOption) {
        self.init(
            id: proto.id, displayName: proto.displayName, description: proto.description_p.nilIfEmpty,
            efforts: proto.efforts, defaultEffort: proto.defaultEffort.nilIfEmpty, isDefault: proto.isDefault)
    }

    public var proto: Proto_ModelOption {
        var r = Proto_ModelOption()
        r.id = id
        r.displayName = displayName
        r.description_p = description ?? ""
        r.efforts = efforts
        r.defaultEffort = defaultEffort ?? ""
        r.isDefault = isDefault
        return r
    }
}
