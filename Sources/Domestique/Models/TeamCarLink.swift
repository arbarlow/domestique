import AgentKit
import DQCore
import Foundation
import Observation
import RaceRadioKit

/// The app's connection to one Team Car: This Mac's (started by the app) or a remote one from
/// Settings → Team Cars. A Team Car owns repositories, workspaces (git worktrees) and agent sessions. The app keeps its own `AppState` as the UI model and mirrors
/// the server into it:
///
/// - Team Car owns: which repositories and local workspaces exist, their paths, branches, ports and
///   lifecycle state, and the riders behind each workspace's chat tabs (provider, model, title, session).
/// - The app owns: names and icons shown for repositories, ship settings, tab order and selection,
///   unread markers, PR links, and everything about cloud (boat.dev) workspaces, which still run in-app.
///
/// On first connect, existing repositories and local workspaces (with their transcripts) are imported
/// into Team Car with their ids, so nothing is lost and tab ids stay rider ids.
///
/// A remote car's workspaces get `host = WorkspaceHost(provider: .teamcar, machineID: car id)`, so
/// git, tasks and terminals run there through `TeamCarHost` (`teamcar exec`). Its repositories map onto
/// the app's by id (the app registers them with its own id) or by GitHub remote.
///
/// Set `DOMESTIQUE_LEGACY_ENGINE=1` to run This Mac's workspaces in-app as before.
@MainActor
@Observable
final class TeamCarLink {
    enum Status: Equatable {
        case disabled
        case starting
        case connected(name: String)
        case unavailable(String)

        var isConnected: Bool { if case .connected = self { true } else { false } }
    }

    enum Car: Equatable {
        case local
        case remote(TeamCarConfig)
    }

    let car: Car
    private(set) var status: Status {
        didSet {
            guard status != oldValue else { return }
            app.teamCarStatusChanged(self, wasConnected: oldValue.isConnected)
        }
    }
    /// The server's handshake answer and info (name, version, platform, agents), once connected.
    private(set) var welcome: Radio_Welcome?
    private(set) var info: Radio_ServerInfo?
    /// Live rider activity from the server stream, for tabs whose chat isn't open.
    private(set) var activity: [UUID: Radio_RiderActivity] = [:]

