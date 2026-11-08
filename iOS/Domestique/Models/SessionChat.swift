import AgentKit
import DQCore
import Foundation
import Observation
import ServerKit

/// One session's transcript and live state, folded from its the Domestique protocol stream. Mirrors the Mac app's
/// ChatModel (server path): replay, then live events; resumes from the last seq after reconnects.
@MainActor @Observable
final class SessionChat {
    let sessionID: String
    let server: ServerConnection

    private(set) var items: [TranscriptItem] = []
    private var index: [String: Int] = [:]
    private(set) var loaded = false
    private(set) var isRunning = false
    private(set) var status: String?
    private(set) var turnStartedAt: Date?
    private(set) var tasks: [String: AgentTask] = [:]
    private(set) var loadError: String?
    var draft = ""
    /// A prompt sent before the worktree was ready, held here until it is.
    private(set) var queuedPrompt: String?
    private var queueTask: Task<Void, Never>?

    private var lastSeq: UInt64 = 0
    /// Items collected during the first replay, shown in one go at ReplayDone.
    private var replayBuffer: [TranscriptItem]?
    private var followTask: Task<Void, Never>?

    init(sessionID: String, server: ServerConnection) {
        self.sessionID = sessionID
        self.server = server
    }

    var session: Proto_Session? { server.sessions[sessionID] }
    var provider: ProviderKind { session?.providerKind ?? .claude }
    var workspace: Proto_Workspace? { session.flatMap { server.workspaces[$0.workspaceID] } }

    var currentModel: ModelOption? {
        let models = server.models[provider] ?? []
        return models.first { $0.id == session?.model } ?? models.first(where: \.isDefault)
    }

    /// The worktree doesn't exist yet, so the agent can't start.
    private var isProvisioning: Bool { workspace?.state == .creating || workspace?.state == .settingUp }

    /// Pending approvals and questions, oldest first.
    var pendingApprovals: [(id: String, request: ApprovalRequest)] {
        items.compactMap { item in
            if case .approval(let a) = item.kind, a.resolution == .pending { return (item.id, a) }
            return nil
        }
    }

