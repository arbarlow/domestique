import DQCore
import Foundation
import Observation
import ServerKit

/// One server: the Domestique protocol client, and the server's repositories, workspaces and sessions folded from
/// its server stream.
@MainActor @Observable
final class ServerConnection: Identifiable {
    enum Status: Equatable {
        case connecting
        case connected
        case offline(String)
    }

    let config: ServerConfig
    nonisolated var id: UUID { config.id }
    private let token: String?

    private(set) var status: Status = .connecting
    private(set) var welcome: Proto_Welcome?
    private(set) var info: Proto_ServerInfo?
    private(set) var repositories: [String: Proto_Repository] = [:]
    private(set) var workspaces: [String: Proto_Workspace] = [:]
    private(set) var sessions: [String: Proto_Session] = [:]
    /// Models per provider, from ListModels or a session stream.
    private(set) var models: [ProviderKind: [ModelOption]] = [:]
    /// The first server snapshot has arrived (so empty lists mean empty, not loading).
    private(set) var loaded = false

    private(set) var client: ServerClient?
    private var runTask: Task<Void, Never>?
    private var readyWaiters: [UUID: CheckedContinuation<ServerClient, any Error>] = [:]
    /// Bumped whenever the client is replaced, so stale loops stop.
    private var generation = 0

    init(config: ServerConfig, token: String?) {
        self.config = config
        self.token = token
    }

    var name: String { config.name }
    var scope: Proto_TokenScope { welcome?.scope ?? .unspecified }
    var canTrigger: Bool { scope.rawValue >= Proto_TokenScope.trigger.rawValue }
    var canOperate: Bool { scope.rawValue >= Proto_TokenScope.operate.rawValue }

    // MARK: Lifecycle

    func start() {
        guard client == nil else { return }
        let endpoint: ServerEndpoint
        do {
            endpoint = try ServerList.endpoint(for: config.url)
        } catch {
            status = .offline(error.localizedDescription)
            return
        }
        generation += 1
        let gen = generation
        let c = ServerClient(endpoint: endpoint, token: token, clientName: ServerList.clientName, clientID: ServerList.clientID)
        client = c
        status = .connecting
        runTask = Task { [weak self] in
            await self?.watch(c, generation: gen)
        }
        Task { [weak self] in
            await self?.run(c, generation: gen)
        }
    }

