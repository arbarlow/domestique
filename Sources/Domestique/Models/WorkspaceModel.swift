import AgentKit
import AppKit
import DQCore
import Foundation
import GitHubKit
import GitKit
import HostKit
import Observation
import ProcessKit

/// Top half of the right panel.
enum PanelTab: String, CaseIterable, Identifiable {
    case files, changes, checks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .files: "All files"
        case .changes: "Changes"
        case .checks: "Checks"
        }
    }
}

/// Bottom dock of the right panel.
enum DockTab: Hashable {
    case setup
    case run
    case terminal(UUID)
}

/// A file opened in the right panel (from the file tree, the changes list, or a chat "View changes").
struct OpenedFile: Hashable {
    var path: String
    /// true = diff vs base, false = full file contents.
    var showDiff: Bool
}

@MainActor
@Observable
final class WorkspaceModel {
    let id: UUID
    @ObservationIgnored unowned let app: AppModel

    private var chats: [UUID: ChatModel] = [:]

    // Config / tasks
    private(set) var config: RepoConfig?
    private(set) var configError: String?
    private(set) var supervisor: TaskSupervisor?
    var selectedRunID: String?

    // Changes
    private(set) var diffFiles: [FileDiff] = []
    private(set) var diffError: String?
    private(set) var isLoadingDiff = false
    private(set) var aheadBehind: AheadBehind?
    var selectedDiffPath: String?

    // Files
    private(set) var files: [String] = []
    private(set) var fileTree: [FileNode] = []
    var selectedFilePath: String?

    // Ship
    private(set) var prStatus: PullRequestStatus?
    private(set) var prError: String?
    var shipBusy: String?
    var shipMessage: String?
    private(set) var conflictFiles: [String] = []
    /// A ship instruction the agent is carrying out (see WorkspaceModel+Ship).
    var agentShip: AgentShipKind?
    /// "Merge when ready" handled by the app (repo doesn't allow GitHub auto-merge).
    var mergeWhenReady: MergeMethod?
    @ObservationIgnored private var prPollTask: Task<Void, Never>?

    // Terminals
    private(set) var terminals: [TerminalSession] = []
    var selectedTerminalID: UUID?

    // Cloud: remote port -> local port forwarded to this Mac.
    private(set) var forwards: [Int: Int] = [:]
    private(set) var forwardErrors: [Int: String] = [:]
    /// Ports the user turned off forwarding for (auto mode skips them).
    var forwardingDisabled: Set<Int> = []
    @ObservationIgnored private var forwardTask: Task<Void, Never>?
    @ObservationIgnored private var lastSeen: [Int: Date] = [:]
    private var remoteConfigExists = false
    @ObservationIgnored private var stackStartPending = false

    // Right panel
    var panelTab: PanelTab = .changes
    var openedFile: OpenedFile?
    var dockTab: DockTab = .run
    var dockExpanded = true

    init(id: UUID, app: AppModel) {
        self.id = id
        self.app = app
        loadConfig()
    }

    var workspace: Workspace? { app.workspace(id) }
    /// Where this workspace's code and processes live.
    var host: any ExecutionHost { Hosts.host(for: workspace?.host) }
    var isRemote: Bool { workspace?.host != nil }
    /// A boat.dev sandbox: machine status, auto-stop and SSH port forwarding apply.
    var isSandbox: Bool { workspace?.isSandbox ?? false }
    /// Where ports opened in this workspace are reached from this Mac: "localhost" (local, and
    /// sandboxes via forwards), else the remote Team Car's host name (your network reaches it).
    var portHost: String {
        guard let id = workspace?.teamCarID else { return "localhost" }
        return app.settings.teamCars.first { $0.id == id }?.hostName ?? "localhost"
    }
    var repo: Repository? { workspace.flatMap { app.repo($0.repoID) } }
    var shipMode: ShipMode { workspace?.shipModeOverride ?? repo?.shipMode ?? .pullRequest }

    var environment: [String: String] {
        guard let ws = workspace, let repo else { return [:] }
        return WorkspaceEnvironment.variables(workspace: ws, repo: repo)
    }

    // MARK: chats

    func chat(for tabID: UUID) -> ChatModel {
        if let c = chats[tabID] { return c }
        let c = ChatModel(tabID: tabID, workspace: self)
        chats[tabID] = c
        return c
    }

