import AgentKit
import DQCore
import Foundation
import HostKit
import Observation
import ServerKit

/// One chat tab: transcript + a lazily-started provider session.
@MainActor
@Observable
final class ChatModel {
    let tabID: UUID
    @ObservationIgnored unowned let workspace: WorkspaceModel

    private(set) var items: [TranscriptItem] = []
    private(set) var isRunning = false
    private(set) var status: String?
    private(set) var loaded = false
    private(set) var turnStartedAt: Date?
    /// Subagents spawned in this chat, by task id (live; not persisted — results land in the Agent tool item).
    private(set) var tasks: [String: AgentTask] = [:]
    private(set) var taskOrder: [String] = []
    /// Subagents the user hasn't dismissed from the tray yet.
    var trayTaskIDs: [String] = []

    var runningTasks: [AgentTask] { taskOrder.compactMap { tasks[$0] }.filter(\.isRunning) }
    var trayTasks: [AgentTask] { trayTaskIDs.compactMap { tasks[$0] } }
    func task(forToolUse id: String) -> AgentTask? { tasks.values.first { $0.toolUseID == id } }

    func clearFinishedFromTray() {
        trayClearTask?.cancel()
        let finished = Set(tasks.values.filter { !$0.isRunning }.map(\.id))
        trayTaskIDs.removeAll { finished.contains($0) }
    }