    func stop() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        if let client { Task { await client.close() } }
        client = nil
        failWaiters(ServerError(code: .unavailable, message: "Disconnected"))
    }

    /// Foreground again: if the connection is down, start over now instead of waiting for backoff.
    func wake() {
        guard status != .connected else { return }
        stop()
        start()
    }

    /// The connected client; waits (up to 15 s) for the connection.
    func ready() async throws -> ServerClient {
        if status == .connected, let client { return client }
        if client == nil { start() }
        let id = UUID()
        let name = config.name
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.readyWaiters.removeValue(forKey: id)?
                .resume(throwing: ServerError(code: .unavailable, message: "Couldn't reach \(name)"))
        }
        return try await withCheckedThrowingContinuation { readyWaiters[id] = $0 }
    }

    private func failWaiters(_ error: any Error) {
        let waiters = readyWaiters
        readyWaiters = [:]
        for w in waiters.values { w.resume(throwing: error) }
    }

    private func watch(_ c: ServerClient, generation gen: Int) async {
        for await state in c.states {
            guard gen == generation else { return }
            switch state {
            case .connecting:
                if status != .connected { status = .connecting }
            case .connected(let w):
                welcome = w
                status = .connected
                let waiters = readyWaiters
                readyWaiters = [:]
                for waiter in waiters.values { waiter.resume(returning: c) }
            case .disconnected(let why):
                status = .offline(why)
            }
        }
    }

    /// Connects (retrying with backoff until it works), then follows the server stream for good. The client
    /// resubscribes on its own after reconnects, and each resubscription starts with a fresh snapshot.
    private func run(_ c: ServerClient, generation gen: Int) async {
        var delay: Duration = .seconds(1)
        while gen == generation, !Task.isCancelled {
            do {
                _ = try await c.connect()
                if info == nil { info = try? await c.serverInfo() }
                let sub = try await c.subscribeServer()
                for await event in sub.events {
                    guard gen == generation else {
                        sub.cancel()
                        return
                    }
                    apply(event)
                }
                // The stream ended: the client was closed (stop) or gave up.
                guard gen == generation else { return }
            } catch let e as ServerError where e.code == .unauthenticated || e.code == .permissionDenied {
                status = .offline(e.message.isEmpty ? "The token was rejected" : e.message)
                failWaiters(e)
                return
            } catch {
                guard gen == generation else { return }
                status = .offline(error.localizedDescription)
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(15))
        }
    }

    private func apply(_ event: Proto_Event) {
        switch event.payload {
        case .serverSnapshot(let snap):
            repositories = Dictionary(snap.repositories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            workspaces = Dictionary(snap.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            sessions = Dictionary(snap.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            loaded = true
        case .repositoryUpserted(let r): repositories[r.id] = r
        case .repositoryRemoved(let id): repositories[id] = nil
        case .workspaceUpserted(let w): workspaces[w.id] = w
        case .workspaceRemoved(let id): workspaces[id] = nil
        case .sessionUpserted(let r): sessions[r.id] = r
        case .sessionRemoved(let id): sessions[id] = nil
        default: break
        }
    }

    // MARK: Views of the state

    var sortedRepositories: [Proto_Repository] {
        repositories.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Active workspaces, newest first.
    var activeWorkspaces: [Proto_Workspace] {
        workspaces.values.filter { $0.state != .archived }.sorted { $0.createdAtMs > $1.createdAtMs }
    }

    func sessions(in workspaceID: String) -> [Proto_Session] {
        sessions.values.filter { $0.workspaceID == workspaceID }.sorted { $0.createdAtMs < $1.createdAtMs }
    }

    /// The busiest session state in a workspace: awaiting input beats running beats idle.
    func activity(of workspaceID: String) -> Proto_SessionActivity {
        var best = Proto_SessionActivity.idle
        for r in sessions.values where r.workspaceID == workspaceID {
            if r.activity == .awaitingInput { return .awaitingInput }
            if r.activity == .running { best = .running }
        }
        return best
    }

    var needsInputCount: Int { sessions.values.filter { $0.activity == .awaitingInput }.count }

    /// One chat model per session, kept while the app runs so going back and forth doesn't replay.
    @ObservationIgnored private var chats: [String: SessionChat] = [:]
    /// Open port tunnels by the port they reach on the server.
    @ObservationIgnored var tunnels: [UInt16: PortTunnel] = [:]

    func chat(for sessionID: String) -> SessionChat {
        if let c = chats[sessionID] { return c }
        let c = SessionChat(sessionID: sessionID, server: self)
        chats[sessionID] = c
        c.follow()
        return c
    }

    // MARK: Actions

    func updateModels(_ list: [ModelOption], for provider: ProviderKind) {
        if !list.isEmpty { models[provider] = list }
    }

    func loadModels(_ provider: ProviderKind) async {
        guard models[provider] == nil, let c = try? await ready() else { return }
        if let list = try? await c.listModels(provider.proto) { updateModels(list.map(ModelOption.init(proto:)), for: provider) }
    }

    var providers: [ProviderKind] {
        let found = Set(info?.providers.map(ProviderKind.init(proto:)) ?? [])
        return found.isEmpty ? ProviderKind.allCases : ProviderKind.allCases.filter(found.contains)
    }

    /// Creates a workspace with one empty chat, ready for its first prompt.
    func createWorkspace(repositoryID: String, provider: ProviderKind) async throws -> Proto_Workspace {
        let c = try await ready()
        var session = Proto_OpenSession()
        session.provider = provider.proto
        session.permissionMode = AgentPermissionMode.bypass.proto
        var req = Proto_CreateWorkspace()
        req.repositoryID = repositoryID
        req.session = session
        let ws = try await c.createWorkspace(req, idempotencyKey: UUID().uuidString)
        workspaces[ws.id] = ws
        return ws
    }

    func openSession(workspaceID: String, provider: ProviderKind, model: String? = nil,
                     permission: Proto_PermissionMode? = nil) async throws -> Proto_Session
    {
        let c = try await ready()
        var req = Proto_OpenSession()
        req.workspaceID = workspaceID
        req.provider = provider.proto
        if let model { req.model = model }
        if let permission { req.permissionMode = permission }
        let r = try await c.openSession(req)
        sessions[r.id] = r
        return r
    }

    func closeSession(_ id: String) async throws {
        try await ready().closeSession(id: id)
        sessions[id] = nil
    }

    func archive(_ workspaceID: String) async throws {
        var req = Proto_ArchiveWorkspace()
        req.workspaceID = workspaceID
        let ws = try await ready().archiveWorkspace(req)
        workspaces[ws.id] = ws
    }

    func addRepository(cloneURL: String) async throws -> Proto_Repository {
        var req = Proto_AddRepository()
        req.cloneURL = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = try await ready().addRepository(req)
        repositories[r.id] = r
        return r
    }
}

extension Proto_Repository {
    var title: String { displayName.isEmpty ? name : displayName }
}

extension Proto_Workspace {
    var stateLabel: String? {
        switch state {
        case .creating: "Creating…"
        case .settingUp: "Setting up…"
        case .failed: failure.isEmpty ? "Failed" : "Failed: \(failure)"
        case .archived: "Archived"
        default: nil
        }
    }
}

extension Proto_Session {
    var providerKind: ProviderKind { ProviderKind(proto: provider) }
    var displayTitle: String { title.isEmpty ? "New chat" : title }
}
