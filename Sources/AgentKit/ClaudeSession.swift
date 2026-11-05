import DQCore
import Foundation

/// Drives the user's installed, unmodified `claude` binary over its stream-json control protocol
/// (the same stdio protocol the official Agent SDKs use). Auth is whatever `claude` is logged in with.
public actor ClaudeSession: AgentSession {
    public nonisolated let provider: ProviderKind = .claude
    public nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    private var config: AgentSessionConfig
    private var process: LineProcess?
    private var sessionID: String?
    private var readerTask: Task<Void, Never>?
    private var requestCounter = 0
    private var pendingControl: [String: CheckedContinuation<JSONValue, Error>] = [:]
    /// can_use_tool requests awaiting the user: request id -> original input.
    private var pendingPermissions: [String: (tool: String, input: JSONValue, toolUseID: String?)] = [:]
    private var approvalItems: [String: TranscriptItem] = [:]

    // Streaming bookkeeping.
    private var currentMessageID: String?
    private var streamedBlocks: [String: [Int: (itemID: String, kind: String)]] = [:]
    private var streamedTextOrder: [String: [String]] = [:]  // msg id -> text item ids in order
    private var streamedThinkingOrder: [String: [String]] = [:]
    private var finalTextCount: [String: Int] = [:]
    private var finalThinkingCount: [String: Int] = [:]
    private var tools: [String: TranscriptItem] = [:]
    private var turnRunning = false
    private var interruptRequested = false
    // Subagents.
    private var tasks: [String: AgentTask] = [:]
    private var taskByToolUse: [String: String] = [:]
    /// Completion notices since the last turn started; they explain the next automatic turn.
    private var pendingNotices: [String] = []

    static let allEfforts = ["low", "medium", "high", "xhigh", "max"]

    public static let fallbackModels: [ModelOption] = [
        ModelOption(id: "default", displayName: "Default", description: "Claude Code's default model", efforts: allEfforts, defaultEffort: "high", isDefault: true),
        ModelOption(id: "opus", displayName: "Opus", efforts: allEfforts, defaultEffort: "high"),
        ModelOption(id: "sonnet", displayName: "Sonnet", efforts: allEfforts, defaultEffort: "high"),
        ModelOption(id: "haiku", displayName: "Haiku"),
    ]

    /// "Default (recommended)" style names from the CLI are trimmed for the compact picker.
    static func shortName(_ s: String) -> String {
        s.replacingOccurrences(of: " (recommended)", with: "")
    }

    public init(config: AgentSessionConfig) {
        self.config = config
        self.sessionID = config.resumeSessionID
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: lifecycle

    private func ensureProcess() async throws {
        if let process, process.isRunning { return }
        let exe = try await LoginEnvironment.shared.resolve("claude")
        var env = await LoginEnvironment.shared.environment()
        env.merge(config.environment) { $1 }
        env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-swift"

        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", Self.cliMode(config.permissionMode),
            // Lets us switch into bypass mid-session without restarting.
            "--allow-dangerously-skip-permissions",
        ]
        if let model = config.model, model != "default" { args += ["--model", model] }
        if let effort = config.effort { args += ["--effort", effort] }
        if let sessionID { args += ["--resume", sessionID] }
        if let prompt = config.appendSystemPrompt, !prompt.isEmpty { args += ["--append-system-prompt", prompt] }
        for root in config.extraWritableRoots { args += ["--add-dir", root] }

        let proc = LineProcess(executable: exe, arguments: args, cwd: config.cwd, environment: env)
        try proc.start { [weak self] status, stderr in
            Task { await self?.processExited(status: status, stderr: stderr) }
        }
        process = proc
        readerTask = Task { [weak self] in
            for await line in proc.lines {
                await self?.handle(line: line)
            }
        }
        // Handshake. Response carries models, commands, account.
        Task { [weak self] in
            guard let self else { return }
            if let resp = try? await self.control(["subtype": "initialize", "hooks": .null]) {
                await self.handleInitialize(resp)
            }
        }
    }

    private func processExited(status: Int32, stderr: String) {
        process = nil
        for (_, c) in pendingControl { c.resume(throwing: AgentError("Claude exited")) }
        pendingControl.removeAll()
        for (id, var item) in approvalItems {
            if case .approval(var req) = item.kind, req.resolution == .pending {
                req.resolution = .cancelled
                item.kind = .approval(req)
                emit(.upsert(item))
            }
            approvalItems[id] = nil
        }
        pendingPermissions.removeAll()
        finishRunningTools(status: .failed)
        if turnRunning {
            turnRunning = false
            emit(.turnEnded(TurnSummary(isError: true, message: "Claude exited")))
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // SIGINT/SIGTERM on shutdown are expected; only surface real failures.
        let expected = status == 0 || status == 130 || status == 143 || status == 2
        emit(.exited(message: expected ? nil : (trimmed.isEmpty ? "claude exited with status \(status)" : String(trimmed.suffix(2000)))))
    }

    public func shutdown() async {
        process?.closeInput()
        process?.terminate()
        readerTask?.cancel()
        process = nil
    }

    // MARK: public API

    public func send(_ text: String, attachments: [AgentAttachment]) async throws {
        try await ensureProcess()
        var content: [JSONValue] = []
        for a in attachments where a.mediaType.hasPrefix("image/") {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": .string(a.mediaType), "data": .string(a.data.base64EncodedString())],
            ])
        }
        content.append(["type": "text", "text": .string(text)])
        let msg: JSONValue = [
            "type": "user",
            "message": ["role": "user", "content": .array(content)],
            "parent_tool_use_id": .null,
            "session_id": .string(sessionID ?? ""),
        ]
        if !turnRunning {
            turnRunning = true
            emit(.turnStarted)
        }
        process?.write(msg)
    }

    public func interrupt() async {
        guard process != nil, turnRunning else { return }
        interruptRequested = true
        _ = try? await control(["subtype": "interrupt"])
    }

    public func respond(requestID: String, decision: ApprovalDecision) async {
        guard let pending = pendingPermissions.removeValue(forKey: requestID) else { return }
        var response: JSONValue
        var resolution: ApprovalRequest.Resolution
        switch decision {
        case .approve:
            response = ["behavior": "allow", "updatedInput": pending.input]
            resolution = .approved
        case .approveForSession:
            response = [
                "behavior": "allow", "updatedInput": pending.input,
                "updatedPermissions": [
                    [
                        "type": "addRules", "behavior": "allow", "destination": "session",
                        "rules": [["toolName": .string(pending.tool)]],
                    ]
                ],
            ]
            resolution = .approvedForSession
        case .deny(let message):
            response = ["behavior": "deny", "message": .string(message ?? "The user denied this action.")]
            resolution = .denied
        }
        if let id = pending.toolUseID, case .object(var o) = response {
            o["toolUseID"] = .string(id)
            response = .object(o)
        }
        writeControlResponse(requestID: requestID, response: response)
        resolveApproval(requestID, resolution: resolution, answers: [:])
    }

    public func answer(requestID: String, answers: [String: String]) async {
        guard let pending = pendingPermissions.removeValue(forKey: requestID) else { return }
        // AskUserQuestion: answers are keyed by question text.
        var input = pending.input.object ?? [:]
        var byQuestion: [String: JSONValue] = [:]
        if let item = approvalItems[requestID], case .approval(let req) = item.kind {
            for q in req.questions { if let a = answers[q.id] { byQuestion[q.question] = .string(a) } }
        }
        input["answers"] = .object(byQuestion)
        writeControlResponse(requestID: requestID, response: ["behavior": "allow", "updatedInput": .object(input)])
        resolveApproval(requestID, resolution: .answered, answers: answers)
    }

    public func setPermissionMode(_ mode: AgentPermissionMode) async {
        config.permissionMode = mode
        guard process != nil else { return }
        _ = try? await control(["subtype": "set_permission_mode", "mode": .string(Self.cliMode(mode))])
    }

    public func setModel(_ model: String?) async {
        config.model = model
        guard process != nil else { return }
        let value: JSONValue = (model == nil || model == "default") ? .null : .string(model!)
        _ = try? await control(["subtype": "set_model", "model": value])
    }

    /// Picks the most-used unified window from a rate_limit_event.
    static func rateLimit(_ info: JSONValue?) -> RateLimitInfo? {
        guard let info else { return nil }
        var best: RateLimitInfo?
        for (key, w) in info["unifiedWindows"]?.object ?? [:] {
            guard let used = w["utilization"]?.double else { continue }
            let candidate = RateLimitInfo(
                usedFraction: used, window: RateLimitInfo.windowLabel(key),
                resetsAt: w["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) })
            if best == nil || used > best!.usedFraction { best = candidate }
        }
        return best
    }

    public func setEffort(_ effort: String?) async {
        config.effort = effort
        guard process != nil else { return }
        _ = try? await control([
            "subtype": "apply_flag_settings", "settings": ["effortLevel": effort.map { .string($0) } ?? .null],
        ])
    }

    static func cliMode(_ mode: AgentPermissionMode) -> String {
        switch mode {
        case .bypass: "bypassPermissions"
        case .auto: "auto"
        case .ask: "default"
        }
    }

    // MARK: control protocol

    private func control(_ request: JSONValue) async throws -> JSONValue {
        guard let process else { throw AgentError("Claude isn't running") }
        requestCounter += 1
        let id = "dq_\(requestCounter)"
        return try await withCheckedThrowingContinuation { cont in
            pendingControl[id] = cont
            process.write(["type": "control_request", "request_id": .string(id), "request": request])
        }
    }

    private func writeControlResponse(requestID: String, response: JSONValue) {
        process?.write([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestID), "response": response],
        ])
    }

    private func writeControlError(requestID: String, message: String) {
        process?.write([
            "type": "control_response",
            "response": ["subtype": "error", "request_id": .string(requestID), "error": .string(message)],
        ])
    }

    private func handleInitialize(_ resp: JSONValue) {
        guard let models = resp["models"]?.array, !models.isEmpty else { return }
        let options = models.compactMap { m -> ModelOption? in
            guard let value = m["value"]?.string else { return nil }
            let efforts = (m["supportedEffortLevels"]?.array ?? []).compactMap(\.string)
            return ModelOption(
                id: value, displayName: Self.shortName(m["displayName"]?.string ?? value),
                description: m["description"]?.string, efforts: efforts,
                defaultEffort: efforts.contains("high") ? "high" : efforts.last, isDefault: value == "default")
        }
        if !options.isEmpty { emit(.models(options)) }
    }

    // MARK: inbound

    private func emit(_ e: AgentEvent) { continuation.yield(e) }

    private func handle(line: Data) {
        guard let msg = try? JSONValue.parse(line) else { return }
        switch msg["type"]?.string {
        case "system": handleSystem(msg)
        case "stream_event": handleStreamEvent(msg)
        case "assistant": handleAssistant(msg)
        case "user": handleUser(msg)
        case "result": handleResult(msg)
        case "control_request": handleControlRequest(msg)
        case "control_response": handleControlResponse(msg)
        case "rate_limit_event":
            if let info = Self.rateLimit(msg["rate_limit_info"]) { emit(.rateLimit(info)) }
        case "control_cancel_request":
            if let id = msg["request_id"]?.string {
                pendingPermissions[id] = nil
                resolveApproval(id, resolution: .cancelled, answers: [:])
            }
        default: break
        }
    }

    private func handleSystem(_ msg: JSONValue) {
        switch msg["subtype"]?.string {
        case "init":
            if let sid = msg["session_id"]?.string {
                sessionID = sid
                emit(.started(sessionID: sid, model: msg["model"]?.string))
            }
        case "api_retry":
            let attempt = msg["attempt"]?.int ?? 0
            let max = msg["max_retries"]?.int ?? 0
            let err = msg["error"]?.string ?? "error"
            emit(.status("API \(err.replacingOccurrences(of: "_", with: " ")) — retrying (\(attempt)/\(max))"))
        case "status":
            if msg["status"]?.string == "compacting" {
                emit(.status("Compacting context…"))
            } else {
                emit(.status(nil))
            }
        case "task_started", "task_progress", "task_updated", "task_notification":
            handleTask(msg)
        case "compact_boundary":
            emit(.upsert(TranscriptItem(id: "compact-\(UUID().uuidString)", kind: .notice(text: "Context compacted"))))
        default: break
        }
    }

    private func handleStreamEvent(_ msg: JSONValue) {
        guard msg["parent_tool_use_id"]?.isNull ?? true, let event = msg["event"] else { return }
        switch event["type"]?.string {
        case "message_start":
            currentMessageID = event["message"]?["id"]?.string
            beginAutoTurnIfIdle()
            emit(.status(nil))
        case "content_block_start":
            guard let mid = currentMessageID, let index = event["index"]?.int,
                let type = event["content_block"]?["type"]?.string
            else { return }
            let itemID = "\(mid)-\(index)"
            switch type {
            case "text":
                streamedBlocks[mid, default: [:]][index] = (itemID, "text")
                streamedTextOrder[mid, default: []].append(itemID)
                emit(.upsert(TranscriptItem(id: itemID, kind: .assistant(text: ""))))
            case "thinking":
                streamedBlocks[mid, default: [:]][index] = (itemID, "thinking")
                streamedThinkingOrder[mid, default: []].append(itemID)
                emit(.upsert(TranscriptItem(id: itemID, kind: .reasoning(text: ""))))
            default: break
            }
        case "content_block_delta":
            guard let mid = currentMessageID, let index = event["index"]?.int,
                let block = streamedBlocks[mid]?[index], let delta = event["delta"]
            else { return }
            switch delta["type"]?.string {
            case "text_delta":
                if let t = delta["text"]?.string { emit(.appendText(itemID: block.itemID, delta: t)) }
            case "thinking_delta":
                if let t = delta["thinking"]?.string { emit(.appendText(itemID: block.itemID, delta: t)) }
            default: break
            }
        default: break
        }
    }

    private func handleAssistant(_ msg: JSONValue) {
        if let parent = msg["parent_tool_use_id"]?.string {
            handleSubagentMessage(msg, parentToolUseID: parent)
            return
        }
        beginAutoTurnIfIdle()
        let message = msg["message"]
        let mid = message?["id"]?.string ?? UUID().uuidString
        for block in message?["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "text":
                let text = block["text"]?.string ?? ""
                let k = finalTextCount[mid, default: 0]
                finalTextCount[mid] = k + 1
                let id = streamedTextOrder[mid].flatMap { $0.indices.contains(k) ? $0[k] : nil } ?? "\(mid)-t\(k)"
                emit(.upsert(TranscriptItem(id: id, kind: .assistant(text: text))))
            case "thinking":
                let text = block["thinking"]?.string ?? ""
                let k = finalThinkingCount[mid, default: 0]
                finalThinkingCount[mid] = k + 1
                let id = streamedThinkingOrder[mid].flatMap { $0.indices.contains(k) ? $0[k] : nil } ?? "\(mid)-r\(k)"
                if !text.isEmpty { emit(.upsert(TranscriptItem(id: id, kind: .reasoning(text: text)))) }
            case "tool_use":
                guard let id = block["id"]?.string else { continue }
                let name = block["name"]?.string ?? "Tool"
                let input = block["input"] ?? .object([:])
                let call = ToolSummaries.claudeTool(name: name, input: input)
                let item = TranscriptItem(id: id, kind: .tool(call))
                tools[id] = item
                emit(.upsert(item))
            default: break
            }
        }
    }

    // MARK: subagents

    /// Claude continued without a user message (a background agent finished, a wakeup fired…).
    private func beginAutoTurnIfIdle() {
        guard !turnRunning else { return }
        turnRunning = true
        // Claude Code answers each completion notice with its own turn, in order.
        let reason = pendingNotices.isEmpty ? "Continuing in the background" : pendingNotices.removeFirst()
        emit(.autoTurnStarted(reason: reason))
    }

    private func handleTask(_ msg: JSONValue) {
        guard let id = msg["task_id"]?.string else { return }
        var task = tasks[id] ?? AgentTask(id: id, description: msg["description"]?.string ?? "Agent")
        if let tool = msg["tool_use_id"]?.string {
            task.toolUseID = tool
            taskByToolUse[tool] = id
        }
        if let usage = msg["usage"] {
            task.toolUses = usage["tool_uses"]?.int ?? task.toolUses
            task.totalTokens = usage["total_tokens"]?.int ?? task.totalTokens
        }
        switch msg["subtype"]?.string {
        case "task_started":
            task.description = msg["description"]?.string ?? task.description
            task.subagentType = msg["subagent_type"]?.string
            task.prompt = msg["prompt"]?.string ?? task.prompt
            task.isBackground = msg["is_backgrounded"]?.bool ?? false
            task.startedAt = .now
        case "task_progress":
            task.activity = msg["description"]?.string ?? task.activity
            if let summary = msg["summary"]?.string { task.summary = summary }
        case "task_updated":
            if let status = msg["patch"]?["status"]?.string { apply(status: status, to: &task) }
            if let bg = msg["patch"]?["is_backgrounded"]?.bool { task.isBackground = bg }
        case "task_notification":
            apply(status: msg["status"]?.string ?? "completed", to: &task)
            if let summary = msg["summary"]?.string, !summary.isEmpty { task.summary = summary }
            let verb = task.status == .completed ? "finished" : task.status == .failed ? "failed" : "stopped"
            pendingNotices.append("Agent “\(task.description)” \(verb)")
        default:
            break
        }
        tasks[id] = task
        emit(.task(task))
    }

    private func apply(status: String, to task: inout AgentTask) {
        switch status {
        case "completed": task.status = .completed
        case "failed": task.status = .failed
        case "stopped", "killed": task.status = .stopped
        default: task.status = .running
        }
        if task.status != .running, task.endedAt == nil { task.endedAt = .now }
    }

    /// Messages a subagent produced (tool calls, text) arrive tagged with its Agent tool call id.
    private func handleSubagentMessage(_ msg: JSONValue, parentToolUseID: String) {
        guard let taskID = taskByToolUse[parentToolUseID], var task = tasks[taskID] else { return }
        for block in msg["message"]?["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "tool_use":
                let call = ToolSummaries.claudeTool(name: block["name"]?.string ?? "Tool", input: block["input"] ?? [:])
                task.steps.append(AgentTask.Step(name: call.name, summary: call.summary))
                if task.steps.count > 40 { task.steps.removeFirst(task.steps.count - 40) }
            case "text":
                if let text = block["text"]?.string, !text.isEmpty { task.output = text }
            default:
                break
            }
        }
        tasks[taskID] = task
        emit(.task(task))
    }

    private func handleUser(_ msg: JSONValue) {
        guard msg["parent_tool_use_id"]?.isNull ?? true else { return }
        guard let blocks = msg["message"]?["content"]?.array else { return }
        for block in blocks where block["type"]?.string == "tool_result" {
            guard let toolID = block["tool_use_id"]?.string, var item = tools[toolID],
                case .tool(var call) = item.kind
            else { continue }
            call.output = ToolSummaries.flattenToolResult(block["content"])
            call.status = (block["is_error"]?.bool ?? false) ? .failed : .completed
            if let structured = msg["tool_use_result"] {
                let changes = ToolSummaries.claudeFileChanges(toolName: call.name, input: call.input, result: structured)
                if !changes.isEmpty { call.fileChanges = changes }
            }
            item.kind = .tool(call)
            tools[toolID] = item
            emit(.upsert(item))
        }
    }

    private func handleResult(_ msg: JSONValue) {
        finishRunningTools(status: .completed)
        let interrupted = interruptRequested && msg["subtype"]?.string != "success"
        interruptRequested = false
        let isError = !interrupted && (msg["is_error"]?.bool ?? (msg["subtype"]?.string != "success"))
        let usage = msg["usage"]
        let input =
            (usage?["input_tokens"]?.int ?? 0) + (usage?["cache_read_input_tokens"]?.int ?? 0)
            + (usage?["cache_creation_input_tokens"]?.int ?? 0)
        let summary = TurnSummary(
            durationMs: msg["duration_ms"]?.int,
            costUSD: msg["total_cost_usd"]?.double,
            inputTokens: input,
            outputTokens: usage?["output_tokens"]?.int,
            isError: isError,
            message: interrupted ? "Interrupted" : (isError ? (msg["result"]?.string ?? msg["subtype"]?.string) : nil)
        )
        turnRunning = false
        emit(.status(nil))
        emit(.turnEnded(summary))
    }

    private func finishRunningTools(status: ToolCall.Status) {
        for (id, var item) in tools {
            guard case .tool(var call) = item.kind, call.status == .running else { continue }
            call.status = status
            item.kind = .tool(call)
            tools[id] = item
            emit(.upsert(item))
        }
    }

    private func handleControlResponse(_ msg: JSONValue) {
        guard let resp = msg["response"], let id = resp["request_id"]?.string,
            let cont = pendingControl.removeValue(forKey: id)
        else { return }
        if resp["subtype"]?.string == "error" {
            cont.resume(throwing: AgentError(resp["error"]?.string ?? "control request failed"))
        } else {
            cont.resume(returning: resp["response"] ?? .null)
        }
    }

    private func handleControlRequest(_ msg: JSONValue) {
        guard let requestID = msg["request_id"]?.string, let req = msg["request"] else { return }
        switch req["subtype"]?.string {
        case "can_use_tool":
            let tool = req["tool_name"]?.string ?? "Tool"
            let input = req["input"] ?? .object([:])
            let toolUseID = req["tool_use_id"]?.string
            pendingPermissions[requestID] = (tool, input, toolUseID)
            var approval: ApprovalRequest
            if tool == "AskUserQuestion" {
                let questions = (input["questions"]?.array ?? []).enumerated().map { i, q in
                    AgentQuestion(
                        id: "q\(i)", header: q["header"]?.string ?? "",
                        question: q["question"]?.string ?? "",
                        options: (q["options"]?.array ?? []).map {
                            .init(label: $0["label"]?.string ?? "", description: $0["description"]?.string)
                        },
                        multiSelect: q["multiSelect"]?.bool ?? false)
                }
                approval = ApprovalRequest(
                    requestID: requestID, title: "Claude has a question", detail: "", questions: questions)
            } else {
                let call = ToolSummaries.claudeTool(name: tool, input: input)
                var detail = call.summary
                if let reason = req["decision_reason"]?.string, !reason.isEmpty {
                    detail += "\n\n" + ANSIStrip.strip(reason)
                }
                approval = ApprovalRequest(
                    requestID: requestID, title: req["title"]?.string ?? "Allow \(req["display_name"]?.string ?? tool)?",
                    detail: detail)
            }
            let item = TranscriptItem(id: "approval-\(requestID)", kind: .approval(approval))
            approvalItems[requestID] = item
            emit(.upsert(item))
        default:
            // Hook callbacks, MCP messages, elicitation, dialogs: not supported yet. Answer so nothing hangs.
            writeControlError(requestID: requestID, message: "Not supported by this client")
        }
    }

    private func resolveApproval(_ requestID: String, resolution: ApprovalRequest.Resolution, answers: [String: String]) {
        guard var item = approvalItems.removeValue(forKey: requestID), case .approval(var req) = item.kind else {
            return
        }
        req.resolution = resolution
        req.answers = answers
        item.kind = .approval(req)
        emit(.upsert(item))
    }
}

enum ANSIStrip {
    static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