    var selectedChat: ChatModel? {
        guard let ws = workspace, let tid = ws.selectedTabID ?? ws.tabs.first?.id else { return nil }
        return chat(for: tid)
    }

    var isAgentRunning: Bool {
        if chats.values.contains(where: { $0.isRunning || !$0.runningTasks.isEmpty }) { return true }
        // Riders running in Team Car without an open chat here (e.g. started from another client).
        guard let link = app.link(for: workspace) else { return false }
        return workspace?.tabs.contains { chats[$0.id] == nil && link.isRiderRunning($0.id) } ?? false
    }
    var needsAttention: Bool {
        if let link = app.link(for: workspace),
            workspace?.tabs.contains(where: { chats[$0.id] == nil && link.isRiderAwaiting($0.id) }) == true
        {
            return true
        }
        return chats.values.contains { chat in
            chat.items.reversed().prefix(5).contains {
                if case .approval(let r) = $0.kind { return r.resolution == .pending }
                return false
            }
        }
    }

    /// Another app instance wrote to the shared database: pick up new chat items.
    func syncChatsFromStore() {
        for chat in chats.values { chat.syncFromStore() }
    }

    func hasChat(_ tabID: UUID) -> Bool { chats[tabID] != nil }

    /// The tab's rider was closed elsewhere.
    func dropTab(_ tabID: UUID) {
        chats[tabID]?.shutdown()
        chats[tabID] = nil
        app.updateWorkspaceIfChanged(id) { w in
            let idx = w.tabs.firstIndex { $0.id == tabID } ?? 0
            w.tabs.removeAll { $0.id == tabID }
            if w.selectedTabID == tabID { w.selectedTabID = w.tabs.isEmpty ? nil : w.tabs[max(0, min(idx, w.tabs.count - 1))].id }
        }
    }

    func isRunning(tabID: UUID) -> Bool {
        guard let c = chats[tabID] else { return app.link(for: workspace)?.isRiderRunning(tabID) ?? false }
        return c.isRunning || !c.runningTasks.isEmpty
    }

    func newTab(provider: ProviderKind? = nil) {
        let provider = provider ?? selectedChat?.tab?.provider ?? app.settings.defaultProvider
        var tab = ChatTab(
            provider: provider, model: app.defaultModel(for: provider),
            permissionMode: app.settings.defaultPermissionMode)
        tab.effort = app.defaultEffort(for: provider)
        app.updateWorkspace(id) {
            $0.tabs.append(tab)
            $0.selectedTabID = tab.id
        }
        app.link(for: workspace)?.openRider(tab, workspace: id)
        app.composerFocusRequest += 1
    }

    func selectTab(_ tabID: UUID) {
        app.updateWorkspace(id) { $0.selectedTabID = tabID }
        app.composerFocusRequest += 1
    }

    /// Cycle to the previous (-1) or next (+1) chat tab, wrapping around.
    func selectAdjacentTab(_ offset: Int) {
        guard let ws = workspace, ws.tabs.count > 1 else { return }
        let current = ws.tabs.firstIndex { $0.id == (ws.selectedTabID ?? ws.tabs.first?.id) } ?? 0
        let next = ((current + offset) % ws.tabs.count + ws.tabs.count) % ws.tabs.count
        selectTab(ws.tabs[next].id)
    }

    func closeTab(_ tabID: UUID) {
        guard let ws = workspace, ws.tabs.count > 1 else { return }
        chats[tabID]?.shutdown()
        chats[tabID] = nil
        let link = app.link(for: ws)
        var forgotten: [UUID] = []
        app.updateWorkspace(id) { w in
            let idx = w.tabs.firstIndex { $0.id == tabID } ?? 0
            // Local chats keep their transcript so the tab can be reopened. Team Car deletes a closed
            // rider's history on the server, so there's nothing to bring back there.
            if link == nil, let tab = w.tabs.first(where: { $0.id == tabID }) {
                var closed = w.closedTabs ?? []
                closed.removeAll { $0.id == tabID }
                closed.insert(ClosedChatTab(tab: tab), at: 0)
                forgotten = closed.dropFirst(ClosedChatTab.limit).map(\.id)
                w.closedTabs = Array(closed.prefix(ClosedChatTab.limit))
            }
            w.tabs.removeAll { $0.id == tabID }
            if w.selectedTabID == tabID { w.selectedTabID = w.tabs[max(0, min(idx, w.tabs.count - 1))].id }
        }
        if let link {
            Task { await link.closeRider(tabID) }
        } else {
            Task { for id in forgotten { await Store.shared.deleteTranscript(tabID: id) } }
        }
    }

