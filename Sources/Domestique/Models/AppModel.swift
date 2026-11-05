import AgentKit
import AppKit
import DQCore
import Foundation
import GitHubKit
import GitKit
import Observation
import ProcessKit

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
    // Layout (persisted)
    var sidebarVisible = UserDefaults.standard.object(forKey: "dq.sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "dq.sidebarVisible") }
    }
    var rightPanelVisible = UserDefaults.standard.object(forKey: "dq.rightPanelVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rightPanelVisible, forKey: "dq.rightPanelVisible") }
    }
    /// Usage left per provider, from rate-limit events (0...1 used), for the sidebar ring.
    var usage: [ProviderKind: UsageInfo] = [:]

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
            case .creating, .settingUp: state.workspaces[i].state = .ready
            default: break
            }
        }
        let loaded = state
        self.state = state
        lastDataVersion = Store.shared.dataVersion()
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
            state.selectedWorkspaceID = newValue
            if let newValue { updateWorkspace(newValue) { $0.hasUnread = false } }
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
        state.repositories = fresh.repositories
        state.workspaces = fresh.workspaces
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
        if selectedRepoID == repo.id { selectedRepoID = nil }
        scheduleSave()
    }

    // MARK: workspaces

    /// New workspace = fresh worktree branched from a just-fetched origin/<default>. Never from the local checkout.
    func createWorkspace(in repo: Repository, provider: ProviderKind? = nil) async {
        let used = Set(state.workspaces.filter { $0.repoID == repo.id }.map(\.name))
        let name = WorkspaceNames.next(excluding: used)
        let prefix = settings.branchPrefix.trimmingCharacters(in: .whitespaces)
        let branch = prefix.isEmpty ? name : "\(prefix)/\(name)"
        let path = Paths.workspacesRoot.appendingPathComponent(repo.name).appendingPathComponent(name).path
        let usedPorts = Set(state.workspaces.filter { !$0.isArchived }.map(\.portBase))
        let portBase = PortAllocator.allocate(used: usedPorts)
        let provider = provider ?? settings.defaultProvider
        var tab = ChatTab(
            provider: provider, model: defaultModel(for: provider), permissionMode: settings.defaultPermissionMode)
        tab.effort = defaultEffort(for: provider)
        let ws = Workspace(
            repoID: repo.id, name: name, branch: branch, path: path, baseBranch: repo.defaultBranch,
            portBase: portBase, state: .creating, tabs: [tab], selectedTabID: tab.id)
        state.workspaces.append(ws)
        selectedWorkspaceID = ws.id
        scheduleSave()

        Trace.log("ws created, selected")
        do {
            try await Git.fetch(repoPath: repo.path, branch: repo.defaultBranch)
            Trace.log("fetched")
            let base = try await Git.createWorktree(
                repoPath: repo.path, path: path, branch: branch, base: "origin/\(repo.defaultBranch)")
            Trace.log("worktree added")
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
            updateWorkspace(ws.id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func archive(_ ws: Workspace) async {
        guard let repo = repo(ws.repoID) else { return }
        if let m = existingModel(for: ws.id) {
            await m.prepareForArchive()
        }
        do {
            if FileManager.default.fileExists(atPath: ws.path) {
                try await Git.removeWorktree(repoPath: repo.path, path: ws.path, force: true)
            }
        } catch {
            alert = AppAlert(title: "Couldn't remove worktree", message: error.localizedDescription)
        }
        workspaceModels[ws.id] = nil
        updateWorkspace(ws.id) { $0.state = .archived }
        if selectedWorkspaceID == ws.id {
            selectedWorkspaceID = activeWorkspaces(in: repo).first?.id
        }
    }

    func deleteArchived(_ ws: Workspace) async {
        guard ws.isArchived else { return }
        for tab in ws.tabs { await Store.shared.deleteTranscript(tabID: tab.id) }
        if let repo = repo(ws.repoID) { try? await Git.deleteBranch(repoPath: repo.path, branch: ws.branch) }
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
        if let models = await ClaudeSession.probeModels() { updateModels(models, for: .claude) }
    }

    private func loadCodexModels() async {
        if let models = try? await CodexAppServer.shared.listModels() { updateModels(models, for: .codex) }
    }

    // MARK: lifecycle

    func shutdown() {
        for m in workspaceModels.values { m.shutdownNow() }
        let state = self.state
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await Store.shared.save(state)
            await CodexAppServer.shared.shutdown()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }
}

enum SettingsRoute: Hashable {
    case general
    case agents
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
