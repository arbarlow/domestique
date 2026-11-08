import AgentKit
import DQCore
import Foundation
import Observation
import ServerKit

/// The app's connection to one server: This Mac's (started by the app) or a remote one from
/// Settings → Servers. A server owns repositories, workspaces (git worktrees) and agent sessions. The app keeps its own `AppState` as the UI model and mirrors
/// the server into it:
///
/// - server owns: which repositories and local workspaces exist, their paths, branches, ports and
///   lifecycle state, and the sessions behind each workspace's chat tabs (provider, model, title, session).
/// - The app owns: names and icons shown for repositories, ship settings, tab order and selection,
///   unread markers, PR links, and everything about cloud (boat.dev) workspaces, which still run in-app.
///
/// On first connect, existing repositories and local workspaces (with their transcripts) are imported
/// into the server with their ids, so nothing is lost and tab ids stay session ids.
///
/// A remote server's workspaces get `host = WorkspaceHost(provider: .server, machineID: server id)`, so
/// git, tasks and terminals run there through `ServerHost` (`domestique exec`). Its repositories map onto
/// the app's by id (the app registers them with its own id) or by GitHub remote.
///
/// Set `DOMESTIQUE_LEGACY_ENGINE=1` to run This Mac's workspaces in-app as before.
@MainActor
@Observable
final class ServerLink {
    enum Status: Equatable {
        case disabled
        case starting
        case connected(name: String)
        case unavailable(String)

        var isConnected: Bool { if case .connected = self { true } else { false } }
    }

    enum Server: Equatable {
        case local
        case remote(ServerConfig)
    }

    let server: Server
    private(set) var status: Status {
        didSet {
            guard status != oldValue else { return }
            app.serverStatusChanged(self, wasConnected: oldValue.isConnected)
        }
    }
    /// The server's handshake answer and info (name, version, platform, agents), once connected.
    private(set) var welcome: Proto_Welcome?
    private(set) var info: Proto_ServerInfo?
    /// Live session activity from the server stream, for tabs whose chat isn't open.
    private(set) var activity: [UUID: Proto_SessionActivity] = [:]