    /// Recently closed chat tabs, most recent first.
    var closedTabs: [ClosedChatTab] { workspace?.closedTabs ?? [] }

    /// Bring a closed chat tab back, with its transcript and agent session.
    func reopenTab(_ tabID: UUID) {
        guard let closed = closedTabs.first(where: { $0.id == tabID }) else { return }
        app.updateWorkspace(id) { w in
            w.closedTabs?.removeAll { $0.id == tabID }
            if !w.tabs.contains(where: { $0.id == tabID }) { w.tabs.append(closed.tab) }
            w.selectedTabID = tabID
        }
        app.composerFocusRequest += 1
    }

    /// ⌘⇧T: reopen the most recently closed chat tab.
    func reopenLastClosedTab() {
        if let last = closedTabs.first { reopenTab(last.id) }
    }

    func agentFinishedTurn(_ chat: ChatModel) {
        reloadConfigIfChanged()  // the agent may have edited domestique.toml
        if app.selectedWorkspaceID != id { app.updateWorkspace(id) { $0.hasUnread = true } }
        refreshDiff()
        if prStatus != nil { refreshPR() }
        finishAgentShip()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func agentNeedsAttention(_ chat: ChatModel) {
        if app.selectedWorkspaceID != id { app.updateWorkspace(id) { $0.hasUnread = true } }
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
    }

    /// Paste text into the selected chat (used by "send logs", "fix CI", conflicts).
    func sendToAgent(_ text: String) {
        guard let chat = selectedChat else { return }
        chat.send(text: text)
    }

    // MARK: config & tasks

    func loadConfig() {
        if isRemote {
            Task { await loadConfigAsync() }
            return
        }
        guard let ws = workspace, FileManager.default.fileExists(atPath: ws.path) else { return }
        do {
            let cfg = try RepoConfig.load(directory: ws.path)
                ?? repo.flatMap { try? RepoConfig.load(directory: $0.path) }
                ?? RepoConfig()
            applyConfig(cfg)
        } catch {
            configError = error.localizedDescription
        }
    }

    /// Re-read domestique.toml (the workspace's, else the main checkout's) and apply it if it changed.
    /// Called when the workspace is focused, the app comes to the front, before ⌘R and after agent
    /// turns, so edits made anywhere show up without reopening anything. Cheap: one small file read.
    func reloadConfigIfChanged() {
        guard let ws = workspace, !ws.isArchived else { return }
        switch ws.state {
        case .ready, .settingUp: break
        default: return
        }
        if isRemote {
            guard remoteReady else { return }
            Task { await loadConfigAsync() }
        } else {
            loadConfig()
        }
    }

    /// Install a parsed config. No-op when nothing changed, so it's safe to call often.
    /// Running tasks keep running; edits to them take effect on their next start.
    private func applyConfig(_ cfg: RepoConfig) {
        let previous = config
        configError = nil
        guard cfg != previous || supervisor == nil else { return }
        config = cfg
        if let supervisor {
            supervisor.update(config: cfg)
        } else {
            Task { await self.makeSupervisor(config: cfg) }
        }
        if previous != nil, app.selectedWorkspaceID == id {
            app.toast = "Reloaded \(RepoConfig.fileName)"
        }
    }

    /// Reads domestique.toml from wherever the workspace lives (the machine's clone first, then the
    /// main checkout on this Mac).
    func loadConfigAsync() async {
        guard let ws = workspace else { return }
        if !isRemote {
            loadConfig()
            return
        }
        let host = self.host
        do {
            var cfg: RepoConfig?
            if let data = try await host.readFile(ws.path + "/" + RepoConfig.fileName, maxBytes: 1_000_000) {
                remoteConfigExists = true
                cfg = try RepoConfig.parse(toml: String(decoding: data, as: UTF8.self))
            } else {
                remoteConfigExists = false
                cfg = repo.flatMap { try? RepoConfig.load(directory: $0.path) }
            }
            applyConfig(cfg ?? RepoConfig())
        } catch {
            configError = error.localizedDescription
        }
    }

    private func makeSupervisor(config: RepoConfig) async {
        guard supervisor == nil, let ws = workspace else { return }
        let host = self.host
        // Remote tasks get only the workspace variables; the machine has its own PATH/HOME.
        let login = host.isLocal ? await LoginEnvironment.shared.environment() : [:]
        // Re-check after the await: loadConfig and runSetup can race to create one.
        guard supervisor == nil else { return }
        let env = login.merging(environment) { $1 }
        let sup = TaskSupervisor(workspacePath: ws.path, config: config, environment: env, host: host)
        sup.isFocused = app.selectedWorkspaceID == id
        supervisor = sup
        if isSandbox { startForwarding() }
    }

    var hasConfigFile: Bool {
        guard let ws = workspace else { return false }
        if isRemote {
            return remoteConfigExists || repo.map { FileManager.default.fileExists(atPath: $0.path + "/" + RepoConfig.fileName) } ?? false
        }
        return FileManager.default.fileExists(atPath: ws.path + "/" + RepoConfig.fileName)
            || repo.map { FileManager.default.fileExists(atPath: $0.path + "/" + RepoConfig.fileName) } ?? false
    }

    func createConfigFile() {
        guard let ws = workspace else { return }
        // Cloud workspaces: the config lives in the main checkout on this Mac (the fallback they read).
        var path = (isRemote ? (repo?.path ?? ws.path) : ws.path) + "/" + RepoConfig.fileName
        // Prefer an existing local-only config in the main checkout.
        if !FileManager.default.fileExists(atPath: path), let repo,
            FileManager.default.fileExists(atPath: repo.path + "/" + RepoConfig.fileName)
        {
            path = repo.path + "/" + RepoConfig.fileName
        }
        if !FileManager.default.fileExists(atPath: path) {
            try? RepoConfig.template.write(toFile: path, atomically: true, encoding: .utf8)
        }
        loadConfig()
        openLocally(path: path)
    }

    func runSetup() async {
        if supervisor == nil, let config { await makeSupervisor(config: config) }
        guard let supervisor, let repo, let config else { return }
        guard config.setupScript != nil || !config.copyFiles.isEmpty else { return }
        dockTab = .setup
        dockExpanded = true
        await supervisor.runSetup(script: config.setupScript, copyFiles: config.copyFiles, from: repo.path)
    }

    func startDefaultStack() {
        // Pick up a just-edited domestique.toml before starting (local reads are synchronous).
        if !isRemote { reloadConfigIfChanged() }
        guard let supervisor, let config else {
            // Cloud workspaces read their config over SSH; run once it has arrived.
            if isRemote, !stackStartPending {
                stackStartPending = true
                Task {
                    await loadConfigAsync()
                    stackStartPending = false
                    if self.supervisor != nil, self.config != nil { self.startDefaultStack() }
                }
            }
            return
        }
        if let stack = config.stacks.first {
            if supervisor.isStackRunning(stack.id) {
                supervisor.stopStack(stack.id)
            } else {
                supervisor.startStack(stack.id)
            }
        } else if let first = config.tasks.first(where: { $0.kind == .service }) {
            if supervisor.task(first.id)?.state.isActive == true {
                supervisor.stop(first.id)
            } else {
                supervisor.run(first.id)
            }
        }
        dockTab = .run
        dockExpanded = true
    }

    var isDefaultStackRunning: Bool {
        guard let supervisor, let config else { return false }
        if let stack = config.stacks.first { return supervisor.isStackRunning(stack.id) }
        if let first = config.tasks.first(where: { $0.kind == .service }) {
            return supervisor.task(first.id)?.state.isActive == true
        }
        return false
    }

    struct OpenTarget: Identifiable, Hashable {
        var id: Int { port }
        var name: String
        var port: Int
        var url: URL
    }

    /// Everything listening in this workspace, best "Open" candidate first:
    /// a task with an `open` URL, then anything that looks like the web app, then the rest.
    var openTargets: [OpenTarget] {
        guard let supervisor else { return [] }
        var targets: [(score: Int, target: OpenTarget)] = []
        var seen = Set<Int>()
        for run in supervisor.runs + supervisor.adhocRuns where run.state.isActive {
            let lower = (run.id + " " + run.name).lowercased()
            let webby = ["web", "frontend", "front", "app", "site", "ui", "vite", "next"].contains { lower.contains($0) }
            // Its `open` URL once the task is actually listening.
            if let url = run.openURL, !run.ports.isEmpty, let port = url.port ?? run.ports.first,
                seen.insert(port).inserted
            {
                if let local = localURL(url, remotePort: port) {
                    targets.append((0, OpenTarget(name: run.name, port: localPort(for: port) ?? port, url: local)))
                }
            }
            for port in run.ports where seen.insert(port).inserted {
                guard let lp = localPort(for: port) else { continue }
                let url = URL(string: "http://\(portHost):\(lp)")!
                targets.append((webby ? 1 : 2, OpenTarget(name: run.name, port: lp, url: url)))
            }
        }
        // Cloud: servers the agent started outside a task, once forwarded.
        if isSandbox {
            for port in supervisor.remoteAppPorts where seen.insert(port).inserted {
                guard let lp = forwards[port] else { continue }
                targets.append((3, OpenTarget(name: "Port \(port)", port: lp, url: URL(string: "http://localhost:\(lp)")!)))
            }
        }
        return targets.sorted { ($0.score, $0.target.port) < ($1.score, $1.target.port) }.map(\.target)
    }

    var primaryOpenTarget: OpenTarget? { openTargets.first }

    /// The port on this Mac that reaches `remotePort` (itself for local workspaces; nil until forwarded).
    func localPort(for remotePort: Int) -> Int? { isSandbox ? forwards[remotePort] : remotePort }

    private func localURL(_ url: URL, remotePort: Int) -> URL? {
        if workspace?.teamCarID != nil {
            // A remote Team Car: same port, on the car's host.
            guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            if c.host == nil || ["localhost", "127.0.0.1", "0.0.0.0"].contains(c.host!) { c.host = portHost }
            return c.url
        }
        guard isSandbox else { return url }
        guard let lp = forwards[remotePort], var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if c.host == nil || ["localhost", "127.0.0.1", "0.0.0.0"].contains(c.host!) { c.host = "localhost" }
        c.port = lp
        return c.url
    }

    // MARK: cloud: port forwarding

    /// Keeps forwards in step with what listens on the machine: every port a task (or the agent)
    /// opens is forwarded to the same port on this Mac, or the next free one.
    private func startForwarding() {
        forwardTask?.cancel()
        forwardTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncForwards()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Ports worth forwarding: anything our runs own, plus anything new since the machine booted.
    var forwardablePorts: [Int] {
        guard let supervisor, isSandbox else { return [] }
        let owned = (supervisor.runs + supervisor.adhocRuns + [supervisor.setupRun].compactMap { $0 }).flatMap(\.ports)
        return Array(Set(owned + supervisor.remoteAppPorts)).sorted()
    }

    private func syncForwards() async {
        guard isSandbox, let h = workspace?.host, let supervisor else { return }
        let phase = app.cloud.status[h.machineID]?.phase
        let ssh = app.cloud.host(h.machineID).ssh
        guard phase == .running || phase == nil else {
            if !forwards.isEmpty {
                await ssh.cancelAllForwards()
                forwards = [:]
            }
            return
        }
        let now = Date()
        let auto = app.settings.provider(for: h)?.boat.autoForwardPorts ?? true
        let listening = Set(supervisor.remoteListening)
        let wanted = Set(forwardablePorts).subtracting(forwardingDisabled).filter { auto || manualForwards.contains($0) }
        for p in wanted { lastSeen[p] = now }
        // Add new ones.
        for remote in wanted.sorted() where forwards[remote] == nil {
            let local = Self.pickLocalPort(preferred: remote, taken: Set(forwards.values))
            do {
                try await ssh.forward(local: local, remote: remote)
                forwards[remote] = local
                forwardErrors[remote] = nil
            } catch {
                forwardErrors[remote] = error.localizedDescription
            }
        }
        // Drop ones that stopped listening for a while (a restarting dev server keeps its forward).
        for (remote, local) in forwards where !listening.contains(remote) || forwardingDisabled.contains(remote) {
            let gone = forwardingDisabled.contains(remote) || now.timeIntervalSince(lastSeen[remote] ?? .distantPast) > 15
            if gone {
                await ssh.cancelForward(local: local)
                forwards[remote] = nil
            }
        }
    }

    /// Ports forwarded by hand when auto-forwarding is off.
    var manualForwards: Set<Int> = []

    func setForwarding(_ port: Int, enabled: Bool) {
        if enabled {
            forwardingDisabled.remove(port)
            manualForwards.insert(port)
        } else {
            forwardingDisabled.insert(port)
            manualForwards.remove(port)
        }
        Task { await syncForwards() }
    }

    /// Same port when it's free on this Mac, else the first free one above 20000.
    static func pickLocalPort(preferred: Int, taken: Set<Int>) -> Int {
        if !taken.contains(preferred), SSHConnection.isLocalPortFree(preferred) { return preferred }
        var p = 20000 + (preferred % 10000)
        while taken.contains(p) || !SSHConnection.isLocalPortFree(p) { p += 1 }
        return p
    }

    /// The machine is about to stop (user action): stop runs/agents/terminals so nothing resumes it.
    func machineWillStop() {
        for c in chats.values { c.shutdown() }
        supervisor?.shutdownNow()
        for t in terminals { t.terminate() }
        forwards = [:]
    }

    /// The machine came back (a resume): it has a new address, so reconnect what depends on it.
    func machineDidStart() async {
        if config == nil { await loadConfigAsync() }
        supervisor?.probeNow()
    }

    var canRunStack: Bool { !(config?.stacks.isEmpty ?? true) || (config?.tasks.contains { $0.kind == .service } ?? false) }

    func sendLogsToAgent(_ run: TaskRun) {
        let tail = run.tail(150)
        sendToAgent(
            "Here are the last lines of the `\(run.name)` task log (`\(run.command)`), state: \(run.state.label). Please take a look.\n\n```\n\(tail)\n```"
        )
    }

    // MARK: changes / files

    func refreshDiff() {
        guard let ws = workspace, !isLoadingDiff else { return }
        guard isRemote ? remoteReady : FileManager.default.fileExists(atPath: ws.path) else { return }
        isLoadingDiff = true
        let path = ws.path
        let base = "origin/\(ws.baseBranch)"
        let host = self.host
        Task {
            defer { self.isLoadingDiff = false }
            do {
                let files = try await Git.diff(path: path, base: base, host: host)
                self.diffFiles = files
                self.diffError = nil
                if let sel = self.selectedDiffPath, !files.contains(where: { $0.path == sel }) {
                    self.selectedDiffPath = nil
                }
                self.aheadBehind = try? await Git.aheadBehind(path: path, base: base, host: host)
            } catch {
                self.diffError = error.localizedDescription
            }
        }
    }

    var diffStat: DiffStat { Git.diffStat(diffFiles) }

    /// Cloud workspaces: only touch the machine once it's set up and running (never resume it just
    /// to refresh a diff).
    var remoteReady: Bool {
        guard let ws = workspace, let h = ws.host else { return true }
        guard case .ready = ws.state else { return false }
        if h.provider == .teamcar { return app.link(for: ws)?.isConnected ?? false }
        return app.cloud.status[h.machineID]?.phase == .running
    }

    @ObservationIgnored private var diffRefreshTask: Task<Void, Never>?

    /// Debounced refresh for bursts of tool calls.
    func scheduleDiffRefresh() {
        diffRefreshTask?.cancel()
        diffRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.refreshDiff()
        }
    }

    func refreshFiles() {
        guard let ws = workspace, remoteReady else { return }
        let path = ws.path
        let host = self.host
        Task {
            guard let list = try? await Git.listFiles(path: path, host: host) else { return }
            let tree = await Task.detached { FileNode.tree(from: list) }.value
            self.files = list
            self.fileTree = tree
        }
    }

    func openInEditor(path: String? = nil) {
        guard let ws = workspace else { return }
        if isRemote {
            // The code lives on the machine: open a shell there instead.
            newTerminal()
            app.toast = "This workspace lives on boat.dev. Opened a terminal on the sandbox."
            return
        }
        let target = path ?? ws.path
        let editor = app.settings.editorCommand
        Task {
            do {
                try await Shell.run(editor, [target], cwd: ws.path)
            } catch {
                NSWorkspace.shared.open(URL(fileURLWithPath: target))
            }
        }
    }

    /// Open a file on this Mac with the editor command.
    func openLocally(path: String) {
        let editor = app.settings.editorCommand
        Task {
            do {
                try await Shell.run(editor, [path], cwd: (path as NSString).deletingLastPathComponent)
            } catch {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    func revealInFinder() {
        guard let ws = workspace, !isRemote else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ws.path)])
    }

    // MARK: ship — pull requests

    var slug: String? { repo?.githubSlug }

    func refreshPR() {
        guard let ws = workspace, let slug else { return }
        Task {
            do {
                var number = ws.prNumber
                if number == nil, let found = try await GitHubClient.shared.findOpenPullRequest(slug: slug, branch: ws.branch) {
                    number = found.number
                    app.updateWorkspace(id) {
                        $0.prNumber = found.number
                        $0.prURL = found.url
                    }
                }
                guard let number else {
                    self.prStatus = nil
                    return
                }
                let previous = self.prStatus
                let status = try await GitHubClient.shared.status(slug: slug, number: number)
                self.prStatus = status
                self.prError = nil
                self.prStatusChanged(from: previous, to: status)
                self.ensurePolling()
            } catch {
                self.prError = error.localizedDescription
            }
        }
    }

    private func ensurePolling() {
        guard prPollTask == nil else { return }
        prPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Checks running: poll fast. Settled: slower. Not on screen: slower still.
                let selected = self.app.selectedWorkspaceID == self.id
                let pending = self.prStatus?.overall == .pending || self.mergeWhenReady != nil
                let interval: Double = pending ? (selected ? 8 : 20) : (selected ? 20 : 60)
                try? await Task.sleep(for: .seconds(interval))
                guard let status = self.prStatus, status.pr.state == .open else {
                    self.prPollTask = nil
                    return
                }
                self.refreshPR()
            }
        }
    }

    /// Commit everything (if needed), push the branch, open the PR.
    func createPullRequest(title: String, body: String, commitMessage: String, draft: Bool) async {
        guard let ws = workspace, let repo, let slug else {
            shipMessage = "This repository has no GitHub remote."
            return
        }
        shipBusy = "Committing…"
        defer { shipBusy = nil }
        do {
            try await Git.commitAll(path: ws.path, message: commitMessage.isEmpty ? title : commitMessage, host: host)
            shipBusy = "Pushing…"
            try await Git.push(path: ws.path, branch: ws.branch, setUpstream: true, host: host)
            shipBusy = "Opening pull request…"
            let pr = try await GitHubClient.shared.createPullRequest(
                slug: slug, head: ws.branch, base: repo.defaultBranch, title: title, body: body, draft: draft)
            app.updateWorkspace(id) {
                $0.prNumber = pr.number
                $0.prURL = pr.url
            }
            shipMessage = nil
            refreshPR()
            refreshDiff()
        } catch {
            shipMessage = error.localizedDescription
        }
    }

    /// Commit + push follow-up work to an existing PR.
    func pushUpdates(commitMessage: String) async {
        guard let ws = workspace else { return }
        shipBusy = "Pushing…"
        defer { shipBusy = nil }
        do {
            try await Git.commitAll(path: ws.path, message: commitMessage, host: host)
            try await Git.push(path: ws.path, branch: ws.branch, setUpstream: true, host: host)
            shipMessage = nil
            refreshPR()
            refreshDiff()
        } catch {
            shipMessage = error.localizedDescription
        }
    }

    func merge(method: MergeMethod) async {
        guard let slug, let status = prStatus else { return }
        shipBusy = "Merging…"
        defer { shipBusy = nil }
        do {
            try await GitHubClient.shared.merge(slug: slug, number: status.pr.number, method: method)
            shipMessage = nil
            refreshPR()
        } catch {
            shipMessage = Self.friendlyGitHubError(error, base: repo?.defaultBranch ?? "main")
            refreshPR()
        }
    }

    func setAutoMerge(_ enabled: Bool, method: MergeMethod) async {
        guard let status = prStatus else { return }
        shipBusy = enabled ? "Enabling auto-merge…" : "Disabling auto-merge…"
        defer { shipBusy = nil }
        do {
            if enabled {
                try await GitHubClient.shared.enableAutoMerge(prNodeID: status.pr.nodeID, method: method)
            } else {
                try await GitHubClient.shared.disableAutoMerge(prNodeID: status.pr.nodeID)
            }
            shipMessage = nil
            refreshPR()
        } catch {
            shipMessage = Self.friendlyGitHubError(error, base: repo?.defaultBranch ?? "main")
        }
    }

    func fixCI() async {
        guard let slug, let status = prStatus else { return }
        shipBusy = "Fetching failing logs…"
        defer { shipBusy = nil }
        do {
            let logs = try await GitHubClient.shared.failedCheckLogs(slug: slug, status: status)
            sendToAgent(
                "CI is failing on PR #\(status.pr.number). Here are the failing checks and log tails. Please find the root cause and fix it.\n\n\(logs)"
            )
        } catch {
            shipMessage = error.localizedDescription
        }
    }

    // MARK: ship — trunk

    func shipToTrunk(commitMessage: String) async {
        guard let ws = workspace, let repo else { return }
        conflictFiles = []
        shipBusy = "Committing…"
        defer { shipBusy = nil }
        do {
            try await Git.commitAll(path: ws.path, message: commitMessage, host: host)
            if let gate = config?.trunkGate, !gate.isEmpty, let supervisor {
                for taskID in gate {
                    guard let task = supervisor.task(taskID) else { continue }
                    shipBusy = "Running \(task.name)…"
                    dockTab = .run
                    dockExpanded = true
                    task.start()
                    let ok = await task.waitUntilFinished()
                    if !ok {
                        shipMessage = "\(task.name) failed — not pushing."
                        return
                    }
                }
            }
            shipBusy = "Rebasing onto origin/\(repo.defaultBranch) and pushing…"
            switch try await Git.trunkShip(path: ws.path, defaultBranch: repo.defaultBranch, host: host) {
            case .pushed(let sha):
                shipMessage = "Pushed \(sha.prefix(8)) to \(repo.defaultBranch)."
            case .nothingToShip:
                shipMessage = "Nothing to ship — already up to date with \(repo.defaultBranch)."
            case .conflict(let files):
                conflictFiles = files
                shipMessage = "Rebase hit conflicts in \(files.count) file(s)."
            }
            refreshDiff()
        } catch {
            shipMessage = error.localizedDescription
        }
    }

    func askAgentToResolveConflicts() {
        guard let repo else { return }
        sendToAgent(
            "Rebasing this branch onto origin/\(repo.defaultBranch) produced conflicts in:\n\(conflictFiles.map { "- \($0)" }.joined(separator: "\n"))\n\nPlease run `git fetch origin && git rebase origin/\(repo.defaultBranch)`, resolve the conflicts preserving both sides' intent, run the relevant tests, and finish the rebase (`git rebase --continue`). Don't push."
        )
        conflictFiles = []
    }

    // MARK: terminals

    func newTerminal() {
        guard let ws = workspace else { return }
        let n = terminals.count + 1
        let term = TerminalSession(
            title: isRemote ? "\(ws.host.map { $0.provider == .teamcar ? ($0.machineName ?? "Team Car") : $0.machineID } ?? "sandbox") \(n)" : "Terminal \(n)", cwd: ws.path, extraEnv: environment,
            host: host)
        terminals.append(term)
        selectedTerminalID = term.id
        dockTab = .terminal(term.id)
        dockExpanded = true
    }

    func closeTerminal(_ id: UUID) {
        terminals.first { $0.id == id }?.terminate()
        terminals.removeAll { $0.id == id }
        if selectedTerminalID == id { selectedTerminalID = terminals.last?.id }
        if dockTab == .terminal(id) { dockTab = terminals.last.map { .terminal($0.id) } ?? .run }
    }

    // MARK: right panel navigation

    /// Open the Changes tab, optionally focused on one file's diff.
    func showChanges(path: String? = nil) {
        panelTab = .changes
        openedFile = path.map { OpenedFile(path: $0, showDiff: true) }
        app.rightPanelVisible = true
    }

    func openFile(_ path: String, diff: Bool = false) {
        openedFile = OpenedFile(path: path, showDiff: diff)
        app.rightPanelVisible = true
    }

    /// Lines added/removed for a path in the current diff, if changed.
    func diffStat(for path: String) -> (Int, Int)? {
        diffFiles.first { $0.path == path }.map { ($0.additions, $0.deletions) }
    }

    // MARK: lifecycle

    func prepareForArchive() async {
        prPollTask?.cancel()
        forwardTask?.cancel()
        for c in chats.values { c.shutdown() }
        // Don't wake a stopped sandbox just to run the archive script.
        let canRunArchive = !isRemote || remoteReady
        if canRunArchive, let script = config?.archiveScript, let supervisor {
            let run = supervisor.runOneshot(name: "Archive", command: script)
            _ = await run.waitUntilFinished()
        }
        supervisor?.stopAll()
        supervisor?.stopProbing()
        for t in terminals { t.terminate() }
        terminals.removeAll()
    }

    func shutdownNow() {
        forwardTask?.cancel()
        for c in chats.values { c.shutdown() }
        supervisor?.shutdownNow()
        for t in terminals { t.terminate() }
    }
}