    var runningTasks: [AgentTask] {
        tasks.values.filter(\.isRunning).sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: Stream

    func follow() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in await self?.followLoop() }
    }

    func stop() {
        followTask?.cancel()
        followTask = nil
    }

    private func followLoop() async {
        var notFound = 0
        while !Task.isCancelled {
            do {
                let client = try await server.ready()
                replayBuffer = lastSeq == 0 ? [] : nil
                let sub = try await client.subscribeSession(sessionID, fromSeq: lastSeq)
                loadError = nil
                await withTaskCancellationHandler {
                    for await event in sub.events {
                        self.apply(event)
                        self.lastSeq = max(self.lastSeq, event.seq)
                    }
                } onCancel: {
                    sub.cancel()
                }
                // Ended: the client was replaced (reconnect from the foreground) or the session closed.
                if server.sessions[sessionID] == nil && server.loaded { return }
            } catch let e as ServerError where e.code == .notFound {
                // A session that's still being opened.
                notFound += 1
                if notFound > 20 {
                    loadError = "This chat is gone from \(server.name)."
                    return
                }
            } catch {
                loadError = error.localizedDescription
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(notFound > 0 ? 250 : 1500))
        }
    }

    private func apply(_ event: Proto_Event) {
        switch event.payload {
        case .itemUpserted(let r):
            guard let item = TranscriptItem(proto: r) else { return }
            if replayBuffer != nil { replayBuffer?.append(item) } else { upsert(item) }
        case .appendText(let a):
            if let i = replayBuffer?.lastIndex(where: { $0.id == a.itemID }) {
                replayBuffer?[i] = Self.appending(a.delta, to: replayBuffer![i])
            } else if let i = index[a.itemID] {
                items[i] = Self.appending(a.delta, to: items[i])
            }
        case .replayDone:
            if let buffer = replayBuffer {
                replayBuffer = nil
                for item in buffer { upsert(item) }
            }
            loaded = true
            isRunning = session.map { $0.activity == .running || $0.activity == .awaitingInput } ?? false
            status = session.flatMap { $0.status.isEmpty ? nil : $0.status }
            turnStartedAt = isRunning ? (turnStartedAt ?? .now) : nil
        case .turnStarted, .autoTurnStarted:
            isRunning = true
            turnStartedAt = turnStartedAt ?? .now
        case .turnEnded:
            isRunning = false
            status = nil
            turnStartedAt = nil
        case .status(let s):
            status = s.text.isEmpty ? nil : s.text
        case .task(let t):
            let task = AgentTask(proto: t)
            tasks[task.id] = task
        case .models(let list):
            server.updateModels(list.models.map(ModelOption.init(proto:)), for: provider)
        case .exited:
            isRunning = false
            status = nil
            turnStartedAt = nil
        default:
            break
        }
    }

    private func upsert(_ item: TranscriptItem) {
        if let i = index[item.id] {
            items[i] = item
        } else {
            index[item.id] = items.count
            items.append(item)
        }
    }

    private static func appending(_ delta: String, to item: TranscriptItem) -> TranscriptItem {
        var item = item
        switch item.kind {
        case .assistant(let t): item.kind = .assistant(text: t + delta)
        case .reasoning(let t): item.kind = .reasoning(text: t + delta)
        case .tool(var call):
            call.output += delta
            if call.output.count > 200_000 { call.output = String(call.output.suffix(150_000)) }
            item.kind = .tool(call)
        default: break
        }
        return item
    }

    // MARK: Actions

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        submit(text)
    }

    /// Sends `text` as the next user message, leaving the composer alone.
    func submit(_ text: String) {
        isRunning = true
        turnStartedAt = turnStartedAt ?? .now
        guard isProvisioning else { return deliver(text) }
        queuedPrompt = text
        queueTask = Task { [weak self] in
            while self?.isProvisioning == true {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.queuedPrompt = nil
            if self.workspace?.state == .failed {
                // The server has already put the failure in the transcript.
                self.draft = text
                self.isRunning = false
                self.turnStartedAt = nil
            } else {
                self.deliver(text)
            }
        }
    }

    private func deliver(_ text: String) {
        perform { try await $0.sendMessage(sessionID: $1, text: text) } onError: { [weak self] in
            self?.draft = text
            self?.isRunning = false
        }
    }

    func interrupt() {
        if let prompt = queuedPrompt {
            queueTask?.cancel()
            queuedPrompt = nil
            draft = prompt
            isRunning = false
            turnStartedAt = nil
            return
        }
        perform { try await $0.interrupt(sessionID: $1) }
    }

    func respond(_ requestID: String, _ decision: ApprovalDecision) {
        let (d, message) = decision.proto
        perform { try await $0.respondApproval(sessionID: $1, requestID: requestID, decision: d, message: message) }
    }

    func answer(_ requestID: String, _ answers: [String: String]) {
        perform { try await $0.answerQuestion(sessionID: $1, requestID: requestID, answers: answers) }
    }

    func update(model: String? = nil, effort: String? = nil, permission: AgentPermissionMode? = nil) {
        var req = Proto_UpdateSession()
        req.sessionID = sessionID
        if let model { req.model = model }
        if let effort { req.effort = effort }
        if let permission { req.permissionMode = permission.proto }
        let update = req
        perform { c, _ in _ = try await c.updateSession(update) }
    }

    private func perform(
        _ call: @escaping @Sendable (ServerClient, String) async throws -> Void, onError: (@MainActor () -> Void)? = nil
    ) {
        let id = sessionID
        Task {
            do {
                try await call(try await server.ready(), id)
            } catch {
                onError?()
                upsert(TranscriptItem(id: "local-error-\(UUID())", kind: .error(text: error.localizedDescription)))
            }
        }
    }
}
