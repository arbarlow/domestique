import AgentKit
import DQCore
import Foundation

// Mappings between Race Radio messages and the app's models. Empty strings on the wire map to nil for
// optional model fields, and 0 ms timestamps to nil dates.

// MARK: - Ids and times

extension UUID {
    /// Team Car ids are lowercase UUID strings.
    public var radioID: String { uuidString.lowercased() }

    /// Parses a Team Car id (any case). Disfavored so unapplied `UUID.init` (e.g. `flatMap(UUID.init)`) still
    /// means Foundation's `init(uuidString:)` in files that import this module.
    @_disfavoredOverload
    public init?(radioID: String) { self.init(uuidString: radioID) }
}

extension Date {
    /// A Race Radio `*_ms` timestamp (Unix epoch milliseconds).
    public init(radioMs: Int64) { self.init(timeIntervalSince1970: TimeInterval(radioMs) / 1000) }

    /// Unix epoch milliseconds, rounded.
    public var radioMs: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    /// nil for 0 (unset).
    static func radio(_ ms: Int64) -> Date? { ms == 0 ? nil : Date(radioMs: ms) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Enums

extension ProviderKind {
    /// Unspecified / unknown map to `.claude`, the server's default.
    public init(radio: Radio_Provider) {
        switch radio {
        case .codex: self = .codex
        default: self = .claude
        }
    }

    public var radio: Radio_Provider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

extension AgentPermissionMode {
    /// Unspecified / unknown map to `.bypass`, the protocol's default.
    public init(radio: Radio_PermissionMode) {
        switch radio {
        case .auto: self = .auto
        case .ask: self = .ask
        default: self = .bypass
        }
    }

    public var radio: Radio_PermissionMode {
        switch self {
        case .bypass: .bypass
        case .auto: .auto
        case .ask: .ask
        }
    }
}

extension ApprovalDecision {
    /// The decision and the optional message (sent to the agent on deny) for `RespondApproval`.
    public var radio: (decision: Radio_Decision, message: String) {
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
    public init?(radio: Radio_TranscriptItem) {
        let kind: Kind
        switch radio.kind {
        case .user(let t): kind = .user(text: t)
        case .assistant(let t): kind = .assistant(text: t)
        case .reasoning(let t): kind = .reasoning(text: t)
        case .tool(let t): kind = .tool(ToolCall(radio: t))
        case .approval(let a): kind = .approval(ApprovalRequest(radio: a))
        case .notice(let t): kind = .notice(text: t)
        case .error(let t): kind = .error(text: t)
        case .turnSummary(let s): kind = .turnSummary(TurnSummary(radio: s))
        case .trigger(let t): kind = .trigger(text: t)
        case nil: return nil
        }
        self.init(id: radio.id, timestamp: Date(radioMs: radio.timestampMs), kind: kind)
    }

    public var radio: Radio_TranscriptItem {
        var r = Radio_TranscriptItem()
        r.id = id
        r.timestampMs = timestamp.radioMs
        switch kind {
        case .user(let t): r.user = t
        case .assistant(let t): r.assistant = t
        case .reasoning(let t): r.reasoning = t
        case .tool(let t): r.tool = t.radio
        case .approval(let a): r.approval = a.radio
        case .notice(let t): r.notice = t
        case .error(let t): r.error = t
        case .turnSummary(let s): r.turnSummary = s.radio
        case .trigger(let t): r.trigger = t
        }
        return r
    }
}

extension ToolCall.Status {
    /// Unspecified / unknown map to `.running`.
    public init(radio: Radio_ToolStatus) {
        switch radio {
        case .completed: self = .completed
        case .failed: self = .failed
        case .declined: self = .declined
        default: self = .running
        }
    }

    public var radio: Radio_ToolStatus {
        switch self {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .declined: .declined
        }
    }
}

extension ToolCall {
    public init(radio: Radio_ToolCall) {
        self.init(
            name: radio.name, summary: radio.summary, input: radio.input, output: radio.output,
            status: Status(radio: radio.status), fileChanges: radio.fileChanges.map(FileChange.init(radio:)),
            description: radio.description_p.isEmpty ? nil : radio.description_p)
    }

    public var radio: Radio_ToolCall {
        var r = Radio_ToolCall()
        r.name = name
        r.summary = summary
        r.input = input
        r.output = output
        r.status = status.radio
        r.fileChanges = fileChanges.map(\.radio)
        r.description_p = description ?? ""
        return r
    }
}

extension FileChange {
    public init(radio: Radio_FileChange) { self.init(path: radio.path, diff: radio.diff) }

    public var radio: Radio_FileChange {
        var r = Radio_FileChange()
        r.path = path
        r.diff = diff
        return r
    }
}

extension ApprovalRequest.Resolution {
    /// Unspecified / unknown map to `.pending`.
    public init(radio: Radio_ApprovalResolution) {
        switch radio {
        case .approved: self = .approved
        case .approvedForSession: self = .approvedForSession
        case .denied: self = .denied
        case .answered: self = .answered
        case .cancelled: self = .cancelled
        default: self = .pending
        }
    }

    public var radio: Radio_ApprovalResolution {
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
    public init(radio: Radio_ApprovalRequest) {
        self.init(
            requestID: radio.requestID, title: radio.title, detail: radio.detail,
            resolution: Resolution(radio: radio.resolution), questions: radio.questions.map(AgentQuestion.init(radio:)),
            answers: radio.answers)
    }

    public var radio: Radio_ApprovalRequest {
        var r = Radio_ApprovalRequest()
        r.requestID = requestID
        r.title = title
        r.detail = detail
        r.resolution = resolution.radio
        r.questions = questions.map(\.radio)
        r.answers = answers
        return r
    }
}

extension AgentQuestion {
    public init(radio: Radio_AgentQuestion) {
        self.init(
            id: radio.id, header: radio.header, question: radio.question,
            options: radio.options.map { Option(label: $0.label, description: $0.description_p.nilIfEmpty) },
            multiSelect: radio.multiSelect)
    }

    public var radio: Radio_AgentQuestion {
        var r = Radio_AgentQuestion()
        r.id = id
        r.header = header
        r.question = question
        r.options = options.map { o in
            var q = Radio_QuestionOption()
            q.label = o.label
            q.description_p = o.description ?? ""
            return q
        }
        r.multiSelect = multiSelect
        return r
    }
}

extension TurnSummary {
    public init(radio: Radio_TurnSummary) {
        self.init(
            durationMs: radio.hasDurationMs ? Int(radio.durationMs) : nil,
            costUSD: radio.hasCostUsd ? radio.costUsd : nil,
            inputTokens: radio.hasInputTokens ? Int(radio.inputTokens) : nil,
            outputTokens: radio.hasOutputTokens ? Int(radio.outputTokens) : nil,
            isError: radio.isError, message: radio.message.nilIfEmpty)
    }

    public var radio: Radio_TurnSummary {
        var r = Radio_TurnSummary()
        if let durationMs { r.durationMs = Int64(durationMs) }
        if let costUSD { r.costUsd = costUSD }
        if let inputTokens { r.inputTokens = Int64(inputTokens) }
        if let outputTokens { r.outputTokens = Int64(outputTokens) }
        r.isError = isError
        r.message = message ?? ""
        return r
    }
}

// MARK: - Live rider state

extension AgentTask.Status {
    /// Unspecified / unknown map to `.running`.
    public init(radio: Radio_AgentTaskStatus) {
        switch radio {
        case .completed: self = .completed
        case .failed: self = .failed
        case .stopped: self = .stopped
        default: self = .running
        }
    }

    public var radio: Radio_AgentTaskStatus {
        switch self {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .stopped: .stopped
        }
    }
}

extension AgentTask {
    public init(radio: Radio_AgentTask) {
        self.init(id: radio.id, description: radio.description_p)
        toolUseID = radio.toolUseID.nilIfEmpty
        subagentType = radio.subagentType.nilIfEmpty
        prompt = radio.prompt.nilIfEmpty
        isBackground = radio.isBackground
        status = Status(radio: radio.status)
        if let started = Date.radio(radio.startedAtMs) { startedAt = started }
        endedAt = Date.radio(radio.endedAtMs)
        toolUses = Int(radio.toolUses)
        totalTokens = Int(radio.totalTokens)
        activity = radio.activity.nilIfEmpty
        output = radio.output
        summary = radio.summary.nilIfEmpty
        steps = radio.steps.map { Step(name: $0.name, summary: $0.summary) }
    }

    public var radio: Radio_AgentTask {
        var r = Radio_AgentTask()
        r.id = id
        r.toolUseID = toolUseID ?? ""
        r.description_p = description
        r.subagentType = subagentType ?? ""
        r.prompt = prompt ?? ""
        r.isBackground = isBackground
        r.status = status.radio
        r.startedAtMs = startedAt.radioMs
        r.endedAtMs = endedAt?.radioMs ?? 0
        r.toolUses = Int32(clamping: toolUses)
        r.totalTokens = Int64(totalTokens)
        r.activity = activity ?? ""
        r.steps = steps.map { s in
            var step = Radio_AgentTaskStep()
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
    public init(radio: Radio_RateLimitWindow) {
        self.init(
            id: radio.id, label: radio.label, duration: radio.duration.nilIfEmpty, usedFraction: radio.usedFraction,
            resetsAt: Date.radio(radio.resetsAtMs), status: radio.status.nilIfEmpty)
    }

    public var radio: Radio_RateLimitWindow {
        var r = Radio_RateLimitWindow()
        r.id = id
        r.label = label
        r.duration = duration ?? ""
        r.usedFraction = usedFraction
        r.resetsAtMs = resetsAt?.radioMs ?? 0
        r.status = status ?? ""
        return r
    }
}

extension RateLimitInfo {
    /// Uses `windows` when present; otherwise builds one window from the legacy single-window fields.
    public init(radio: Radio_RateLimit) {
        let windows: [RateLimitWindow]
        if !radio.windows.isEmpty {
            windows = radio.windows.map(RateLimitWindow.init(radio:))
        } else {
            let label = radio.window.isEmpty ? "Usage" : radio.window
            windows = [RateLimitWindow(
                id: radio.window.isEmpty ? "primary" : radio.window, label: label, usedFraction: radio.usedFraction,
                resetsAt: Date.radio(radio.resetsAtMs))]
        }
        self.init(
            windows: windows, usingOverage: radio.usingOverage, overageStatus: radio.overageStatus.nilIfEmpty,
            overageDisabledReason: radio.overageDisabledReason.nilIfEmpty, plan: radio.plan.nilIfEmpty)
    }

    /// Fills both `windows` and the legacy fields (from the most-used window).
    public var radio: Radio_RateLimit {
        var r = Radio_RateLimit()
        r.windows = windows.map(\.radio)
        if let worst {
            r.usedFraction = worst.usedFraction
            r.window = worst.label
            r.resetsAtMs = worst.resetsAt?.radioMs ?? 0
        }
        r.usingOverage = usingOverage
        r.overageStatus = overageStatus ?? ""
        r.overageDisabledReason = overageDisabledReason ?? ""
        r.plan = plan ?? ""
        return r
    }
}

extension ModelOption {
    public init(radio: Radio_ModelOption) {
        self.init(
            id: radio.id, displayName: radio.displayName, description: radio.description_p.nilIfEmpty,
            efforts: radio.efforts, defaultEffort: radio.defaultEffort.nilIfEmpty, isDefault: radio.isDefault)
    }

    public var radio: Radio_ModelOption {
        var r = Radio_ModelOption()
        r.id = id
        r.displayName = displayName
        r.description_p = description ?? ""
        r.efforts = efforts
        r.defaultEffort = defaultEffort ?? ""
        r.isDefault = isDefault
        return r
    }
}