    var isEnabled: Bool { status != .disabled }
    var isConnected: Bool { if case .connected = status { true } else { false } }

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private var client: ServerClient?
    @ObservationIgnored private var connectedServerID: String?
    @ObservationIgnored private var serverTask: Task<Void, Never>?
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<ServerClient, Error>] = []
    /// Workspaces / tabs created here whose server records may not have arrived yet.
    @ObservationIgnored private var pendingWorkspaces: Set<UUID> = []
    @ObservationIgnored private var pendingTabs: Set<UUID> = []
    /// Workspaces whose setup script is running in the app (the server already says READY).
    @ObservationIgnored var settingUp: Set<UUID> = []
    @ObservationIgnored private var workspaceWaiters: [UUID: [CheckedContinuation<WorkspaceState, Error>]] = [:]
    /// Last state the server reported per workspace (the app's copy may differ while it runs setup).
    @ObservationIgnored private var serverStates: [UUID: WorkspaceState] = [:]

    @ObservationIgnored private var closed = false
    @ObservationIgnored private var versionCheckPending = false
    /// This Mac's server is outdated but was busy; swap it as soon as no agent is mid-turn.
    @ObservationIgnored private var restartWhenIdle = false
    @ObservationIgnored private var alerted = false
    /// Server repository id -> app repository id (remote servers; This Mac's use the same ids).
    @ObservationIgnored private var repoMap: [String: UUID] = [:]

    init(app: AppModel, server: Server = .local) {
        self.app = app
        self.server = server
        let legacy = ProcessInfo.processInfo.environment["DOMESTIQUE_LEGACY_ENGINE"] == "1"
        status = legacy && server == .local ? .disabled : .starting
    }

    var serverID: UUID? { if case .remote(let c) = server { c.id } else { nil } }
    var isLocal: Bool { server == .local }
    var displayName: String {
        switch server {
        case .local: "This Mac"
        case .remote(let c): c.name
        }
    }

    /// Whether this workspace's agents and lifecycle go through this server.
    func manages(_ ws: Workspace?) -> Bool {
        guard isEnabled, let ws else { return false }
        switch server {
        case .local: return ws.host == nil
        case .remote(let c): return ws.serverID == c.id
        }
    }

    // MARK: connection

    func start() {
        guard isEnabled, client == nil else { return }
        Task { await connect() }
    }

    /// Connects, retrying with backoff until the first handshake succeeds (the client reconnects by
    /// itself after that).
    private func connect() async {
        var delay: Duration = .seconds(2)
        while !closed {
            status = .starting
            do {
                let c = try await makeClient()
                let welcome = try await c.connect()
                guard !closed else { await c.close(); return }
                client = c
                self.welcome = welcome
                connectedServerID = welcome.serverID
                status = .connected(name: welcome.serverName)
                for w in readyWaiters { w.resume(returning: c) }
                readyWaiters.removeAll()
                watchConnection(c)
                serverTask = Task { [weak self] in await self?.followServer(c) }
                info = try? await c.serverInfo()
                // Checked after the first snapshot, when session activity is known.
                versionCheckPending = isLocal
                return
            } catch {
                status = .unavailable(error.localizedDescription)
                for w in readyWaiters { w.resume(throwing: error) }
                readyWaiters.removeAll()
                if isLocal, !alerted {
                    alerted = true
                    app.alert = AppAlert(
                        title: "Couldn't start server",
                        message: "Domestique runs agents on a local server.\n\n\(error.localizedDescription)")
                }
                // A bad token won't fix itself.
                if let e = error as? ServerError, e.code == .unauthenticated { return }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(60))
            }
        }
    }

    private func makeClient() async throws -> ServerClient {
        switch server {
        case .local:
            // Only an address this Mac still has: binding one that's gone would stop server starting.
            let phoneIP = app.settings.phoneAccessAddress.flatMap { ip in LocalServer.networkAddresses().first { $0.ip == ip }?.ip }
            let endpoint = try await LocalServer.ensureRunning(
                addListen: phoneIP.map { ["tcp://\($0):\(LocalServer.networkPort)"] } ?? [])
            return ServerClient(endpoint: endpoint, clientName: "Domestique for Mac", clientID: Self.clientID)
        case .remote(let cfg):
            guard var url = URL(string: cfg.url), let scheme = url.scheme, ["ws", "wss"].contains(scheme) else {
                throw ServerError(code: .invalidArgument, message: "\(cfg.url) isn't a ws:// or wss:// URL")
            }
            if url.path.isEmpty || url.path == "/" { url = url.appending(path: "radio/v1") }
            return ServerClient(
                endpoint: .url(url), token: ServerTokens.get(cfg.id), clientName: "Domestique for Mac",
                clientID: Self.clientID)
        }
    }

    /// After an app update the old server keeps running (it outlives the app). Swap it for the bundled
    /// one whenever the versions differ: right away if no agent is mid-turn, else as soon as they all are
    /// idle. A bundled "dev" build (running from a source checkout) leaves whatever server is running alone;
    /// a running "dev" server is replaced by a release one.
    private func restartIfOutdated() async {
        restartWhenIdle = false
        guard isLocal, let bundled = LocalServer.binary(), let running = welcome?.serverVersion else { return }
        let version = await Task.detached { Self.version(of: bundled) }.value
        guard let version, version != "dev", version != running, welcome?.serverVersion == running else { return }
        guard !agentsBusy else {
            Trace.log("domestique: \(running) is outdated (bundled \(version)); restarting once agents are idle")
            restartWhenIdle = true
            return
        }
        Trace.log("domestique: restarting \(running) -> \(version)")
        await restart()
    }

    private var agentsBusy: Bool {
        activity.values.contains(where: { $0 == .running || $0 == .awaitingInput })
    }

    /// Called whenever session activity changes: performs a restart deferred by `restartIfOutdated`.
    private func restartIfDeferredAndIdle() {
        guard restartWhenIdle, !agentsBusy else { return }
        restartWhenIdle = false
        Task { await restartIfOutdated() }
    }

    nonisolated private static func version(of binary: URL) -> String? {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["version"]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: " ").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// This Mac only: stop the running server (its agents stop too) and start it again.
    func restart() async {
        guard isLocal else { return }
        restartWhenIdle = false
        serverTask?.cancel()
        if let client { await client.close() }
        client = nil
        welcome = nil
        info = nil
        status = .starting
        let pids = Self.signalLocalServer()
        for _ in 0..<50 where pids.contains(where: { kill($0, 0) == 0 }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        closed = false
        await connect()
    }

    /// This Mac only, on quit: hang up and stop the running server (its agents stop too) without waiting.
    func stopServer() {
        guard isLocal else { return }
        close()
        Self.signalLocalServer()
    }

    /// SIGTERMs whatever domestique process listens on This Mac's socket; returns the pids it signalled.
    @discardableResult
    nonisolated private static func signalLocalServer() -> [pid_t] {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-a", "-t", "-c", "domestique", "-c", "teamcar", LocalServer.socketPath]
        let out = Pipe()
        lsof.standardOutput = out
        guard (try? lsof.run()) != nil else { return [] }
        lsof.waitUntilExit()
        let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { kill(pid, SIGTERM) }
        return pids
    }

    /// "Test connection" in Settings: handshake and server info, then hang up.
    static func test(_ cfg: ServerConfig, token: String) async throws -> Proto_ServerInfo {
        guard var url = URL(string: cfg.url), let scheme = url.scheme, ["ws", "wss"].contains(scheme) else {
            throw ServerError(code: .invalidArgument, message: "Use a ws:// or wss:// URL")
        }
        if url.path.isEmpty || url.path == "/" { url = url.appending(path: "radio/v1") }
        let c = ServerClient(endpoint: .url(url), token: token, clientName: "Domestique for Mac (test)", clientID: clientID)
        defer { Task { await c.close() } }
        _ = try await c.connect()
        return try await c.serverInfo()
    }

    private func watchConnection(_ c: ServerClient) {
        Task { [weak self] in
            for await state in c.states {
                guard let self else { return }
                switch state {
                case .connected(let w): self.status = .connected(name: w.serverName)
                case .connecting: if self.isConnected { self.status = .unavailable("Reconnecting to the server…") }
                case .disconnected(let why): self.status = .unavailable(why)
                }
            }
        }
    }

    /// The connected client; waits for the first connection.
    func ready() async throws -> ServerClient {
        if let client { return client }
        if case .unavailable(let why) = status { throw ServerError(code: .unavailable, message: why) }
        if !isEnabled { throw ServerError(code: .unavailable, message: "Server is disabled") }
        return try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    func close() {
        closed = true
        serverTask?.cancel()
        if let client { Task { await client.close() } }
        client = nil
    }

    static var clientID: String {
        let key = "dq.teamcar.clientID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "mac-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: server stream

    private func followServer(_ c: ServerClient) async {
        do {
            let sub = try await c.subscribeServer()
            for await event in sub.events {
                if Task.isCancelled { sub.cancel(); return }
                await apply(event, client: c)
            }
        } catch {
            status = .unavailable("Lost the server stream: \(error.localizedDescription)")
        }
    }

    private func apply(_ event: Proto_Event, client c: ServerClient) async {
        switch event.payload {
        case .serverSnapshot(let snap):
            await reconcile(snap, client: c)
        case .repositoryUpserted(let r):
            upsertRepo(r)
        case .repositoryRemoved(let id):
            guard isLocal else {
                repoMap[id] = nil
                return
            }
            guard let id = UUID(protoID: id), let repo = app.repo(id) else { return }
            if app.activeWorkspaces(in: repo).isEmpty { app.forgetRepository(id) }
        case .workspaceUpserted(let w):
            upsertWorkspace(w, sessions: nil)
        case .workspaceRemoved(let id):
            guard let id = UUID(protoID: id) else { return }
            app.forgetWorkspace(id)
            markSynced(workspace: id, false)
        case .sessionUpserted(let r):
            upsertSession(r)
        case .sessionRemoved(let id):
            guard let tabID = UUID(protoID: id) else { return }
            activity[tabID] = nil
            restartIfDeferredAndIdle()
            for ws in app.state.workspaces where ws.tabs.contains(where: { $0.id == tabID }) && !pendingTabs.contains(tabID) {
                app.model(for: ws.id).dropTab(tabID)
            }
        default:
            break
        }
    }

    /// Brings app and server in line after (re)connecting: imports what only the app knows, adopts what
    /// only the server knows, and drops what was deleted elsewhere.
    private func reconcile(_ snap: Proto_ServerSnapshot, client c: ServerClient) async {
        let serverRepos = Dictionary(snap.repositories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let serverWS = Set(snap.workspaces.map(\.id))
        if !isLocal {
            await reconcileRemote(snap, serverWS: serverWS)
            return
        }

        // Repositories the server doesn't have yet (or under another id: adopt the server's id).
        for repo in app.state.repositories where serverRepos[repo.id.protoID] == nil {
            do {
                var req = Proto_AddRepository()
                req.path = repo.path
                req.id = repo.id.protoID
                let r = try await c.addRepository(req)
                if r.id != repo.id.protoID, let newID = UUID(protoID: r.id) { app.renameRepositoryID(repo.id, to: newID) }
            } catch {
                // A clone that's gone from disk can't be registered; keep showing it as before.
                Trace.log("domestique: couldn't register \(repo.path): \(error.localizedDescription)")
            }
        }
        for r in snap.repositories { upsertRepo(r) }

        // Local workspaces: import the ones the server never had; drop the ones deleted elsewhere.
        let synced = syncedWorkspaces
        for ws in app.state.workspaces where !ws.isRemote && !serverWS.contains(ws.id.protoID) {
            if synced.contains(ws.id) && !pendingWorkspaces.contains(ws.id) {
                app.forgetWorkspace(ws.id)
                markSynced(workspace: ws.id, false)
                continue
            }
            guard !pendingWorkspaces.contains(ws.id) else { continue }
            do {
                _ = try await c.importWorkspace(await importRequest(for: ws))
                markSynced(workspace: ws.id, true)
            } catch {
                Trace.log("domestique: couldn't import \(ws.name): \(error.localizedDescription)")
            }
        }

        let sessionsByWS = Dictionary(grouping: snap.sessions, by: \.workspaceID)
        for w in snap.workspaces { upsertWorkspace(w, sessions: sessionsByWS[w.id] ?? []) }
        for r in snap.sessions {
            if let id = UUID(protoID: r.id) { activity[id] = r.activity }
            noteProgress(r)
        }
        if versionCheckPending {
            versionCheckPending = false
            Task { await restartIfOutdated() }
        }
    }

    /// A remote server: map its repositories onto the app's, mirror its workspaces, drop deleted ones.
    /// Nothing is imported: only This Mac has pre-server workspaces.
    private func reconcileRemote(_ snap: Proto_ServerSnapshot, serverWS: Set<String>) async {
        repoMap = [:]
        for r in snap.repositories { upsertRepo(r) }
        let synced = syncedWorkspaces
        for ws in app.state.workspaces where manages(ws) && !serverWS.contains(ws.id.protoID) {
            if synced.contains(ws.id) && !pendingWorkspaces.contains(ws.id) {
                app.forgetWorkspace(ws.id)
                markSynced(workspace: ws.id, false)
            }
        }
        let sessionsByWS = Dictionary(grouping: snap.sessions, by: \.workspaceID)
        for w in snap.workspaces { upsertWorkspace(w, sessions: sessionsByWS[w.id] ?? []) }
        for r in snap.sessions {
            if let id = UUID(protoID: r.id) { activity[id] = r.activity }
            noteProgress(r)
        }
    }

    /// The server repository for an app repository on this server, cloning it there first if needed.
    private func ensureRepository(_ repo: Repository, client c: ServerClient) async throws -> String {
        if isLocal { return repo.id.protoID }
        if let (connectedServerID, _) = repoMap.first(where: { $0.value == repo.id }) { return connectedServerID }
        guard let url = repo.remoteURL, !url.isEmpty else {
            throw ServerError(code: .failedPrecondition, message: "\(repo.title) has no remote to clone on \(displayName).")
        }
        var req = Proto_AddRepository()
        req.cloneURL = url
        req.name = repo.name
        req.id = repo.id.protoID
        let r = try await c.addRepository(req)
        repoMap[r.id] = repo.id
        return r.id
    }

    private func importRequest(for ws: Workspace) async -> Proto_ImportWorkspace {
        var w = Proto_Workspace()
        w.id = ws.id.protoID
        w.repositoryID = ws.repoID.protoID
        w.name = ws.name
        w.branch = ws.branch
        w.path = ws.path
        w.baseBranch = ws.baseBranch
        w.baseCommit = ws.baseCommit ?? ""
        w.portBase = Int32(ws.portBase)
        w.createdAtMs = Int64(ws.createdAt.timeIntervalSince1970 * 1000)
        switch ws.state {
        case .archived: w.state = .archived
        case .failed(let why):
            w.state = .failed
            w.failure = why
        default: w.state = .ready
        }
        var req = Proto_ImportWorkspace()
        req.workspace = w
        for tab in ws.tabs {
            var r = Proto_Session()
            r.id = tab.id.protoID
            r.workspaceID = w.id
            r.title = tab.title
            r.provider = tab.provider.proto
            r.model = tab.model ?? ""
            r.effort = tab.effort ?? ""
            r.permissionMode = tab.permissionMode.proto
            r.providerSessionID = tab.providerSessionID ?? ""
            r.createdAtMs = Int64(tab.createdAt.timeIntervalSince1970 * 1000)
            var ir = Proto_ImportSession()
            ir.session = r
            ir.items = await Store.shared.loadTranscript(tabID: tab.id).map(\.proto)
            req.sessions.append(ir)
        }
        return req
    }

    // MARK: mirroring

    private func upsertRepo(_ r: Proto_Repository) {
        if !isLocal {
            // Same id (registered from this app), else the same GitHub repository.
            if let id = UUID(protoID: r.id), app.repo(id) != nil {
                repoMap[r.id] = id
            } else if let slug = GitHubRemote.slug(from: r.remoteURL)?.lowercased(),
                let repo = app.repositories.first(where: { $0.githubSlug?.lowercased() == slug })
            {
                repoMap[r.id] = repo.id
            }
            return
        }
        guard let id = UUID(protoID: r.id) else { return }
        if app.repo(id) != nil {
            app.updateRepoIfChanged(id) { repo in
                repo.path = r.path
                repo.remoteURL = r.remoteURL.isEmpty ? nil : r.remoteURL
                repo.defaultBranch = r.defaultBranch
            }
        } else {
            var repo = Repository(
                id: id, name: r.name, path: r.path, remoteURL: r.remoteURL.isEmpty ? nil : r.remoteURL,
                defaultBranch: r.defaultBranch,
                createdAt: Date(timeIntervalSince1970: Double(r.createdAtMs) / 1000))
            if !r.displayName.isEmpty { repo.displayName = r.displayName }
            app.adoptRepository(repo)
        }
    }

    /// `sessions` nil = keep the app's tabs (a workspace-only update).
    private func upsertWorkspace(_ w: Proto_Workspace, sessions: [Proto_Session]?) {
        guard let id = UUID(protoID: w.id),
            let repoID = isLocal ? UUID(protoID: w.repositoryID) : repoMap[w.repositoryID]
        else { return }
        markSynced(workspace: id, true)
        let state = appState(w)
        serverStates[id] = state
        if app.workspace(id) == nil {
            guard app.repo(repoID) != nil else { return }
            let tabs = (sessions ?? []).sorted { $0.createdAtMs < $1.createdAtMs }.map(Self.tab)
            var ws = Workspace(
                id: id, repoID: repoID, name: w.name, branch: w.branch, path: w.path, baseBranch: w.baseBranch,
                baseCommit: w.baseCommit.isEmpty ? nil : w.baseCommit, portBase: Int(w.portBase), state: state,
                createdAt: Date(timeIntervalSince1970: Double(w.createdAtMs) / 1000), tabs: tabs,
                selectedTabID: tabs.first?.id)
            ws.host = workspaceHost
            app.adoptWorkspace(ws)
        } else {
            app.updateWorkspaceIfChanged(id) { ws in
                ws.name = w.name
                ws.branch = w.branch
                ws.path = w.path
                ws.baseBranch = w.baseBranch
                if !w.baseCommit.isEmpty { ws.baseCommit = w.baseCommit }
                ws.portBase = Int(w.portBase)
                // The app runs setup itself once the worktree exists; keep showing that.
                if !(self.settingUp.contains(id) && state == .ready) { ws.state = state }
                if let sessions {
                    let serverIDs = Set(sessions.compactMap { UUID(protoID: $0.id) })
                    ws.tabs.removeAll { !serverIDs.contains($0.id) && !self.pendingTabs.contains($0.id) }
                    for r in sessions.sorted(by: { $0.createdAtMs < $1.createdAtMs }) { Self.merge(r, into: &ws) }
                    if ws.selectedTabID.map({ sid in !ws.tabs.contains { $0.id == sid } }) ?? true {
                        ws.selectedTabID = ws.tabs.first?.id
                    }
                }
            }
        }
        if Self.isSettled(state) { resolveWaiters(id, state) }
    }

    private func upsertSession(_ r: Proto_Session) {
        guard let tabID = UUID(protoID: r.id), let wsID = UUID(protoID: r.workspaceID) else { return }
        pendingTabs.remove(tabID)
        activity[tabID] = r.activity
        app.updateWorkspaceIfChanged(wsID) { ws in Self.merge(r, into: &ws) }
        noteProgress(r)
        restartIfDeferredAndIdle()
    }

    // MARK: unread

    /// Highest transcript seq the user has had on screen, per tab (persisted, so work done while the
    /// app was closed, or from another client, shows as unread).
    @ObservationIgnored private var seenSeqs: [String: UInt64] =
        (UserDefaults.standard.dictionary(forKey: "dq.teamcar.seenSeq") as? [String: NSNumber])?
        .mapValues(\.uint64Value) ?? [:]
    @ObservationIgnored private var lastSeqs: [UUID: UInt64] = [:]

    private func noteProgress(_ r: Proto_Session) {
        guard let tabID = UUID(protoID: r.id), let wsID = UUID(protoID: r.workspaceID) else { return }
        lastSeqs[tabID] = r.lastSeq
        guard let seen = seenSeqs[r.id] else {
            setSeen(r.id, r.lastSeq)  // first sight (e.g. just imported): nothing new
            return
        }
        guard r.lastSeq > seen else { return }
        if app.selectedWorkspaceID == wsID {
            setSeen(r.id, r.lastSeq)
        } else if r.activity == .idle {
            app.updateWorkspaceIfChanged(wsID) { $0.hasUnread = true }
        }
    }

    /// The user is looking at this workspace: everything in it so far counts as seen.
    func markSeen(workspace id: UUID) {
        guard let ws = app.workspace(id) else { return }
        for tab in ws.tabs { if let seq = lastSeqs[tab.id] { setSeen(tab.id.protoID, seq) } }
    }

    private func setSeen(_ sessionID: String, _ seq: UInt64) {
        guard seenSeqs[sessionID] != seq else { return }
        seenSeqs[sessionID] = seq
        UserDefaults.standard.set(seenSeqs.mapValues { NSNumber(value: $0) }, forKey: "dq.teamcar.seenSeq")
    }

    /// What a workspace on this server runs on (nil for This Mac).
    var workspaceHost: WorkspaceHost? {
        guard case .remote(let c) = server else { return nil }
        return WorkspaceHost(provider: .server, machineID: c.id.uuidString, machineName: c.name)
    }

    private static func merge(_ r: Proto_Session, into ws: inout Workspace) {
        guard let tabID = UUID(protoID: r.id) else { return }
        if let i = ws.tabs.firstIndex(where: { $0.id == tabID }) {
            ws.tabs[i].title = r.title
            ws.tabs[i].provider = ProviderKind(proto: r.provider)
            ws.tabs[i].model = r.model.isEmpty ? nil : r.model
            ws.tabs[i].effort = r.effort.isEmpty ? nil : r.effort
            ws.tabs[i].permissionMode = AgentPermissionMode(proto: r.permissionMode)
            ws.tabs[i].providerSessionID = r.providerSessionID.isEmpty ? nil : r.providerSessionID
        } else {
            ws.tabs.append(tab(r))
            if ws.selectedTabID == nil { ws.selectedTabID = tabID }
        }
    }

    private static func tab(_ r: Proto_Session) -> ChatTab {
        var t = ChatTab(
            id: UUID(protoID: r.id) ?? UUID(), title: r.title, provider: ProviderKind(proto: r.provider),
            model: r.model.isEmpty ? nil : r.model, permissionMode: AgentPermissionMode(proto: r.permissionMode),
            providerSessionID: r.providerSessionID.isEmpty ? nil : r.providerSessionID,
            createdAt: Date(timeIntervalSince1970: Double(r.createdAtMs) / 1000))
        t.effort = r.effort.isEmpty ? nil : r.effort
        return t
    }

    private func appState(_ w: Proto_Workspace) -> WorkspaceState {
        switch w.state {
        case .creating: .creating
        case .settingUp: .settingUp
        case .failed: .failed(w.failure.isEmpty ? "Workspace creation failed" : w.failure)
        case .archived: .archived
        default: .ready
        }
    }

    // MARK: operations used by the app

    /// Registers a workspace the app just created locally (state .creating) and creates its worktree on
    /// Server. Returns once the worktree exists (READY) or creation failed (throws).
    func createWorkspace(_ ws: Workspace) async throws {
        pendingWorkspaces.insert(ws.id)
        for t in ws.tabs { pendingTabs.insert(t.id) }
        defer { pendingWorkspaces.remove(ws.id) }
        let c = try await ready()
        guard let repo = app.repo(ws.repoID) else {
            throw ServerError(code: .notFound, message: "The repository is gone")
        }
        var req = Proto_CreateWorkspace()
        req.id = ws.id.protoID
        req.repositoryID = try await ensureRepository(repo, client: c)
        req.name = ws.name
        req.branch = ws.branch
        req.baseBranch = ws.baseBranch
        req.skipSetup = true
        if let tab = ws.tabs.first { req.session = Self.openRequest(tab, workspace: ws.id) }
        _ = try await c.createWorkspace(req, idempotencyKey: "create-" + ws.id.protoID)
        markSynced(workspace: ws.id, true)
        // serverStates catches a READY that arrived before we started waiting.
        switch try await waitForWorkspace(ws.id) {
        case .failed(let why): throw ServerError(code: .failedPrecondition, message: why)
        case .archived: throw ServerError(code: .failedPrecondition, message: "The workspace was archived")
        default: break
        }
    }

    private func waitForWorkspace(_ id: UUID) async throws -> WorkspaceState {
        if let s = serverStates[id], Self.isSettled(s) { return s }
        return try await withCheckedThrowingContinuation { workspaceWaiters[id, default: []].append($0) }
    }

    private static func isSettled(_ s: WorkspaceState) -> Bool {
        switch s {
        case .ready, .archived, .failed: true
        case .creating, .settingUp: false
        }
    }

    private func resolveWaiters(_ id: UUID, _ state: WorkspaceState) {
        guard let waiters = workspaceWaiters.removeValue(forKey: id) else { return }
        for w in waiters { w.resume(returning: state) }
    }

    func archiveWorkspace(_ ws: Workspace) async throws {
        let c = try await ready()
        var req = Proto_ArchiveWorkspace()
        req.workspaceID = ws.id.protoID
        req.skipArchiveScript = true  // the app already ran it in the run dock
        _ = try await c.archiveWorkspace(req)
    }

    func deleteWorkspace(_ ws: Workspace) async throws {
        let c = try await ready()
        var req = Proto_DeleteWorkspace()
        req.workspaceID = ws.id.protoID
        req.deleteBranch = true
        try await c.deleteWorkspace(req)
        markSynced(workspace: ws.id, false)
    }

    func addRepository(path: String) async throws -> Repository {
        let c = try await ready()
        var req = Proto_AddRepository()
        req.path = path
        req.id = UUID().protoID
        let r = try await c.addRepository(req)
        upsertRepo(r)
        guard let id = UUID(protoID: r.id), let repo = app.repo(id) else {
            throw ServerError(code: .internal, message: "Server returned an invalid repository id")
        }
        return repo
    }

    func removeRepository(_ id: UUID) async throws {
        let c = try await ready()
        do {
            try await c.removeRepository(id: id.protoID)
        } catch let e as ServerError where e.code == .notFound {}
    }

    /// Tabs created here that the server hasn't confirmed yet.
    var openingTabs: Set<UUID> { pendingTabs }

    func openSession(_ tab: ChatTab, workspace: UUID) {
        pendingTabs.insert(tab.id)
        let req = Self.openRequest(tab, workspace: workspace)
        Task {
            do {
                _ = try await ready().openSession(req)
            } catch {
                pendingTabs.remove(tab.id)
                app.alert = AppAlert(title: "Couldn't open a chat", message: error.localizedDescription)
            }
        }
    }

    func closeSession(_ tabID: UUID) async {
        pendingTabs.remove(tabID)
        activity[tabID] = nil
        restartIfDeferredAndIdle()
        _ = try? await ready().closeSession(id: tabID.protoID)
    }

    /// Swaps the tab's session for a fresh one (e.g. a different provider), keeping the tab.
    func replaceSession(_ tab: ChatTab, workspace: UUID) async {
        pendingTabs.insert(tab.id)
        activity[tab.id] = nil
        _ = try? await ready().closeSession(id: tab.id.protoID)
        openSession(tab, workspace: workspace)
    }

    static func openRequest(_ tab: ChatTab, workspace: UUID) -> Proto_OpenSession {
        var r = Proto_OpenSession()
        r.id = tab.id.protoID
        r.workspaceID = workspace.protoID
        r.provider = tab.provider.proto
        r.model = tab.model ?? ""
        r.effort = tab.effort ?? ""
        r.permissionMode = tab.permissionMode.proto
        r.title = tab.title
        return r
    }

    func listModels(_ provider: ProviderKind) async -> [ModelOption]? {
        guard let models = try? await ready().listModels(provider.proto), !models.isEmpty else { return nil }
        return models.map(ModelOption.init(proto:))
    }

    func isSessionRunning(_ tabID: UUID) -> Bool {
        guard let a = activity[tabID] else { return false }
        return a == .running || a == .awaitingInput
    }

    func isSessionAwaiting(_ tabID: UUID) -> Bool { activity[tabID] == .awaitingInput }

    // MARK: which workspaces this server has seen

    /// Ids of local workspaces known to exist on this server. A workspace that's in here but missing
    /// from the server was deleted elsewhere (don't re-import it).
    private var syncedWorkspaces: Set<UUID> {
        guard let connectedServerID else { return [] }
        let raw = UserDefaults.standard.stringArray(forKey: "dq.teamcar.synced.\(connectedServerID)") ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func markSynced(workspace id: UUID, _ synced: Bool) {
        guard let connectedServerID else { return }
        var set = syncedWorkspaces
        let changed = synced ? set.insert(id).inserted : set.remove(id) != nil
        guard changed else { return }
        UserDefaults.standard.set(set.map(\.uuidString), forKey: "dq.teamcar.synced.\(connectedServerID)")
    }
}
