import AgentKit
import AppKit
import DQCore
import Foundation
import GitHubKit
import GitKit
import HostKit
import Observation
import ProcessKit
import ServerKit

@MainActor
@Observable
final class AppModel {
    private(set) var state: AppState
    private var workspaceModels: [UUID: WorkspaceModel] = [:]
    var modelsByProvider: [ProviderKind: [ModelOption]] = AppModel.cachedModels()
    var alert: AppAlert?
    /// Bumped whenever the user navigates to a chat (workspace or tab); the composer focuses itself on change.
    var composerFocusRequest = 0
    /// In-app settings page; nil = closed.
    var settingsRoute: SettingsRoute?
    /// "Clone from GitHub" sheet.
    var showGitHubPicker = false
    /// "New workspace from pull request" sheet, for this repository.
    var pullRequestPickerRepo: Repository?
    // Layout (persisted)
    var sidebarVisible = UserDefaults.standard.object(forKey: "dq.sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "dq.sidebarVisible") }
    }
    var rightPanelVisible = UserDefaults.standard.object(forKey: "dq.rightPanelVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rightPanelVisible, forKey: "dq.rightPanelVisible") }
    }
    /// Usage left per provider, from rate-limit events (0...1 used), for the sidebar ring.
    var usage: [ProviderKind: UsageInfo] = [:]
    /// Cloud machine status + actions (boat.dev).
    @ObservationIgnored private(set) var cloud: CloudMachines!
    /// This Mac's server: runs agents and local worktrees.
    @ObservationIgnored private(set) var server: ServerLink!
    /// Remote servers from Settings → Servers, by id.
    private(set) var remoteServers: [UUID: ServerLink] = [:]
    /// Pending saves of edited sandbox providers to their server (debounced per provider).
    @ObservationIgnored var providerSaveTasks: [UUID: Task<Void, Never>] = [:]
    /// Progress line for workspaces being created ("Cloning …").
    var creationSteps: [UUID: String] = [:]
    /// Stage-by-stage progress of boat.dev workspaces, kept after they finish until dismissed.
    var creationTimelines: [UUID: CreationTimeline] = [:]
    /// Workspaces with an archive in flight (script, teardown and worktree removal can take a while).
    private(set) var archiving: Set<UUID> = []
    /// Brief confirmation shown at the bottom of the window.
    var toast: String? {
        didSet {
            guard toast != nil else { return }
            toastTask?.cancel()
            toastTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self?.toast = nil
            }
        }
    }
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func recordUsage(_ info: RateLimitInfo, for provider: ProviderKind) {
        usage[provider, default: UsageInfo()].merge(info)
    }

    /// Checks GitHub Releases for newer CI builds; drives the sidebar's update button.
    let updater = Updater()

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var hasPendingSave = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var lastDataVersion: Int64 = 0

    init() {
        var state = Store.shared.loadStateSync()
        // Anything mid-creation when we last quit didn't finish.
        for i in state.workspaces.indices {
            switch state.workspaces[i].state {
            case .creating where state.workspaces[i].path.hasPrefix(BoatHost.home):
                // A cloud workspace whose sandbox/clone didn't finish before we quit.
                state.workspaces[i].state = .failed("Creation was interrupted. Archive this workspace and create a new one.")
            case .creating, .settingUp:
                // Server workspaces: its server stream says how creation ended.
                let serverOwned = (state.workspaces[i].host == nil
                    && ProcessInfo.processInfo.environment["DOMESTIQUE_LEGACY_ENGINE"] != "1")
                    || state.workspaces[i].host?.provider == .server
                if !serverOwned { state.workspaces[i].state = .ready }
            default: break
            }
        }
        let loaded = state
        self.state = state
        lastDataVersion = Store.shared.dataVersion()
        cloud = CloudMachines(app: self)
        server = ServerLink(app: self)
        server.start()
        ServerDirectory.shared.update(state.settings.servers)
        Hosts.serverResolver = { h in ServerDirectory.shared.host(for: h) }
        for cfg in state.settings.servers { startServer(cfg) }
        installSandboxRouting()
        // Coming back to the app (e.g. after editing domestique.toml elsewhere): re-check the config.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.selectedWorkspaceModel?.reloadConfigIfChanged() }
        }
        Task {
            await Store.shared.markLoaded(loaded)
            self.scheduleSave()  // persists any launch fix-ups above
        }
        startSync()
        updater.start()
        Task { await loadCodexModels() }
        Task { await loadClaudeModels() }
        Task { [weak self] in
            // Keep every open PR's checks fresh from launch, not only the workspace on screen.
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            for ws in self.state.workspaces where !ws.isArchived && ws.prNumber != nil {
                self.model(for: ws.id).refreshPR()
            }
        }
        Task { await handleLaunchArguments() }
        Task { [weak self] in
            for await info in CodexAppServer.shared.rateLimits {
                self?.recordUsage(info, for: .codex)
            }
        }
    }

    /// `Domestique --add-repo <path> [--prompt "..."]` adds/selects a repo (and optionally kicks off a chat).
    private func handleLaunchArguments() async {
        let args = ProcessInfo.processInfo.arguments
        // `--settings general|agents|repo` opens the in-app settings page.
        if let i = args.firstIndex(of: "--settings") {
            let page = i + 1 < args.count ? args[i + 1] : "general"
            switch page {
            case "agents": settingsRoute = .agents
            case "cloud", "sandboxes": settingsRoute = .servers
            case "servers": settingsRoute = .servers
            case "repo": settingsRoute = state.repositories.first.map { .repo($0.id) } ?? .general
            default: settingsRoute = .general
            }
        }
        guard let i = args.firstIndex(of: "--add-repo"), i + 1 < args.count else { return }
        let path = URL(fileURLWithPath: (args[i + 1] as NSString).standardizingPath).resolvingSymlinksInPath().path
        if let repo = state.repositories.first(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path
        }) {
            selectedWorkspaceID = activeWorkspaces(in: repo).first?.id
        } else {
            await addRepository(path: path)
        }
        // `--new-workspace local|boat` creates a fresh workspace there (e.g. to try a cloud workspace).
        if let n = args.firstIndex(of: "--new-workspace"), n + 1 < args.count,
            let repo = selectedWorkspaceModel?.repo ?? state.repositories.first(where: {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path
            })
        {
            let loc = workspaceLocations.first { $0.id == args[n + 1] || locationName($0) == args[n + 1] } ?? .local
            await createWorkspace(in: repo, location: loc)
        }
        if let p = args.firstIndex(of: "--prompt"), p + 1 < args.count, let model = selectedWorkspaceModel {
            model.selectedChat?.send(text: args[p + 1])
        }
        // `--run` starts the selected workspace's default stack.
        if args.contains("--run"), let model = selectedWorkspaceModel {
            try? await Task.sleep(for: .seconds(1))
            model.startDefaultStack()
        }
    }

    // MARK: lookups

    var settings: AppSettings {
        get { state.settings }
        set {
            state.settings = newValue
            scheduleSave()
        }
    }

    var repositories: [Repository] { state.repositories }

    func repo(_ id: UUID) -> Repository? { state.repositories.first { $0.id == id } }

    func workspace(_ id: UUID) -> Workspace? { state.workspaces.first { $0.id == id } }

    func activeWorkspaces(in repo: Repository) -> [Workspace] {
        state.workspaces.filter { $0.repoID == repo.id && !$0.isArchived }.sorted { $0.createdAt > $1.createdAt }
    }

    func archivedWorkspaces(in repo: Repository) -> [Workspace] {
        state.workspaces.filter { $0.repoID == repo.id && $0.isArchived }.sorted { $0.createdAt > $1.createdAt }
    }

    var selectedWorkspaceID: UUID? {
        get { state.selectedWorkspaceID }
        set {
            settingsRoute = nil
            composerFocusRequest += 1
            if let newValue, let ws = workspace(newValue) { selectedRepoID = ws.repoID }
            guard state.selectedWorkspaceID != newValue else { return }
            if let old = state.selectedWorkspaceID { workspaceModels[old]?.supervisor?.isFocused = false }
            state.selectedWorkspaceID = newValue
            if let newValue {
                updateWorkspace(newValue) { $0.hasUnread = false }
                server.markSeen(workspace: newValue)
                workspaceModels[newValue]?.supervisor?.isFocused = true
                workspaceModels[newValue]?.reloadConfigIfChanged()
            }
            scheduleSave()
        }
    }

    /// The project shown when no workspace is selected (its home page). Follows the selected workspace.
    var selectedRepoID: UUID? = UserDefaults.standard.string(forKey: "dq.selectedRepoID").flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(selectedRepoID?.uuidString, forKey: "dq.selectedRepoID") }
    }

    /// The selected workspace's repo, else the selected project.
    var selectedRepo: Repository? {
        if let ws = selectedWorkspaceID.flatMap(workspace) { return repo(ws.repoID) }
        return selectedRepoID.flatMap(repo)
    }

    /// Shows a project's home page (deselects any workspace).
    func showProject(_ repo: Repository) {
        selectedWorkspaceID = nil
        selectedRepoID = repo.id
    }

    /// Back to the Domestique welcome page.
    func showHome() {
        selectedWorkspaceID = nil
        selectedRepoID = nil
    }

    var selectedWorkspaceModel: WorkspaceModel? {
        guard let id = selectedWorkspaceID, workspace(id) != nil else { return nil }
        return model(for: id)
    }

    func model(for workspaceID: UUID) -> WorkspaceModel {
        if let m = workspaceModels[workspaceID] { return m }
        let m = WorkspaceModel(id: workspaceID, app: self)
        workspaceModels[workspaceID] = m
        return m
    }

    func existingModel(for workspaceID: UUID) -> WorkspaceModel? { workspaceModels[workspaceID] }

    // MARK: Servers

    /// The server running this workspace's agents, if any (nil for boat.dev and legacy workspaces).
    func link(for ws: Workspace?) -> ServerLink? {
        guard let ws else { return nil }
        if let id = ws.serverID { return remoteServers[id] }
        return server.manages(ws) ? server : nil
    }

    /// This Mac's server first, then the remote ones in settings order.
    var serverLinks: [ServerLink] {
        [server] + settings.servers.compactMap { remoteServers[$0.id] }
    }

    private func startServer(_ cfg: ServerConfig) {
        let link = ServerLink(app: self, server: .remote(cfg))
        remoteServers[cfg.id] = link
        link.start()
    }

    func addServer(_ cfg: ServerConfig, token: String) throws {
        try ServerTokens.set(token, for: cfg.id)
        settings.servers.append(cfg)
        ServerDirectory.shared.update(settings.servers)
        startServer(cfg)
    }

    /// Name, URL or token changed: reconnect.
    func updateServer(_ cfg: ServerConfig, token: String?) throws {
        if let token, !token.isEmpty { try ServerTokens.set(token, for: cfg.id) }
        guard let i = settings.servers.firstIndex(where: { $0.id == cfg.id }) else { return }
        settings.servers[i] = cfg
        ServerDirectory.shared.update(settings.servers)
        remoteServers[cfg.id]?.close()
        startServer(cfg)
        for ws in state.workspaces where ws.serverID == cfg.id {
            updateWorkspaceIfChanged(ws.id) { $0.host?.machineName = cfg.name }
        }
    }

    /// Forgets the server and its workspaces here. They keep existing on the server.
    func removeServer(_ id: UUID) {
        remoteServers[id]?.close()
        remoteServers[id] = nil
        for ws in state.workspaces where ws.serverID == id { forgetWorkspace(ws.id) }
        // Its sandbox providers go with it (their sandboxes stay on the service).
        for p in settings.sandboxProviders where p.remoteServerID == id && activeWorkspaces(on: p).isEmpty {
            forgetSandboxProvider(p)
        }
        settings.servers.removeAll { $0.id == id }
        ServerDirectory.shared.update(settings.servers)
        ServerTokens.delete(id)
        for repo in state.repositories where repo.defaultLocation.map({ server(of: $0) == .server(id) }) ?? false {
            updateRepo(repo.id) { $0.defaultLocation = nil }
        }
        if settings.defaultServer == .server(id) { settings.defaultServer = nil }
        settings.setPreferences(ServerPreferences(), for: .server(id))
    }

    // MARK: mutation

    func updateWorkspace(_ id: UUID, _ mutate: (inout Workspace) -> Void) {
        guard let i = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        mutate(&state.workspaces[i])
        scheduleSave()
    }

    func updateRepo(_ id: UUID, _ mutate: (inout Repository) -> Void) {
        guard let i = state.repositories.firstIndex(where: { $0.id == id }) else { return }
        mutate(&state.repositories[i])
        scheduleSave()
    }

    /// Like updateWorkspace, but skips the save when nothing changed (server echoes are frequent).
    func updateWorkspaceIfChanged(_ id: UUID, _ mutate: (inout Workspace) -> Void) {
        guard let i = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        var copy = state.workspaces[i]
        mutate(&copy)
        guard copy != state.workspaces[i] else { return }
        state.workspaces[i] = copy
        scheduleSave()
    }

    func updateRepoIfChanged(_ id: UUID, _ mutate: (inout Repository) -> Void) {
        guard let i = state.repositories.firstIndex(where: { $0.id == id }) else { return }
        var copy = state.repositories[i]
        mutate(&copy)
        guard copy != state.repositories[i] else { return }
        state.repositories[i] = copy
        scheduleSave()
    }

    // MARK: mirroring server

    /// A repository another client added to the server.
    func adoptRepository(_ repo: Repository) {
        guard self.repo(repo.id) == nil else { return }
        state.repositories.append(repo)
        scheduleSave()
    }

    /// A workspace another client created on the server.
    func adoptWorkspace(_ ws: Workspace) {
        guard workspace(ws.id) == nil else { return }
        state.workspaces.append(ws)
        scheduleSave()
    }

    /// Removed on the server by another client.
    func forgetWorkspace(_ id: UUID) {
        guard workspace(id) != nil else { return }
        workspaceModels[id]?.shutdownNow()
        workspaceModels[id] = nil
        state.workspaces.removeAll { $0.id == id }
        if state.selectedWorkspaceID == id { state.selectedWorkspaceID = nil }
        scheduleSave()
    }

    func forgetRepository(_ id: UUID) {
        state.workspaces.removeAll { $0.repoID == id && $0.isArchived }
        state.repositories.removeAll { $0.id == id }
        if selectedRepoID == id { selectedRepoID = nil }
        scheduleSave()
    }

    /// Server already knew this clone under another id: adopt its id.
    func renameRepositoryID(_ old: UUID, to new: UUID) {
        guard let i = state.repositories.firstIndex(where: { $0.id == old }) else { return }
        if repo(new) != nil {
            state.repositories.remove(at: i)
        } else {
            state.repositories[i].id = new
        }
        for j in state.workspaces.indices where state.workspaces[j].repoID == old { state.workspaces[j].repoID = new }
        if selectedRepoID == old { selectedRepoID = new }
        scheduleSave()
    }

    func scheduleSave() {
        hasPendingSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.hasPendingSave = false
            await Store.shared.save(self.state)
        }
    }

    func saveNow() async {
        saveTask?.cancel()
        hasPendingSave = false
        await Store.shared.save(state)
    }

    // MARK: sharing the database with other running instances

    /// Every running copy of the app uses the same SQLite file. When another one commits,
    /// pull its repositories / workspaces / settings and any new chat items.
    private func startSync() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                let version = Store.shared.dataVersion()
                guard version != self.lastDataVersion else { continue }
                self.lastDataVersion = version
                await self.reloadFromStore()
            }
        }
    }

    private func reloadFromStore() async {
        if hasPendingSave { await saveNow() }  // don't lose local edits
        let fresh = Store.shared.loadStateSync()
        let selected = state.selectedWorkspaceID
        let local = Dictionary(state.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        state.repositories = fresh.repositories
        state.workspaces = fresh.workspaces.map { theirs in
            guard let mine = local[theirs.id] else { return theirs }
            var merged = theirs
            merged.keepLocalTabState(from: mine, opening: link(for: mine)?.openingTabs ?? [])
            return merged
        }
        state.settings = fresh.settings
        state.selectedWorkspaceID = selected  // selection stays per-window
        await Store.shared.markLoaded(state)
        let ids = Set(state.workspaces.map(\.id))
        for id in workspaceModels.keys where !ids.contains(id) { workspaceModels[id] = nil }
        for model in workspaceModels.values { model.syncChatsFromStore() }
    }

    // MARK: repositories

    func promptAddRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        panel.message = "Choose a git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addRepository(path: url.path) }
    }

    func addRepository(path: String) async {
        if server.isEnabled {
            do {
                if let existing = state.repositories.first(where: {
                    URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                        == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                }) {
                    showProject(existing)
                    return
                }
                showProject(try await server.addRepository(path: path))
            } catch {
                alert = AppAlert(title: "Couldn't add repository", message: error.localizedDescription)
            }
            return
        }
        do {
            let info = try await Git.repoInfo(path: path)
            if let existing = state.repositories.first(where: { $0.path == info.root }) {
                // Already added: just jump to it.
                showProject(existing)
                return
            }
            let name = URL(fileURLWithPath: info.root).lastPathComponent
            let repo = Repository(name: name, path: info.root, remoteURL: info.remoteURL, defaultBranch: info.defaultBranch)
            Trace.log("repo info ok")
            state.repositories.append(repo)
            scheduleSave()
            showProject(repo)
        } catch {
            alert = AppAlert(title: "Couldn't add repository", message: error.localizedDescription)
        }
    }

    /// The already-added repository whose origin is this GitHub repo, if any.
    func localRepository(for gh: GitHubRepo) -> Repository? {
        state.repositories.first { $0.githubSlug?.lowercased() == gh.fullName.lowercased() }
    }

    /// Clones a GitHub repo into the clone root (<root>/<owner>/<name>), adds it, and shows its project page.
    /// Already-added repos are just selected; an existing clone at the destination is reused.
    func cloneFromGitHub(_ gh: GitHubRepo) async throws {
        if let existing = localRepository(for: gh) {
            showProject(existing)
            return
        }
        let dest = settings.cloneRoot.appendingPathComponent(gh.owner).appendingPathComponent(gh.name).path
        if FileManager.default.fileExists(atPath: dest) {
            let info = try? await Git.repoInfo(path: dest)
            guard let info, info.root == URL(fileURLWithPath: dest).resolvingSymlinksInPath().path || info.root == dest,
                GitHubRemote.slug(from: info.remoteURL)?.lowercased() == gh.fullName.lowercased()
            else {
                throw GitHubError(message: "\(dest) already exists and isn't a clone of \(gh.fullName).")
            }
        } else {
            do {
                try await Git.clone(slug: gh.fullName, url: gh.cloneURL, to: dest)
            } catch {
                // Don't leave a half-cloned folder behind to trip up the next attempt.
                try? FileManager.default.removeItem(atPath: dest)
                throw error
            }
        }
        await addRepository(path: dest)
    }

    func removeRepository(_ repo: Repository) {
        state.workspaces.removeAll { $0.repoID == repo.id && $0.isArchived }
        guard activeWorkspaces(in: repo).isEmpty else {
            alert = AppAlert(title: "Archive workspaces first", message: "\(repo.name) still has active workspaces.")
            return
        }
        state.repositories.removeAll { $0.id == repo.id }
        for provider in settings.sandboxProviders { SandboxEnvironmentStore.save([], provider: provider.id, repo: repo.id) }
        if selectedRepoID == repo.id { selectedRepoID = nil }
        scheduleSave()
        if server.isEnabled {
            Task {
                do {
                    try await server.removeRepository(repo.id)
                } catch {
                    alert = AppAlert(title: "Couldn't remove the repository from the server", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: workspaces

    /// The active workspace already working on `pr`, if any.
    func workspace(for pr: PullRequestSummary, in repo: Repository) -> Workspace? {
        activeWorkspaces(in: repo).first {
            $0.prNumber == pr.number || (!pr.isCrossRepository && $0.branch == pr.headRefName)
        }
    }

    /// Jumps to the workspace already on `pr`, or starts one checked out at its head.
    func openPullRequest(_ pr: PullRequestSummary, in repo: Repository, location: WorkspaceLocation? = nil) async {
        if let ws = workspace(for: pr, in: repo) {
            selectedWorkspaceID = ws.id
            return
        }
        await createWorkspace(in: repo, location: location, pullRequest: pr)
    }

    /// New workspace = fresh worktree branched from a just-fetched origin/<default>. Never from the local checkout.
    /// With `pullRequest`, the worktree is then moved to that PR's head: same-repo PRs keep their branch name
    /// (so pushing updates the PR and it's linked); fork PRs get a local `pr-<n>` branch instead.
    func createWorkspace(
        in repo: Repository, provider: ProviderKind? = nil, location: WorkspaceLocation? = nil,
        pullRequest pr: PullRequestSummary? = nil
    ) async {
        let location = location ?? defaultLocation(for: repo)
        if isWorktree(location), !settings.preferences(for: server(of: location)).worktrees {
            let name = serverName(for: server(of: location))
            alert = AppAlert(
                title: "Worktrees are off on \(name)",
                message: "Turn them back on, or add a sandbox provider to a server, in Settings → Servers.")
            return
        }
        let used = Set(state.workspaces.filter { $0.repoID == repo.id }.map(\.name))
        let name = WorkspaceNames.next(excluding: used)
        let prefix = settings.branchPrefix.trimmingCharacters(in: .whitespaces)
        let branch: String =
            if let pr, !pr.isCrossRepository, !pr.headRefName.isEmpty { pr.headRefName }
            else if let pr { prefix.isEmpty ? "pr-\(pr.number)" : "\(prefix)/pr-\(pr.number)" }
            else { prefix.isEmpty ? name : "\(prefix)/\(name)" }
        let linkPR = pr.map { !$0.isCrossRepository } ?? false
        let target: ServerLink? = if case .server(let id) = location { remoteServers[id] } else { nil }
        if case .server = location, target == nil {
            alert = AppAlert(title: "Server not found", message: "That server isn't in Settings → Servers any more.")
            return
        }
        let remote = location != .local
        let path =
            target != nil
            ? ""  // the server's path arrives with its first update
            : remote
            ? "\(BoatHost.home)/\(repo.name)"
            : Paths.workspacesRoot.appendingPathComponent(repo.name).appendingPathComponent(name).path
        let usedPorts = Set(state.workspaces.filter { !$0.isArchived }.map(\.portBase))
        // Server assigns local workspaces' ports (and updates this); cloud ones use their own range.
        let portBase = PortAllocator.allocate(used: usedPorts, in: remote ? PortAllocator.cloudRange : PortAllocator.localRange)
        let provider = provider ?? settings.defaultProvider
        var tab = ChatTab(
            provider: provider, model: defaultModel(for: provider), permissionMode: settings.defaultPermissionMode)
        tab.effort = defaultEffort(for: provider)
        if let pr { tab.title = "#\(pr.number) \(pr.title)" }
        var ws = Workspace(
            repoID: repo.id, name: name, branch: branch, path: path, baseBranch: repo.defaultBranch,
            portBase: portBase, state: .creating, prNumber: linkPR ? pr?.number : nil,
            prURL: linkPR ? pr?.url : nil, tabs: [tab], selectedTabID: tab.id)
        ws.host = target?.workspaceHost
        state.workspaces.append(ws)
        selectedWorkspaceID = ws.id
        scheduleSave()

        Trace.log("ws created, selected")
        if let target {
            // The server clones (once) and creates the worktree; setup runs from here, on the server.
            setCreationStep(ws.id, "Creating on \(target.displayName)")
            target.settingUp.insert(ws.id)
            defer { target.settingUp.remove(ws.id) }
            do {
                try await target.createWorkspace(ws)
                if let pr { try await checkOutPullRequest(pr, in: ws.id) }
                setCreationStep(ws.id, "Running setup")
                updateWorkspace(ws.id) { $0.state = .settingUp }
                let model = model(for: ws.id)
                await model.loadConfigAsync()
                await model.runSetup()
                creationSteps[ws.id] = nil
                updateWorkspace(ws.id) { $0.state = .ready }
            } catch {
                creationSteps[ws.id] = nil
                updateWorkspace(ws.id) { $0.state = .failed(error.localizedDescription) }
            }
            return
        }
        if remote {
            do {
                guard let provider = settings.provider(for: location) else {
                    throw HostError("That sandbox provider isn't in Settings → Servers any more.")
                }
                try await provisionBoatWorkspace(ws.id, repo: repo, provider: provider, pullRequest: pr?.number)
                if let pr { try await checkOutPullRequest(pr, in: ws.id) }
                beginStage(ws.id, .setup)
                let model = model(for: ws.id)
                await model.loadConfigAsync()
                await model.runSetup()
                creationTimelines[ws.id]?.finish()
                updateWorkspace(ws.id) { $0.state = .ready }
            } catch {
                creationTimelines[ws.id]?.fail()
                updateWorkspace(ws.id) { $0.state = .failed(error.localizedDescription) }
            }
            return
        }
        if server.isEnabled {
            // Server fetches and creates the worktree; the app runs setup so its output shows in the dock.
            server.settingUp.insert(ws.id)
            defer { server.settingUp.remove(ws.id) }
            do {
                try await server.createWorkspace(ws)
                if let pr {
                    try await checkOutPullRequest(pr, in: ws.id)
                    creationSteps[ws.id] = nil
                }
                updateWorkspace(ws.id) { $0.state = .settingUp }
                let model = model(for: ws.id)
                model.recordGhMergeBase()
                model.loadConfig()
                await model.runSetup()
                updateWorkspace(ws.id) { $0.state = .ready }
            } catch {
                creationSteps[ws.id] = nil
                updateWorkspace(ws.id) { $0.state = .failed(error.localizedDescription) }
            }
            return
        }
        do {
            try await Git.fetch(repoPath: repo.path, branch: repo.defaultBranch)
            Trace.log("fetched")
            let base = try await Git.createWorktree(
                repoPath: repo.path, path: path, branch: branch, base: "origin/\(repo.defaultBranch)")
            Trace.log("worktree added")
            if let pr {
                try await checkOutPullRequest(pr, in: ws.id)
                creationSteps[ws.id] = nil
            }
            updateWorkspace(ws.id) {
                $0.baseCommit = base
                $0.state = .settingUp
            }
            model(for: ws.id).recordGhMergeBase()
            Trace.log("state settingUp")
            let model = model(for: ws.id)
            model.loadConfig()
            Trace.log("config loaded")
            await model.runSetup()
            Trace.log("setup done")
            updateWorkspace(ws.id) { $0.state = .ready }
            Trace.log("ready")
        } catch {
            creationSteps[ws.id] = nil
            updateWorkspace(ws.id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// Moves a just-created workspace's branch to `pr`'s head, on whichever host the workspace lives.
    private func checkOutPullRequest(_ pr: PullRequestSummary, in wsID: UUID) async throws {
        guard let ws = workspace(wsID), !ws.path.isEmpty else {
            throw GitError("The workspace has no worktree to check #\(pr.number) out into.")
        }
        setCreationStep(wsID, "Checking out #\(pr.number)")
        beginStage(wsID, .pullRequest)
        try await Git.checkOutPullRequest(path: ws.path, number: pr.number, host: model(for: wsID).host)
    }

    func archive(_ ws: Workspace) async {
        guard let repo = repo(ws.repoID), archiving.insert(ws.id).inserted else { return }
        defer { archiving.remove(ws.id) }
        if let m = existingModel(for: ws.id) {
            await m.prepareForArchive()
        }
        if ws.isSandbox {
            await archiveRemote(ws)
        } else if let link = link(for: ws) {
            do {
                try await link.archiveWorkspace(ws)
            } catch let e as ServerError where e.code == .notFound {
                // Creation failed before the server heard of it, so there's nothing to tear down.
            } catch {
                alert = AppAlert(title: "Couldn't archive workspace", message: error.localizedDescription)
                return
            }
        } else { do {
            if FileManager.default.fileExists(atPath: ws.path) {
                try await Git.removeWorktree(repoPath: repo.path, path: ws.path, force: true)
            }
        } catch {
            alert = AppAlert(title: "Couldn't remove worktree", message: error.localizedDescription)
        } }
        workspaceModels[ws.id] = nil
        // An archived workspace can't reopen anything, so closed chats end here.
        for closed in workspace(ws.id)?.closedTabs ?? [] { await Store.shared.deleteTranscript(tabID: closed.id) }
        updateWorkspace(ws.id) {
            $0.state = .archived
            $0.closedTabs = nil
        }
        if selectedWorkspaceID == ws.id {
            selectedWorkspaceID = activeWorkspaces(in: repo).first?.id
        }
    }

    func deleteArchived(_ ws: Workspace) async {
        guard ws.isArchived else { return }
        for tab in ws.tabs { await Store.shared.deleteTranscript(tabID: tab.id) }
        for closed in ws.closedTabs ?? [] { await Store.shared.deleteTranscript(tabID: closed.id) }
        if ws.isSandbox {
            await deleteRemote(ws)
        } else if let link = link(for: ws) {
            do {
                try await link.deleteWorkspace(ws)
            } catch let e as ServerError where e.code == .notFound {
                // Already gone from the server (or it never got there).
            } catch {
                alert = AppAlert(title: "Couldn't delete workspace", message: error.localizedDescription)
                return
            }
        } else if let repo = repo(ws.repoID) {
            try? await Git.deleteBranch(repoPath: repo.path, branch: ws.branch)
        }
        state.workspaces.removeAll { $0.id == ws.id }
        scheduleSave()
    }

    // MARK: models

    func defaultModel(for provider: ProviderKind) -> String? {
        switch provider {
        case .claude: settings.defaultClaudeModel
        case .codex: settings.defaultCodexModel
        }
    }

    func defaultEffort(for provider: ProviderKind) -> String? {
        switch provider {
        case .claude: settings.defaultClaudeEffort
        case .codex: settings.defaultCodexEffort
        }
    }

    func models(for provider: ProviderKind) -> [ModelOption] { modelsByProvider[provider] ?? [] }

    /// The model a tab actually runs: its explicit choice, else the provider's default.
    func resolvedModel(_ provider: ProviderKind, _ id: String?) -> ModelOption? {
        let all = models(for: provider)
        if let id { return all.first { $0.id == id } }
        return all.first { $0.isDefault } ?? all.first
    }

    /// What to call a model in the UI: its real name ("Opus 5.5"), never just "Default" or "Claude".
    func modelLabel(_ provider: ProviderKind, _ id: String?) -> String {
        let all = models(for: provider)
        guard let id else {
            if let d = all.first(where: \.isDefault), d.displayName != "Default" { return d.displayName }
            return provider.displayName
        }
        return all.first { $0.id == id }?.displayName ?? id
    }

    /// Selectable models (the synthetic Claude "default" entry is represented by the Default row).
    func pickableModels(for provider: ProviderKind) -> [ModelOption] {
        models(for: provider).filter { $0.id != "default" }
    }

    func updateModels(_ models: [ModelOption], for provider: ProviderKind) {
        guard !models.isEmpty, modelsByProvider[provider] != models else { return }
        modelsByProvider[provider] = models
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: modelsByProvider.map { ($0.key.rawValue, $0.value) })) {
            UserDefaults.standard.set(data, forKey: Self.modelsCacheKey)
        }
    }

    private static let modelsCacheKey = "dq.models.v1"

    /// Last-known model lists, so the picker shows real names before any provider has answered.
    private static func cachedModels() -> [ProviderKind: [ModelOption]] {
        var result: [ProviderKind: [ModelOption]] = [.claude: ClaudeSession.fallbackModels]
        if let data = UserDefaults.standard.data(forKey: modelsCacheKey),
            let cached = try? JSONDecoder().decode([String: [ModelOption]].self, from: data)
        {
            for (key, models) in cached {
                if let p = ProviderKind(rawValue: key), !models.isEmpty { result[p] = models }
            }
        }
        return result
    }

    private func loadClaudeModels() async {
        if server.isEnabled {
            if let models = await server.listModels(.claude) { updateModels(models, for: .claude) }
            return
        }
        if let models = await ClaudeSession.probeModels() { updateModels(models, for: .claude) }
    }

    private func loadCodexModels() async {
        if server.isEnabled {
            if let models = await server.listModels(.codex) { updateModels(models, for: .codex) }
            return
        }
        if let models = try? await CodexAppServer.shared.listModels() { updateModels(models, for: .codex) }
    }

    // MARK: lifecycle

    func shutdown() {
        // Quitting stops This Mac's server and its agents, unless Settings says to keep it running or
        // another local client is still using it. Remote servers always keep going.
        var stopping: [Task<Void, Never>] = []
        for link in serverLinks {
            if link.isLocal, !settings.keepServerRunning {
                if let stop = link.stopServerIfLastClient() { stopping.append(stop) }
            } else {
                link.close()
            }
        }
        for m in workspaceModels.values { m.shutdownNow() }
        let state = self.state
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [stopping] in
            await Store.shared.save(state)
            for stop in stopping { await stop.value }
            await CodexAppServer.shared.shutdown()
            for server in CodexAppServer.remoteServers { await server.shutdown() }
            // Drop SSH masters and port forwards; the sandboxes keep running (and auto-stop).
            for host in Hosts.allBoatHosts { await host.ssh.closeMaster() }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }
}

enum SettingsRoute: Hashable {
    case general
    case agents
    case servers
    case repo(UUID)
}

/// Latest known usage per provider. Rate-limit events can be partial (Claude often only reports the window
/// that's closest to its limit), so windows are merged by id and kept until replaced.
struct UsageInfo: Equatable {
    var windows: [RateLimitWindow] = []
    var usingOverage = false
    var overageStatus: String?
    var overageDisabledReason: String?
    var plan: String?
    var updatedAt: Date = .now

    mutating func merge(_ info: RateLimitInfo) {
        for w in info.windows {
            if let i = windows.firstIndex(where: { $0.id == w.id }) { windows[i] = w } else { windows.append(w) }
        }
        windows.sort { ($0.order, $0.id) < ($1.order, $1.id) }
        usingOverage = info.usingOverage
        overageStatus = info.overageStatus ?? overageStatus
        overageDisabledReason = info.overageDisabledReason
        plan = info.plan ?? plan
        updatedAt = .now
    }

    /// Used fraction, treating a window whose reset time has passed as empty.
    static func used(_ w: RateLimitWindow, now: Date = .now) -> Double {
        if let r = w.resetsAt, r <= now { return 0 }
        return w.usedFraction
    }

    /// The most-used window right now (drives the ring).
    var worst: RateLimitWindow? { windows.max { Self.used($0) < Self.used($1) } }
    var usedFraction: Double { worst.map { Self.used($0) } ?? 0 }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