    var isEnabled: Bool { status != .disabled }
    var isConnected: Bool { if case .connected = status { true } else { false } }

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private var client: TeamCarClient?
    @ObservationIgnored private var serverID: String?
    @ObservationIgnored private var serverTask: Task<Void, Never>?
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<TeamCarClient, Error>] = []
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
    @ObservationIgnored private var alerted = false
    /// Server repository id -> app repository id (remote cars; This Mac's use the same ids).
    @ObservationIgnored private var repoMap: [String: UUID] = [:]

    init(app: AppModel, car: Car = .local) {
        self.app = app
        self.car = car
        let legacy = ProcessInfo.processInfo.environment["DOMESTIQUE_LEGACY_ENGINE"] == "1"
        status = legacy && car == .local ? .disabled : .starting
    }

    var carID: UUID? { if case .remote(let c) = car { c.id } else { nil } }
    var isLocal: Bool { car == .local }
    var displayName: String {
        switch car {
        case .local: "This Mac"
        case .remote(let c): c.name
        }
    }

    /// Whether this workspace's agents and lifecycle go through this Team Car.
    func manages(_ ws: Workspace?) -> Bool {
        guard isEnabled, let ws else { return false }
        switch car {
        case .local: return ws.host == nil
        case .remote(let c): return ws.teamCarID == c.id
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
                serverID = welcome.serverID
                status = .connected(name: welcome.serverName)
                for w in readyWaiters { w.resume(returning: c) }
                readyWaiters.removeAll()
                watchConnection(c)
                serverTask = Task { [weak self] in await self?.followServer(c) }
                info = try? await c.serverInfo()
                // Checked after the first snapshot, when rider activity is known.
                versionCheckPending = isLocal
                return
            } catch {
                status = .unavailable(error.localizedDescription)
                for w in readyWaiters { w.resume(throwing: error) }
                readyWaiters.removeAll()
                if isLocal, !alerted {
                    alerted = true
                    app.alert = AppAlert(
                        title: "Couldn't start Team Car",
                        message: "Domestique runs agents in Team Car, its local server.\n\n\(error.localizedDescription)")
                }
                // A bad token won't fix itself.
                if let e = error as? TeamCarError, e.code == .unauthenticated { return }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(60))
            }
        }
    }

    private func makeClient() async throws -> TeamCarClient {
        switch car {
        case .local:
            let endpoint = try await LocalTeamCar.ensureRunning()
            return TeamCarClient(endpoint: endpoint, clientName: "Domestique for Mac", clientID: Self.clientID)
        case .remote(let cfg):
            guard var url = URL(string: cfg.url), let scheme = url.scheme, ["ws", "wss"].contains(scheme) else {
                throw TeamCarError(code: .invalidArgument, message: "\(cfg.url) isn't a ws:// or wss:// URL")
            }
            if url.path.isEmpty || url.path == "/" { url = url.appending(path: "radio/v1") }
            return TeamCarClient(
                endpoint: .url(url), token: TeamCarTokens.get(cfg.id), clientName: "Domestique for Mac",
                clientID: Self.clientID)
        }
    }

    /// After an app update the old Team Car keeps running (it outlives the app). Swap it for the bundled
    /// one when the versions differ and no agent is mid-turn; otherwise leave it for next launch.
    private func restartIfOutdated() async {
        guard let bundled = LocalTeamCar.binary(), let running = welcome?.serverVersion,
            let version = Self.version(of: bundled), version != running, version != "dev", running != "dev"
        else { return }
        guard !activity.values.contains(where: { $0 == .running || $0 == .awaitingInput }) else {
            Trace.log("teamcar: \(running) is outdated (bundled \(version)) but agents are running; keeping it")
            return
        }
        Trace.log("teamcar: restarting \(running) -> \(version)")
        await restart()
    }

    private static func version(of binary: URL) -> String? {
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

    /// This Mac only: stop the running Team Car (its agents stop too) and start it again.
    func restart() async {
        guard isLocal else { return }
        serverTask?.cancel()
        if let client { await client.close() }
        client = nil
        welcome = nil
        info = nil
        status = .starting
        let socket = LocalTeamCar.socketPath
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-a", "-t", "-c", "teamcar", socket]
        let out = Pipe()
        lsof.standardOutput = out
        if (try? lsof.run()) != nil {
            lsof.waitUntilExit()
            let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
            for pid in pids { kill(pid, SIGTERM) }
            for _ in 0..<50 where pids.contains(where: { kill($0, 0) == 0 }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        closed = false
        await connect()
    }

    /// "Test connection" in Settings: handshake and server info, then hang up.
    static func test(_ cfg: TeamCarConfig, token: String) async throws -> Radio_ServerInfo {
        guard var url = URL(string: cfg.url), let scheme = url.scheme, ["ws", "wss"].contains(scheme) else {
            throw TeamCarError(code: .invalidArgument, message: "Use a ws:// or wss:// URL")
        }
        if url.path.isEmpty || url.path == "/" { url = url.appending(path: "radio/v1") }
        let c = TeamCarClient(endpoint: .url(url), token: token, clientName: "Domestique for Mac (test)", clientID: clientID)
        defer { Task { await c.close() } }
        _ = try await c.connect()
        return try await c.serverInfo()
    }

    private func watchConnection(_ c: TeamCarClient) {
        Task { [weak self] in
            for await state in c.states {
                guard let self else { return }
                switch state {
                case .connected(let w): self.status = .connected(name: w.serverName)
                case .connecting: if self.isConnected { self.status = .unavailable("Reconnecting to Team Car…") }
                case .disconnected(let why): self.status = .unavailable(why)
                }
            }
        }
    }

    /// The connected client; waits for the first connection.
    func ready() async throws -> TeamCarClient {
        if let client { return client }
        if case .unavailable(let why) = status { throw TeamCarError(code: .unavailable, message: why) }
        if !isEnabled { throw TeamCarError(code: .unavailable, message: "Team Car is disabled") }
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

    private func followServer(_ c: TeamCarClient) async {
        do {
            let sub = try await c.subscribeServer()
            for await event in sub.events {
                if Task.isCancelled { sub.cancel(); return }
                await apply(event, client: c)
            }
        } catch {
            status = .unavailable("Lost the Team Car server stream: \(error.localizedDescription)")
        }
    }

    private func apply(_ event: Radio_Event, client c: TeamCarClient) async {
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
            guard let id = UUID(radioID: id), let repo = app.repo(id) else { return }
            if app.activeWorkspaces(in: repo).isEmpty { app.forgetRepository(id) }
        case .workspaceUpserted(let w):
            upsertWorkspace(w, riders: nil)
        case .workspaceRemoved(let id):
            guard let id = UUID(radioID: id) else { return }
            app.forgetWorkspace(id)
            markSynced(workspace: id, false)
        case .riderUpserted(let r):
            upsertRider(r)
        case .riderRemoved(let id):
            guard let tabID = UUID(radioID: id) else { return }
            activity[tabID] = nil
            for ws in app.state.workspaces where ws.tabs.contains(where: { $0.id == tabID }) && !pendingTabs.contains(tabID) {
                app.model(for: ws.id).dropTab(tabID)
            }
        default:
            break
        }
    }

    /// Brings app and server in line after (re)connecting: imports what only the app knows, adopts what
    /// only the server knows, and drops what was deleted elsewhere.
    private func reconcile(_ snap: Radio_ServerSnapshot, client c: TeamCarClient) async {
        let serverRepos = Dictionary(snap.repositories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let serverWS = Set(snap.workspaces.map(\.id))
        if !isLocal {
            await reconcileRemote(snap, serverWS: serverWS)
            return
        }

        // Repositories the server doesn't have yet (or under another id: adopt the server's id).
        for repo in app.state.repositories where serverRepos[repo.id.radioID] == nil {
            do {
                var req = Radio_AddRepository()
                req.path = repo.path
                req.id = repo.id.radioID
                let r = try await c.addRepository(req)
                if r.id != repo.id.radioID, let newID = UUID(radioID: r.id) { app.renameRepositoryID(repo.id, to: newID) }
            } catch {
                // A clone that's gone from disk can't be registered; keep showing it as before.
                Trace.log("teamcar: couldn't register \(repo.path): \(error.localizedDescription)")
            }
        }
        for r in snap.repositories { upsertRepo(r) }

        // Local workspaces: import the ones the server never had; drop the ones deleted elsewhere.
        let synced = syncedWorkspaces
        for ws in app.state.workspaces where !ws.isRemote && !serverWS.contains(ws.id.radioID) {
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
                Trace.log("teamcar: couldn't import \(ws.name): \(error.localizedDescription)")
            }
        }

        let ridersByWS = Dictionary(grouping: snap.riders, by: \.workspaceID)
        for w in snap.workspaces { upsertWorkspace(w, riders: ridersByWS[w.id] ?? []) }
        for r in snap.riders {
            if let id = UUID(radioID: r.id) { activity[id] = r.activity }
            noteProgress(r)
        }
        if versionCheckPending {
            versionCheckPending = false
            Task { await restartIfOutdated() }
        }
    }

    /// A remote car: map its repositories onto the app's, mirror its workspaces, drop deleted ones.
    /// Nothing is imported: only This Mac has pre-Team Car workspaces.
    private func reconcileRemote(_ snap: Radio_ServerSnapshot, serverWS: Set<String>) async {
        repoMap = [:]
        for r in snap.repositories { upsertRepo(r) }
        let synced = syncedWorkspaces
        for ws in app.state.workspaces where manages(ws) && !serverWS.contains(ws.id.radioID) {
            if synced.contains(ws.id) && !pendingWorkspaces.contains(ws.id) {
                app.forgetWorkspace(ws.id)
                markSynced(workspace: ws.id, false)
            }
        }
        let ridersByWS = Dictionary(grouping: snap.riders, by: \.workspaceID)
        for w in snap.workspaces { upsertWorkspace(w, riders: ridersByWS[w.id] ?? []) }
        for r in snap.riders {
            if let id = UUID(radioID: r.id) { activity[id] = r.activity }
            noteProgress(r)
        }
    }

    /// The server repository for an app repository on this car, cloning it there first if needed.
    private func ensureRepository(_ repo: Repository, client c: TeamCarClient) async throws -> String {
        if isLocal { return repo.id.radioID }
        if let (serverID, _) = repoMap.first(where: { $0.value == repo.id }) { return serverID }
        guard let url = repo.remoteURL, !url.isEmpty else {
            throw TeamCarError(code: .failedPrecondition, message: "\(repo.title) has no remote to clone on \(displayName).")
        }
        var req = Radio_AddRepository()
        req.cloneURL = url
        req.name = repo.name
        req.id = repo.id.radioID
        let r = try await c.addRepository(req)
        repoMap[r.id] = repo.id
        return r.id
    }

    private func importRequest(for ws: Workspace) async -> Radio_ImportWorkspace {
        var w = Radio_Workspace()
        w.id = ws.id.radioID
        w.repositoryID = ws.repoID.radioID
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
        var req = Radio_ImportWorkspace()
        req.workspace = w
        for tab in ws.tabs {
            var r = Radio_Rider()
            r.id = tab.id.radioID
            r.workspaceID = w.id
            r.title = tab.title
            r.provider = tab.provider.radio
            r.model = tab.model ?? ""
            r.effort = tab.effort ?? ""
            r.permissionMode = tab.permissionMode.radio
            r.providerSessionID = tab.providerSessionID ?? ""
            r.createdAtMs = Int64(tab.createdAt.timeIntervalSince1970 * 1000)
            var ir = Radio_ImportRider()
            ir.rider = r
            ir.items = await Store.shared.loadTranscript(tabID: tab.id).map(\.radio)
            req.riders.append(ir)
        }
        return req
    }

    // MARK: mirroring

    private func upsertRepo(_ r: Radio_Repository) {
        if !isLocal {
            // Same id (registered from this app), else the same GitHub repository.
            if let id = UUID(radioID: r.id), app.repo(id) != nil {
                repoMap[r.id] = id
            } else if let slug = GitHubRemote.slug(from: r.remoteURL)?.lowercased(),
                let repo = app.repositories.first(where: { $0.githubSlug?.lowercased() == slug })
            {
                repoMap[r.id] = repo.id
            }
            return
        }
        guard let id = UUID(radioID: r.id) else { return }
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

    /// `riders` nil = keep the app's tabs (a workspace-only update).
    private func upsertWorkspace(_ w: Radio_Workspace, riders: [Radio_Rider]?) {
        guard let id = UUID(radioID: w.id),
            let repoID = isLocal ? UUID(radioID: w.repositoryID) : repoMap[w.repositoryID]
        else { return }
        markSynced(workspace: id, true)
        let state = appState(w)
        serverStates[id] = state
        if app.workspace(id) == nil {
            guard app.repo(repoID) != nil else { return }
            let tabs = (riders ?? []).sorted { $0.createdAtMs < $1.createdAtMs }.map(Self.tab)
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
                if let riders {
                    let serverIDs = Set(riders.compactMap { UUID(radioID: $0.id) })
                    ws.tabs.removeAll { !serverIDs.contains($0.id) && !self.pendingTabs.contains($0.id) }
                    for r in riders.sorted(by: { $0.createdAtMs < $1.createdAtMs }) { Self.merge(r, into: &ws) }
                    if ws.selectedTabID.map({ sid in !ws.tabs.contains { $0.id == sid } }) ?? true {
                        ws.selectedTabID = ws.tabs.first?.id
                    }
                }
            }
        }
        if Self.isSettled(state) { resolveWaiters(id, state) }
    }

    private func upsertRider(_ r: Radio_Rider) {
        guard let tabID = UUID(radioID: r.id), let wsID = UUID(radioID: r.workspaceID) else { return }
        pendingTabs.remove(tabID)
        activity[tabID] = r.activity
        app.updateWorkspaceIfChanged(wsID) { ws in Self.merge(r, into: &ws) }
        noteProgress(r)
    }

    // MARK: unread

    /// Highest transcript seq the user has had on screen, per tab (persisted, so work done while the
    /// app was closed, or from another client, shows as unread).
    @ObservationIgnored private var seenSeqs: [String: UInt64] =
        (UserDefaults.standard.dictionary(forKey: "dq.teamcar.seenSeq") as? [String: NSNumber])?
        .mapValues(\.uint64Value) ?? [:]
    @ObservationIgnored private var lastSeqs: [UUID: UInt64] = [:]

    private func noteProgress(_ r: Radio_Rider) {
        guard let tabID = UUID(radioID: r.id), let wsID = UUID(radioID: r.workspaceID) else { return }
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
        for tab in ws.tabs { if let seq = lastSeqs[tab.id] { setSeen(tab.id.radioID, seq) } }
    }

    private func setSeen(_ riderID: String, _ seq: UInt64) {
        guard seenSeqs[riderID] != seq else { return }
        seenSeqs[riderID] = seq
        UserDefaults.standard.set(seenSeqs.mapValues { NSNumber(value: $0) }, forKey: "dq.teamcar.seenSeq")
    }

    /// What a workspace on this car runs on (nil for This Mac).
    var workspaceHost: WorkspaceHost? {
        guard case .remote(let c) = car else { return nil }
        return WorkspaceHost(provider: .teamcar, machineID: c.id.uuidString, machineName: c.name)
    }

    private static func merge(_ r: Radio_Rider, into ws: inout Workspace) {
        guard let tabID = UUID(radioID: r.id) else { return }
        if let i = ws.tabs.firstIndex(where: { $0.id == tabID }) {
            ws.tabs[i].title = r.title
            ws.tabs[i].provider = ProviderKind(radio: r.provider)
            ws.tabs[i].model = r.model.isEmpty ? nil : r.model
            ws.tabs[i].effort = r.effort.isEmpty ? nil : r.effort
            ws.tabs[i].permissionMode = AgentPermissionMode(radio: r.permissionMode)
            ws.tabs[i].providerSessionID = r.providerSessionID.isEmpty ? nil : r.providerSessionID
        } else {
            ws.tabs.append(tab(r))
            if ws.selectedTabID == nil { ws.selectedTabID = tabID }
        }
    }

    private static func tab(_ r: Radio_Rider) -> ChatTab {
        var t = ChatTab(
            id: UUID(radioID: r.id) ?? UUID(), title: r.title, provider: ProviderKind(radio: r.provider),
            model: r.model.isEmpty ? nil : r.model, permissionMode: AgentPermissionMode(radio: r.permissionMode),
            providerSessionID: r.providerSessionID.isEmpty ? nil : r.providerSessionID,
            createdAt: Date(timeIntervalSince1970: Double(r.createdAtMs) / 1000))
        t.effort = r.effort.isEmpty ? nil : r.effort
        return t
    }

    private func appState(_ w: Radio_Workspace) -> WorkspaceState {
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
    /// Team Car. Returns once the worktree exists (READY) or creation failed (throws).
    func createWorkspace(_ ws: Workspace) async throws {
        pendingWorkspaces.insert(ws.id)
        for t in ws.tabs { pendingTabs.insert(t.id) }
        defer { pendingWorkspaces.remove(ws.id) }
        let c = try await ready()
        guard let repo = app.repo(ws.repoID) else {
            throw TeamCarError(code: .notFound, message: "The repository is gone")
        }
        var req = Radio_CreateWorkspace()
        req.id = ws.id.radioID
        req.repositoryID = try await ensureRepository(repo, client: c)
        req.name = ws.name
        req.branch = ws.branch
        req.baseBranch = ws.baseBranch
        req.skipSetup = true
        if let tab = ws.tabs.first { req.rider = Self.openRequest(tab, workspace: ws.id) }
        _ = try await c.createWorkspace(req, idempotencyKey: "create-" + ws.id.radioID)
        markSynced(workspace: ws.id, true)
        // serverStates catches a READY that arrived before we started waiting.
        switch try await waitForWorkspace(ws.id) {
        case .failed(let why): throw TeamCarError(code: .failedPrecondition, message: why)
        case .archived: throw TeamCarError(code: .failedPrecondition, message: "The workspace was archived")
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
        var req = Radio_ArchiveWorkspace()
        req.workspaceID = ws.id.radioID
        req.skipArchiveScript = true  // the app already ran it in the run dock
        _ = try await c.archiveWorkspace(req)
    }

    func deleteWorkspace(_ ws: Workspace) async throws {
        let c = try await ready()
        var req = Radio_DeleteWorkspace()
        req.workspaceID = ws.id.radioID
        req.deleteBranch = true
        try await c.deleteWorkspace(req)
        markSynced(workspace: ws.id, false)
    }

    func addRepository(path: String) async throws -> Repository {
        let c = try await ready()
        var req = Radio_AddRepository()
        req.path = path
        req.id = UUID().radioID
        let r = try await c.addRepository(req)
        upsertRepo(r)
        guard let id = UUID(radioID: r.id), let repo = app.repo(id) else {
            throw TeamCarError(code: .internal, message: "Team Car returned an invalid repository id")
        }
        return repo
    }

    func removeRepository(_ id: UUID) async throws {
        let c = try await ready()
        do {
            try await c.removeRepository(id: id.radioID)
        } catch let e as TeamCarError where e.code == .notFound {}
    }

    func openRider(_ tab: ChatTab, workspace: UUID) {
        pendingTabs.insert(tab.id)
        let req = Self.openRequest(tab, workspace: workspace)
        Task {
            do {
                _ = try await ready().openRider(req)
            } catch {
                pendingTabs.remove(tab.id)
                app.alert = AppAlert(title: "Couldn't open a chat", message: error.localizedDescription)
            }
        }
    }

    func closeRider(_ tabID: UUID) async {
        pendingTabs.remove(tabID)
        activity[tabID] = nil
        _ = try? await ready().closeRider(id: tabID.radioID)
    }

    /// Swaps the tab's rider for a fresh one (e.g. a different provider), keeping the tab.
    func replaceRider(_ tab: ChatTab, workspace: UUID) async {
        pendingTabs.insert(tab.id)
        activity[tab.id] = nil
        _ = try? await ready().closeRider(id: tab.id.radioID)
        openRider(tab, workspace: workspace)
    }

    static func openRequest(_ tab: ChatTab, workspace: UUID) -> Radio_OpenRider {
        var r = Radio_OpenRider()
        r.id = tab.id.radioID
        r.workspaceID = workspace.radioID
        r.provider = tab.provider.radio
        r.model = tab.model ?? ""
        r.effort = tab.effort ?? ""
        r.permissionMode = tab.permissionMode.radio
        r.title = tab.title
        return r
    }

    func listModels(_ provider: ProviderKind) async -> [ModelOption]? {
        guard let models = try? await ready().listModels(provider.radio), !models.isEmpty else { return nil }
        return models.map(ModelOption.init(radio:))
    }

    func isRiderRunning(_ tabID: UUID) -> Bool {
        guard let a = activity[tabID] else { return false }
        return a == .running || a == .awaitingInput
    }

    func isRiderAwaiting(_ tabID: UUID) -> Bool { activity[tabID] == .awaitingInput }

    // MARK: which workspaces this server has seen

    /// Ids of local workspaces known to exist on this Team Car. A workspace that's in here but missing
    /// from the server was deleted elsewhere (don't re-import it).
    private var syncedWorkspaces: Set<UUID> {
        guard let serverID else { return [] }
        let raw = UserDefaults.standard.stringArray(forKey: "dq.teamcar.synced.\(serverID)") ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func markSynced(workspace id: UUID, _ synced: Bool) {
        guard let serverID else { return }
        var set = syncedWorkspaces
        let changed = synced ? set.insert(id).inserted : set.remove(id) != nil
        guard changed else { return }
        UserDefaults.standard.set(set.map(\.uuidString), forKey: "dq.teamcar.synced.\(serverID)")
    }
}
