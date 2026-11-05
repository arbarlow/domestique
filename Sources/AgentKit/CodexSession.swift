import DQCore
import Foundation

/// One Codex thread on the shared app-server.
public actor CodexSession: AgentSession, CodexThreadHandler {
    public nonisolated let provider: ProviderKind = .codex
    public nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    private var config: AgentSessionConfig
    private var threadID: String?
    private var attached = false
    private var turnID: String?
    private var lastUsage: (input: Int, output: Int)?
    private var pendingApprovals: [String: (method: String, params: JSONValue, item: TranscriptItem)] = [:]
    private var approvalCounter = 0

    public init(config: AgentSessionConfig) {
        self.config = config
        self.threadID = config.resumeSessionID
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    private func emit(_ e: AgentEvent) { continuation.yield(e) }

    // MARK: policy mapping

    private var approvalPolicy: JSONValue {
        config.permissionMode == .bypass ? "never" : "on-request"
    }

    private var sandboxMode: JSONValue {
        config.permissionMode == .bypass ? "danger-full-access" : "workspace-write"
    }

    private var reviewer: JSONValue {
        config.permissionMode == .auto ? "auto_review" : "user"
    }

    private var sandboxPolicy: JSONValue {
        if config.permissionMode == .bypass { return ["type": "dangerFullAccess"] }
        return [
            "type": "workspaceWrite",
            "writableRoots": .array(([config.cwd] + config.extraWritableRoots).map { .string($0) }),
            "networkAccess": true,
            "excludeTmpdirEnvVar": false,
            "excludeSlashTmp": false,
        ]
    }

    // MARK: thread

    private func ensureThread() async throws -> String {
        let server = CodexAppServer.server(for: config.host)
        if let threadID, attached { return threadID }
        var params: [String: JSONValue] = [
            "cwd": .string(config.cwd),
            "approvalPolicy": approvalPolicy,
            "approvalsReviewer": reviewer,
            "sandbox": sandboxMode,
        ]
        if let model = config.model { params["model"] = .string(model) }
        if let prompt = config.appendSystemPrompt, !prompt.isEmpty { params["developerInstructions"] = .string(prompt) }

        let result: JSONValue
        if let threadID {
            params["threadId"] = .string(threadID)
            params["excludeTurns"] = true
            do {
                result = try await server.request("thread/resume", .object(params))
            } catch {
                // Thread vanished (e.g. archived): start fresh rather than wedging the tab.
                params["threadId"] = nil
                params["excludeTurns"] = nil
                emit(.upsert(TranscriptItem(id: "notice-\(UUID())", kind: .notice(text: "Couldn't resume previous Codex thread; starting a new one."))))
                result = try await server.request("thread/start", .object(params))
            }
        } else {
            result = try await server.request("thread/start", .object(params))
        }
        guard let id = result["thread"]?["id"]?.string else { throw AgentError("Codex didn't return a thread id") }
        threadID = id
        attached = true
        await server.register(threadID: id, handler: self)
        emit(.started(sessionID: id, model: result["model"]?.string ?? result["thread"]?["model"]?.string))
        return id
    }

    // MARK: AgentSession

    public func send(_ text: String, attachments: [AgentAttachment]) async throws {
        let tid = try await ensureThread()
        var input: [JSONValue] = [["type": "text", "text": .string(text), "text_elements": []]]
        for a in attachments where a.mediaType.hasPrefix("image/") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dq-\(UUID().uuidString)-\(a.filename)")
            try? a.data.write(to: url)
            input.append(["type": "localImage", "path": .string(url.path)])
        }
        if let turnID {
            _ = try await CodexAppServer.server(for: config.host).request(
                "turn/steer", ["threadId": .string(tid), "expectedTurnId": .string(turnID), "input": .array(input)])
            return
        }
        var params: [String: JSONValue] = [
            "threadId": .string(tid),
            "input": .array(input),
            "approvalPolicy": approvalPolicy,
            "approvalsReviewer": reviewer,
            "sandboxPolicy": sandboxPolicy,
        ]
        if let model = config.model { params["model"] = .string(model) }
        if let effort = config.effort { params["effort"] = .string(effort) }
        emit(.turnStarted)
        do {
            let result = try await CodexAppServer.server(for: config.host).request("turn/start", .object(params))
            if let id = result["turn"]?["id"]?.string { turnID = id }
        } catch {
            emit(.turnEnded(TurnSummary(isError: true, message: error.localizedDescription)))
            throw error
        }
    }

    public func interrupt() async {
        guard let threadID, let turnID else { return }
        _ = try? await CodexAppServer.server(for: config.host).request(
            "turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)])
    }

    public func respond(requestID: String, decision: ApprovalDecision) async {
        // handleServerRequest is suspended waiting for this.
        decisions[requestID]?.resume(returning: .decision(decision))
        decisions[requestID] = nil
    }

    public func answer(requestID: String, answers: [String: String]) async {
        decisions[requestID]?.resume(returning: .answers(answers))
        decisions[requestID] = nil
    }

    public func setPermissionMode(_ mode: AgentPermissionMode) async {
        config.permissionMode = mode  // applied on the next turn/start
    }

    public func setModel(_ model: String?) async {
        config.model = model
    }

    public func setEffort(_ effort: String?) async {
        config.effort = effort  // applied on the next turn/start
    }

    public func shutdown() async {
        if let threadID {
            await CodexAppServer.server(for: config.host).unregister(threadID: threadID)
            _ = try? await CodexAppServer.server(for: config.host).request("thread/unsubscribe", ["threadId": .string(threadID)])
        }
        attached = false
        for (_, c) in decisions { c.resume(returning: .decision(.deny(message: nil))) }
        decisions.removeAll()
    }

    // MARK: notifications

    func handleNotification(method: String, params: JSONValue) async {
        switch method {
        case "turn/started":
            turnID = params["turn"]?["id"]?.string ?? turnID
        case "turn/completed":
            turnID = nil
            let turn = params["turn"]
            let errorMessage = turn?["error"]?["message"]?.string
            let status = turn?["status"]?.string
            emit(.status(nil))
            emit(
                .turnEnded(
                    TurnSummary(
                        durationMs: turn?["durationMs"]?.int, inputTokens: lastUsage?.input,
                        outputTokens: lastUsage?.output, isError: errorMessage != nil || status == "failed",
                        message: errorMessage ?? (status == "interrupted" ? "Interrupted" : nil))))
        case "item/started", "item/completed":
            guard let item = params["item"], let id = item["id"]?.string,
                let kind = ToolSummaries.codexItem(item)
            else { return }
            emit(.upsert(TranscriptItem(id: id, kind: kind)))
        case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/commandExecution/outputDelta",
            "item/plan/delta":
            if let id = params["itemId"]?.string, let delta = params["delta"]?.string {
                emit(.appendText(itemID: id, delta: delta))
            }
        case "item/reasoning/summaryPartAdded":
            if let id = params["itemId"]?.string { emit(.appendText(itemID: id, delta: "\n\n")) }
        case "thread/tokenUsage/updated":
            if let total = params["tokenUsage"]?["last"] {
                lastUsage = (total["inputTokens"]?.int ?? 0, total["outputTokens"]?.int ?? 0)
            }
        case "error":
            let message = params["error"]?["message"]?.string ?? "Codex error"
            if params["willRetry"]?.bool == true {
                emit(.status("\(message) — retrying"))
            } else {
                emit(.upsert(TranscriptItem(id: "error-\(UUID())", kind: .error(text: message))))
            }
        case "model/rerouted":
            if let to = params["toModel"]?.string ?? params["model"]?.string {
                emit(.upsert(TranscriptItem(id: "notice-\(UUID())", kind: .notice(text: "Model rerouted to \(to)"))))
            }
        case "thread/compacted":
            emit(.upsert(TranscriptItem(id: "notice-\(UUID())", kind: .notice(text: "Context compacted"))))
        default:
            break
        }
    }

    func serverExited(message: String?) async {
        attached = false
        if turnID != nil {
            turnID = nil
            emit(.turnEnded(TurnSummary(isError: true, message: "Codex exited")))
        }
        emit(.exited(message: message))
    }

    // MARK: server requests (approvals / questions)

    private enum Reply: Sendable {
        case decision(ApprovalDecision)
        case answers([String: String])
    }

    private var decisions: [String: CheckedContinuation<Reply, Never>] = [:]

    func handleServerRequest(method: String, params: JSONValue) async -> JSONValue? {
        approvalCounter += 1
        let requestID = "codex-\(approvalCounter)-\(params["itemId"]?.string ?? "")"
        let approval: ApprovalRequest
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let cmd = params["command"]?.string ?? params["command"]?.array?.compactMap(\.string).joined(separator: " ") ?? ""
            var detail = ToolSummaries.unwrapShell(cmd)
            if let reason = params["reason"]?.string { detail += "\n\n\(reason)" }
            approval = ApprovalRequest(requestID: requestID, title: "Run command?", detail: detail)
        case "item/fileChange/requestApproval", "applyPatchApproval":
            approval = ApprovalRequest(
                requestID: requestID, title: "Apply file changes?", detail: params["reason"]?.string ?? "")
        case "item/permissions/requestApproval":
            approval = ApprovalRequest(
                requestID: requestID, title: "Grant extra permissions?",
                detail: [params["reason"]?.string, params["permissions"]?.prettyString].compactMap { $0 }.joined(
                    separator: "\n\n"))
        case "item/tool/requestUserInput":
            let questions = (params["questions"]?.array ?? []).map { q in
                AgentQuestion(
                    id: q["id"]?.string ?? UUID().uuidString, header: q["header"]?.string ?? "",
                    question: q["question"]?.string ?? "",
                    options: (q["options"]?.array ?? []).map {
                        .init(label: $0["label"]?.string ?? "", description: $0["description"]?.string)
                    })
            }
            approval = ApprovalRequest(requestID: requestID, title: "Codex has a question", detail: "", questions: questions)
        default:
            return nil
        }
        let item = TranscriptItem(id: "approval-\(requestID)", kind: .approval(approval))
        pendingApprovals[requestID] = (method, params, item)
        emit(.upsert(item))

        let reply = await withCheckedContinuation { (c: CheckedContinuation<Reply, Never>) in
            decisions[requestID] = c
        }
        pendingApprovals[requestID] = nil

        var resolved = approval
        let result: JSONValue
        switch (method, reply) {
        case ("item/tool/requestUserInput", .answers(let answers)):
            resolved.resolution = .answered
            resolved.answers = answers
            var map: [String: JSONValue] = [:]
            for (k, v) in answers { map[k] = ["answers": [.string(v)]] }
            result = ["answers": .object(map)]
        case ("item/tool/requestUserInput", _):
            resolved.resolution = .denied
            result = ["answers": [:]]
        case ("item/permissions/requestApproval", .decision(let d)):
            switch d {
            case .approve, .approveForSession:
                resolved.resolution = .approved
                result = [
                    "permissions": params["permissions"] ?? [:],
                    "scope": d.isSession ? "session" : "turn",
                ]
            case .deny:
                resolved.resolution = .denied
                result = ["permissions": [:], "scope": "turn"]
            }
        case ("execCommandApproval", .decision(let d)), ("applyPatchApproval", .decision(let d)):
            resolved.resolution = d.resolution
            result = [
                "decision": d.isApproval
                    ? (d.isSession ? "approved_for_session" : "approved")
                    : ["denied": ["rejection": .string(d.denyMessage ?? "User declined")]]
            ]
        case (_, .decision(let d)):
            resolved.resolution = d.resolution
            result = ["decision": d.isApproval ? (d.isSession ? "acceptForSession" : "accept") : "decline"]
        case (_, .answers):
            resolved.resolution = .denied
            result = ["decision": "decline"]
        }
        emit(.upsert(TranscriptItem(id: item.id, timestamp: item.timestamp, kind: .approval(resolved))))
        return result
    }
}

extension ApprovalDecision {
    var isApproval: Bool {
        if case .deny = self { return false }
        return true
    }
    var isSession: Bool {
        if case .approveForSession = self { return true }
        return false
    }
    var denyMessage: String? {
        if case .deny(let m) = self { return m }
        return nil
    }
    var resolution: ApprovalRequest.Resolution {
        switch self {
        case .approve: .approved
        case .approveForSession: .approvedForSession
        case .deny: .denied
        }
    }
}