    /// Once every subagent in the tray has finished, hold the "all done" state briefly, then fade the tray
    /// away. Results stay inline in the transcript on each Agent tool card. A new subagent cancels this.
    private func scheduleTrayAutoClear() {
        trayClearTask?.cancel()
        guard !trayTasks.isEmpty, !trayTasks.contains(where: \.isRunning) else { return }
        trayClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, !self.trayTasks.contains(where: \.isRunning) else { return }
            self.clearFinishedFromTray()
        }
    }
    var draft = ""
    var attachments: [AgentAttachment] = []

    /// A follow-up typed while the agent is mid-turn. It waits here (so the live turn stays expanded)
    /// and goes out when the turn ends, unless the user steers it in now.
    struct QueuedMessage: Identifiable {
        let id = UUID()
        var text: String
        var attachments: [AgentAttachment]
    }
    private(set) var queued: [QueuedMessage] = []

    @ObservationIgnored private var index: [String: Int] = [:]
    @ObservationIgnored private var session: (any AgentSession)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDeltas: [(String, String)] = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var lastCost: Double = 0
    @ObservationIgnored private var trayClearTask: Task<Void, Never>?

    /// Local workspaces: the agent runs in the server as a session with this tab's id; this model follows
    /// its transcript and sends it requests. Cloud workspaces still run the agent in-app.
    @ObservationIgnored let viaServer: Bool
    /// The server this chat's session lives on (This Mac's or a remote one).
    @ObservationIgnored private let link: ServerLink?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    /// Items collected during the first replay (assigned in one go, not item by item).
    @ObservationIgnored private var replayBuffer: [TranscriptItem]?

    init(tabID: UUID, workspace: WorkspaceModel) {
        self.tabID = tabID
        self.workspace = workspace
        link = workspace.app.link(for: workspace.workspace)
        viaServer = link != nil
    }

    var tab: ChatTab? { workspace.workspace?.tabs.first { $0.id == tabID } }

    private func updateTab(_ mutate: (inout ChatTab) -> Void) {
        workspace.app.updateWorkspace(workspace.id) { ws in
            guard let i = ws.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            mutate(&ws.tabs[i])
        }
    }

    var hasMessages: Bool { !items.isEmpty }

    // MARK: loading

    @ObservationIgnored private var lastRowID: Int64 = 0

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if viaServer {
            followSession()
            return
        }
        let id = tabID
        Task {
            let (stored, maxRow) = await Store.shared.transcriptItems(tabID: id, afterRowID: 0)
            self.lastRowID = maxRow
            // Anything left "pending"/"running" belongs to a process that's gone.
            let fixed = stored.map(Self.settle)
            self.items = fixed + self.items
            self.rebuildIndex()
        }
    }

    /// Pull items another instance saved for this tab (only while this instance isn't driving it).
    func syncFromStore() {
        guard !viaServer, loaded, session == nil || !isRunning, pendingDeltas.isEmpty, dirty.isEmpty else { return }
        let id = tabID
        let after = lastRowID
        Task {
            let (fresh, maxRow) = await Store.shared.transcriptItems(tabID: id, afterRowID: after)
            self.lastRowID = max(self.lastRowID, maxRow)
            guard !fresh.isEmpty else { return }
            for item in fresh {
                if let i = self.index[item.id] {
                    self.items[i] = item
                } else {
                    self.index[item.id] = self.items.count
                    self.items.append(item)
                }
            }
        }
    }

    private static func settle(_ item: TranscriptItem) -> TranscriptItem {
        var item = item
        switch item.kind {
        case .tool(var call) where call.status == .running:
            call.status = .failed
            item.kind = .tool(call)
        case .approval(var req) where req.resolution == .pending:
            req.resolution = .cancelled
            item.kind = .approval(req)
        default: break
        }
        return item
    }

    private func rebuildIndex() {
        index.removeAll(keepingCapacity: true)
        for (i, item) in items.enumerated() { index[item.id] = i }
    }

    // MARK: session

    private func ensureSession() -> any AgentSession {
        if let session { return session }
        guard let tab, let ws = workspace.workspace, let repo = workspace.repo else {
            fatalError("chat without workspace")
        }
        var env = WorkspaceEnvironment.variables(workspace: ws, repo: repo)
        env["DOMESTIQUE_TAB"] = tab.id.uuidString
        var config = AgentSessionConfig(
            cwd: ws.path,
            model: tab.model,
            effort: tab.effort,
            permissionMode: tab.permissionMode,
            resumeSessionID: tab.providerSessionID,
            environment: env,
            // A cloud clone is self-contained; a local worktree writes into the main repo's .git.
            extraWritableRoots: ws.isRemote ? [] : [repo.path + "/.git"],
            appendSystemPrompt: Self.systemPrompt(ws: ws, repo: repo),
            host: workspace.host
        )
        if let boat = workspace.host as? BoatHost {
            let app = workspace.app
            let server = app.settings.provider(for: ws.host)?.home ?? .thisMac
            config.mcpConfig = { await app.syncMCPConfig(to: boat, server: server) }
        }
        let s = AgentFactory.makeSession(provider: tab.provider, config: config)
        session = s
        eventTask = Task { [weak self] in
            for await event in s.events {
                guard let self else { return }
                self.apply(event)
            }
        }
        return s
    }

    static func systemPrompt(ws: Workspace, repo: Repository) -> String {
        if let h = ws.host {
            return """
                You are working inside Domestique, in a \(h.provider.displayName) cloud sandbox (\(h.machineID), Ubuntu) with a clone of the "\(repo.name)" repository.
                - Clone: \(ws.path)
                - Branch: \(ws.branch) (branched from origin/\(repo.defaultBranch))
                - This workspace owns ports \(ws.portBase)-\(ws.portBase + 9) ($DOMESTIQUE_PORT is the first). Use them for dev servers. Domestique forwards every port you listen on to the same port on the user's Mac, so http://localhost:<port> works for them as-is. Binding 127.0.0.1 is fine.
                - Docker is available. You have sudo.
                - The user previews, runs tasks, and ships (PR or push to \(repo.defaultBranch)) from the Domestique UI, so don't push or open PRs unless asked.
                """
        }
        return """
        You are working inside Domestique, in an isolated git worktree for the "\(repo.name)" repository.
        - Worktree: \(ws.path)
        - Branch: \(ws.branch) (branched from origin/\(repo.defaultBranch))
        - This workspace owns ports \(ws.portBase)-\(ws.portBase + 9) ($DOMESTIQUE_PORT is the first). Use them for any dev servers so parallel workspaces don't collide.
        - The user previews, runs tasks, and ships (a pull request, or a push straight to the default branch) from the Domestique UI, so don't push or open PRs unless asked.
        """
    }

    /// Send the composer's draft. Mid-turn it's queued for when the turn ends; `steer` sends it now.
    func send(steer: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let files = attachments
        draft = ""
        attachments = []
        if isRunning, !steer {
            queued.append(QueuedMessage(text: text, attachments: files))
        } else {
            send(text: text, attachments: files)
        }
    }

    /// Send a queued follow-up into the running turn right away.
    func steer(_ id: UUID) {
        guard let i = queued.firstIndex(where: { $0.id == id }) else { return }
        let m = queued.remove(at: i)
        send(text: m.text, attachments: m.attachments)
    }

    func removeQueued(_ id: UUID) {
        queued.removeAll { $0.id == id }
    }

    /// Pull a queued follow-up back into the composer to edit it.
    func editQueued(_ id: UUID) {
        guard let i = queued.firstIndex(where: { $0.id == id }) else { return }
        let m = queued.remove(at: i)
        draft = draft.isEmpty ? m.text : m.text + "\n\n" + draft
        attachments = m.attachments + attachments
    }

    /// The turn ended: everything queued goes out together as the next message.
    private func sendQueued() {
        guard !queued.isEmpty, !isRunning else { return }
        let all = queued
        queued = []
        let text = all.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        send(text: text, attachments: all.flatMap(\.attachments))
    }

    /// Stopping the agent means "hold on": queued follow-ups go back into the composer instead of firing.
    private func restoreQueuedToDraft() {
        guard !queued.isEmpty else { return }
        let all = queued
        queued = []
        let text = all.map(\.text).filter { !$0.isEmpty }
        draft = (text + (draft.isEmpty ? [] : [draft])).joined(separator: "\n\n")
        attachments = all.flatMap(\.attachments) + attachments
    }

    func send(text: String, attachments: [AgentAttachment] = []) {
        loadIfNeeded()
        if items.isEmpty, tab?.title == "New chat" {
            let title = text.split(separator: "\n").first.map { String($0.prefix(40)) } ?? "Chat"
            updateTab { $0.title = title }
        }
        var display = text
        if !attachments.isEmpty { display += "\n\n" + attachments.map { "📎 \($0.filename)" }.joined(separator: "  ") }
        clearFinishedFromTray()
        if viaServer {
            isRunning = true
            turnStartedAt = turnStartedAt ?? .now
            let session = tabID.protoID
            let files = attachments.map { a -> Proto_Attachment in
                var r = Proto_Attachment()
                r.data = a.data
                r.mediaType = a.mediaType
                r.filename = a.filename
                return r
            }
            Task {
                do {
                    try await self.link!.ready().sendMessage(sessionID: session, text: text, attachments: files)
                } catch {
                    self.upsert(TranscriptItem(id: "error-\(UUID())", kind: .error(text: error.localizedDescription)))
                    self.isRunning = false
                    self.turnStartedAt = nil
                }
            }
            return
        }
        let item = TranscriptItem(id: "user-\(UUID().uuidString)", kind: .user(text: display))
        upsert(item)
        let session = ensureSession()
        isRunning = true
        turnStartedAt = turnStartedAt ?? .now
        Task {
            do {
                try await session.send(text, attachments: attachments)
            } catch {
                self.upsert(TranscriptItem(id: "error-\(UUID())", kind: .error(text: self.describe(error))))
                self.isRunning = false
                self.turnStartedAt = nil
            }
        }
    }

    /// Errors from a cloud machine get a hint about where to fix them.
    func describe(_ error: Error) -> String {
        let msg = error.localizedDescription
        guard workspace.isRemote else { return msg }
        let lower = msg.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("not logged in") || lower.contains("login") {
            return msg + "\n\nAgents on boat.dev sandboxes sign in with the Claude / ChatGPT accounts connected on boat.dev → Agents & Proxying (https://boat.dev/dashboard?tab=agents)."
        }
        return msg
    }

    func interrupt() {
        restoreQueuedToDraft()
        if viaServer {
            sessionCall { try await $0.interrupt(sessionID: $1) }
            return
        }
        guard let session else { return }
        Task { await session.interrupt() }
    }

    func respond(_ request: ApprovalRequest, decision: ApprovalDecision) {
        if viaServer {
            let (d, message) = decision.proto
            sessionCall { try await $0.respondApproval(sessionID: $1, requestID: request.requestID, decision: d, message: message) }
            return
        }
        guard let session else { return }
        Task { await session.respond(requestID: request.requestID, decision: decision) }
    }

    func answer(_ request: ApprovalRequest, answers: [String: String]) {
        if viaServer {
            sessionCall { try await $0.answerQuestion(sessionID: $1, requestID: request.requestID, answers: answers) }
            return
        }
        guard let session else { return }
        Task { await session.answer(requestID: request.requestID, answers: answers) }
    }

    func setPermissionMode(_ mode: AgentPermissionMode) {
        updateTab { $0.permissionMode = mode }
        if viaServer {
            var u = Proto_UpdateSession()
            u.permissionMode = mode.proto
            updateSession(u)
            return
        }
        if let session { Task { await session.setPermissionMode(mode) } }
    }

    func setModel(_ model: String?) {
        guard let tab else { return }
        updateTab { $0.model = model }
        if viaServer {
            var u = Proto_UpdateSession()
            u.model = model ?? ""
            updateSession(u)
        } else if let session { Task { await session.setModel(model) } }
        // Keep the thinking level valid for the new model.
        let option = workspace.app.resolvedModel(tab.provider, model)
        if let effort = tab.effort, let option, !option.efforts.contains(effort) {
            setEffort(nil)
        }
    }

    func setEffort(_ effort: String?) {
        updateTab { $0.effort = effort }
        if viaServer {
            var u = Proto_UpdateSession()
            u.effort = effort ?? ""
            updateSession(u)
        } else if let session { Task { await session.setEffort(effort) } }
    }

    /// Only allowed before the first message: the provider owns the conversation after that.
    func setProvider(_ provider: ProviderKind) {
        guard !hasMessages, tab?.provider != provider else { return }
        shutdown()
        updateTab {
            $0.provider = provider
            $0.model = workspace.app.defaultModel(for: provider)
            $0.effort = workspace.app.defaultEffort(for: provider)
            $0.providerSessionID = nil
        }
        if viaServer, let tab {
            // A session's provider is fixed: replace the (empty) session, keeping the tab's id.
            let link = self.link!
            let wsID = workspace.id
            Task {
                await link.replaceSession(tab, workspace: wsID)
                self.loaded = false
                self.loadIfNeeded()
            }
        }
    }

    func shutdown() {
        sessionTask?.cancel()
        sessionTask = nil
        flushDeltas()
        persistDirty()
        eventTask?.cancel()
        eventTask = nil
        trayClearTask?.cancel()
        if let session { Task { await session.shutdown() } }
        session = nil
        isRunning = false
    }

    // MARK: events

    private func apply(_ event: AgentEvent) {
        switch event {
        case .appendText(let id, let delta):
            pendingDeltas.append((id, delta))
            scheduleFlush()
            return
        default:
            flushDeltas()
        }
        switch event {
        case .started(let sessionID, _):
            if tab?.providerSessionID != sessionID { updateTab { $0.providerSessionID = sessionID } }
        case .upsert(let item):
            upsert(item)
            // `gh pr create` prints the PR URL: link it right away.
            if case .tool(let call) = item.kind, call.name == "Bash", call.status != .running, !call.output.isEmpty {
                workspace.noticePullRequestURL(in: call.output)
                workspace.noticeTrunkPush(in: call.output)
            }
            // Keep the Changes panel live while the agent edits.
            if case .tool(let call) = item.kind, call.status != .running,
                !call.fileChanges.isEmpty || ["Bash", "Edit", "Write", "MultiEdit"].contains(call.name)
            {
                workspace.scheduleDiffRefresh()
            }
            if case .approval(let req) = item.kind, req.resolution != .pending { persistDirty() }
            if case .approval(let req) = item.kind, req.resolution == .pending { workspace.agentNeedsAttention(self) }
        case .appendText:
            break
        case .turnStarted:
            isRunning = true
            turnStartedAt = turnStartedAt ?? .now
        case .turnEnded(var summary):
            if let total = summary.costUSD {
                // Claude reports cumulative session cost; show the per-turn delta.
                let delta = max(0, total - lastCost)
                lastCost = total
                summary.costUSD = delta
            }
            if summary.durationMs == nil, let start = turnStartedAt {
                summary.durationMs = Int(Date().timeIntervalSince(start) * 1000)
            }
            upsert(TranscriptItem(id: "turn-\(UUID().uuidString)", kind: .turnSummary(summary)))
            if summary.isError, workspace.isRemote, let m = summary.message {
                let hinted = describe(AgentError(m))
                if hinted != m { upsert(TranscriptItem(id: "error-\(UUID())", kind: .notice(text: String(hinted.dropFirst(m.count)).trimmingCharacters(in: .whitespacesAndNewlines)))) }
            }
            isRunning = false
            status = nil
            turnStartedAt = nil
            persistDirty()
            workspace.agentFinishedTurn(self)
            sendQueued()
        case .status(let s):
            status = s
        case .models(let models):
            if let provider = tab?.provider { workspace.app.updateModels(models, for: provider) }
        case .task(let task):
            if tasks[task.id] == nil {
                taskOrder.append(task.id)
                trayTaskIDs.append(task.id)
            }
            tasks[task.id] = task
            if task.isRunning {
                trayClearTask?.cancel()
            } else {
                if !viaServer { recordTaskResult(task) }  // Server records it on the item itself
                scheduleTrayAutoClear()
            }
        case .autoTurnStarted(let reason):
            upsert(TranscriptItem(id: "trigger-\(UUID().uuidString)", kind: .trigger(text: reason)))
            isRunning = true
            turnStartedAt = .now
        case .rateLimit(let info):
            // A sandbox's agents use the accounts connected on the provider, not this Mac's.
            if let provider = tab?.provider, !workspace.isRemote {
                workspace.app.recordUsage(info, for: provider)
            }
        case .exited(let message):
            session = nil
            eventTask = nil
            isRunning = false
            restoreQueuedToDraft()
            status = nil
            turnStartedAt = nil
            if let message {
                upsert(TranscriptItem(id: "error-\(UUID())", kind: .error(text: describe(AgentError(message)))))
            }
            persistDirty()
        }
    }

    /// Persist a finished subagent's outcome on its Agent tool item (the launch result for background
    /// agents is just "Async agent launched…").
    private func recordTaskResult(_ task: AgentTask) {
        guard let toolID = task.toolUseID, let i = index[toolID], case .tool(var call) = items[i].kind else { return }
        let result = task.summary ?? (task.output.isEmpty ? nil : task.output)
        if let result { call.output = result }
        call.status = task.status == .completed ? .completed : task.status == .failed ? .failed : .declined
        var item = items[i]
        item.kind = .tool(call)
        items[i] = item
        dirty.insert(item.id)
    }

    private func upsert(_ item: TranscriptItem) {
        if let i = index[item.id] {
            var merged = item
            merged.timestamp = items[i].timestamp
            items[i] = merged
        } else {
            index[item.id] = items.count
            items.append(item)
        }
        dirty.insert(item.id)
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            self?.flushDeltas()
        }
    }

    /// Coalesces token deltas into one mutation per frame.
    private func flushDeltas() {
        flushScheduled = false
        guard !pendingDeltas.isEmpty else { return }
        var combined: [String: String] = [:]
        var order: [String] = []
        for (id, d) in pendingDeltas {
            if combined[id] == nil { order.append(id) }
            combined[id, default: ""] += d
        }
        pendingDeltas.removeAll(keepingCapacity: true)
        for id in order {
            guard let i = index[id], let delta = combined[id] else { continue }
            var item = items[i]
            switch item.kind {
            case .assistant(let text): item.kind = .assistant(text: text + delta)
            case .reasoning(let text): item.kind = .reasoning(text: text + delta)
            case .tool(var call):
                call.output += delta
                if call.output.count > 200_000 { call.output = String(call.output.suffix(150_000)) }
                item.kind = .tool(call)
            default: continue
            }
            items[i] = item
            dirty.insert(id)
        }
    }

    private func persistDirty() {
        if viaServer {
            dirty.removeAll()  // Server persists the transcript
            return
        }
        guard !dirty.isEmpty else { return }
        let toWrite = dirty.compactMap { id in index[id].map { items[$0] } }.sorted { lhs, rhs in
            (index[lhs.id] ?? 0) < (index[rhs.id] ?? 0)
        }
        dirty.removeAll()
        let id = tabID
        Task { await Store.shared.append(toWrite, tabID: id) }
    }

    // MARK: Server session

    private func sessionCall(_ call: @escaping @Sendable (ServerClient, String) async throws -> Void) {
        let session = tabID.protoID
        let link = self.link!
        Task {
            do {
                try await call(try await link.ready(), session)
            } catch {
                self.upsert(TranscriptItem(id: "error-\(UUID())", kind: .error(text: error.localizedDescription)))
            }
        }
    }

    private func updateSession(_ update: Proto_UpdateSession) {
        var u = update
        u.sessionID = tabID.protoID
        let req = u
        sessionCall { client, _ in _ = try await client.updateSession(req) }
    }

    /// Replays the session's transcript, then follows it live. The subscription resumes by itself after a
    /// reconnect (replaying only what changed), so this runs until the chat is closed.
    private func followSession() {
        sessionTask?.cancel()
        items = []
        index = [:]
        replayBuffer = []
        let link = self.link!
        let session = tabID.protoID
        sessionTask = Task { [weak self] in
            var attempts = 0
            while !Task.isCancelled {
                do {
                    let client = try await link.ready()
                    let sub = try await client.subscribeSession(session)
                    await withTaskCancellationHandler {
                        for await event in sub.events {
                            guard let self else { return }
                            self.applySession(event)
                        }
                    } onCancel: {
                        sub.cancel()
                    }
                    return
                } catch let e as ServerError where e.code == .notFound && attempts < 20 {
                    // The session is still being opened (a new tab).
                    attempts += 1
                    try? await Task.sleep(for: .milliseconds(250))
                } catch {
                    guard let self else { return }
                    self.replayBuffer = nil
                    self.upsert(TranscriptItem(id: "error-domestique", kind: .error(text: "Couldn't load this chat from the server: \(error.localizedDescription)")))
                    return
                }
            }
        }
    }

    private func applySession(_ event: Proto_Event) {
        if case .appendText(let a) = event.payload, replayBuffer == nil {
            pendingDeltas.append((a.itemID, a.delta))
            scheduleFlush()
            return
        }
        flushDeltas()
        switch event.payload {
        case .itemUpserted(let r):
            guard let item = TranscriptItem(proto: r) else { return }
            if replayBuffer != nil {
                replayBuffer?.append(item)
                return
            }
            upsert(item)
            if case .tool(let call) = item.kind, call.name == "Bash", call.status != .running, !call.output.isEmpty {
                workspace.noticePullRequestURL(in: call.output)
                workspace.noticeTrunkPush(in: call.output)
            }
            if case .tool(let call) = item.kind, call.status != .running,
                !call.fileChanges.isEmpty || ["Bash", "Edit", "Write", "MultiEdit"].contains(call.name)
            {
                workspace.scheduleDiffRefresh()
            }
            if case .approval(let req) = item.kind, req.resolution == .pending { workspace.agentNeedsAttention(self) }
        case .replayDone:
            if let buffer = replayBuffer {
                replayBuffer = nil
                for item in buffer {
                    if let i = index[item.id] {
                        items[i] = item
                    } else {
                        index[item.id] = items.count
                        items.append(item)
                    }
                }
            }
            let running = link?.isSessionRunning(tabID) ?? false
            isRunning = running
            if !running { turnStartedAt = nil } else { turnStartedAt = turnStartedAt ?? .now }
        case .turnStarted:
            isRunning = true
            turnStartedAt = turnStartedAt ?? .now
        case .turnEnded:
            isRunning = false
            status = nil
            turnStartedAt = nil
            workspace.agentFinishedTurn(self)
            sendQueued()
        case .status(let st):
            status = st.text.isEmpty ? nil : st.text
        case .models(let list):
            if let provider = tab?.provider {
                workspace.app.updateModels(list.models.map(ModelOption.init(proto:)), for: provider)
            }
        case .task(let t):
            apply(.task(AgentTask(proto: t)))
        case .autoTurnStarted:
            isRunning = true
            turnStartedAt = .now
        case .rateLimit(let r):
            if let provider = tab?.provider { workspace.app.recordUsage(RateLimitInfo(proto: r), for: provider) }
        case .exited:
            isRunning = false
            restoreQueuedToDraft()
            status = nil
            turnStartedAt = nil
        default:
            break
        }
    }
}
