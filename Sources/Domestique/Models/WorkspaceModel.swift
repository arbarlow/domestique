import AgentKit
import AppKit
import DQCore
import Foundation
import GitHubKit
import GitKit
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

    var isAgentRunning: Bool { chats.values.contains { $0.isRunning || !$0.runningTasks.isEmpty } }
    var needsAttention: Bool {
        chats.values.contains { chat in
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

    func isRunning(tabID: UUID) -> Bool {
        guard let c = chats[tabID] else { return false }
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
    }

    func selectTab(_ tabID: UUID) {
        app.updateWorkspace(id) { $0.selectedTabID = tabID }
    }

    func closeTab(_ tabID: UUID) {
        guard let ws = workspace, ws.tabs.count > 1 else { return }
        chats[tabID]?.shutdown()
        chats[tabID] = nil
        app.updateWorkspace(id) { w in
            let idx = w.tabs.firstIndex { $0.id == tabID } ?? 0
            w.tabs.removeAll { $0.id == tabID }
            if w.selectedTabID == tabID { w.selectedTabID = w.tabs[max(0, min(idx, w.tabs.count - 1))].id }
        }
        Task { await Store.shared.deleteTranscript(tabID: tabID) }
    }

    func agentFinishedTurn(_ chat: ChatModel) {
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
        guard let ws = workspace, FileManager.default.fileExists(atPath: ws.path) else { return }
        do {
            let cfg = try RepoConfig.load(directory: ws.path)
                ?? repo.flatMap { try? RepoConfig.load(directory: $0.path) }
                ?? RepoConfig()
            config = cfg
            configError = nil
            if let supervisor {
                supervisor.update(config: cfg)
            } else {
                Task { await self.makeSupervisor(config: cfg) }
            }
        } catch {
            configError = error.localizedDescription
        }
    }

    private func makeSupervisor(config: RepoConfig) async {
        guard supervisor == nil, let ws = workspace else { return }
        let login = await LoginEnvironment.shared.environment()
        // Re-check after the await: loadConfig and runSetup can race to create one.
        guard supervisor == nil else { return }
        let env = login.merging(environment) { $1 }
        supervisor = TaskSupervisor(workspacePath: ws.path, config: config, environment: env)
    }

    var hasConfigFile: Bool {
        guard let ws = workspace else { return false }
        return FileManager.default.fileExists(atPath: ws.path + "/" + RepoConfig.fileName)
            || repo.map { FileManager.default.fileExists(atPath: $0.path + "/" + RepoConfig.fileName) } ?? false
    }

    func createConfigFile() {
        guard let ws = workspace else { return }
        var path = ws.path + "/" + RepoConfig.fileName
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
        openInEditor(path: path)
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
        guard let supervisor, let config else { return }
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
                targets.append((0, OpenTarget(name: run.name, port: port, url: url)))
            }
            for port in run.ports where seen.insert(port).inserted {
                let url = URL(string: "http://localhost:\(port)")!
                targets.append((webby ? 1 : 2, OpenTarget(name: run.name, port: port, url: url)))
            }
        }
        return targets.sorted { ($0.score, $0.target.port) < ($1.score, $1.target.port) }.map(\.target)
    }

    var primaryOpenTarget: OpenTarget? { openTargets.first }

    var canRunStack: Bool { !(config?.stacks.isEmpty ?? true) || (config?.tasks.contains { $0.kind == .service } ?? false) }

    func sendLogsToAgent(_ run: TaskRun) {
        let tail = run.tail(150)
        sendToAgent(
            "Here are the last lines of the `\(run.name)` task log (`\(run.command)`), state: \(run.state.label). Please take a look.\n\n```\n\(tail)\n```"
        )
    }

    // MARK: changes / files

    func refreshDiff() {
        guard let ws = workspace, FileManager.default.fileExists(atPath: ws.path), !isLoadingDiff else { return }
        isLoadingDiff = true
        let path = ws.path
        let base = "origin/\(ws.baseBranch)"
        Task {
            defer { self.isLoadingDiff = false }
            do {
                let files = try await Git.diff(path: path, base: base)
                self.diffFiles = files
                self.diffError = nil
                if let sel = self.selectedDiffPath, !files.contains(where: { $0.path == sel }) {
                    self.selectedDiffPath = nil
                }
                self.aheadBehind = try? await Git.aheadBehind(path: path, base: base)
            } catch {
                self.diffError = error.localizedDescription
            }
        }
    }

    var diffStat: DiffStat { Git.diffStat(diffFiles) }

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
        guard let ws = workspace else { return }
        let path = ws.path
        Task {
            guard let list = try? await Git.listFiles(path: path) else { return }
            let tree = await Task.detached { FileNode.tree(from: list) }.value
            self.files = list
            self.fileTree = tree
        }
    }

    func openInEditor(path: String? = nil) {
        guard let ws = workspace else { return }
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

    func revealInFinder() {
        guard let ws = workspace else { return }
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
            try await Git.commitAll(path: ws.path, message: commitMessage.isEmpty ? title : commitMessage)
            shipBusy = "Pushing…"
            try await Git.push(path: ws.path, branch: ws.branch, setUpstream: true)
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
            try await Git.commitAll(path: ws.path, message: commitMessage)
            try await Git.push(path: ws.path, branch: ws.branch, setUpstream: true)
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
            try await Git.commitAll(path: ws.path, message: commitMessage)
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
            switch try await Git.trunkShip(path: ws.path, defaultBranch: repo.defaultBranch) {
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
        let term = TerminalSession(title: "Terminal \(n)", cwd: ws.path, extraEnv: environment)
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
        for c in chats.values { c.shutdown() }
        if let script = config?.archiveScript, let supervisor {
            let run = supervisor.runOneshot(name: "Archive", command: script)
            _ = await run.waitUntilFinished()
        }
        supervisor?.stopAll()
        for t in terminals { t.terminate() }
        terminals.removeAll()
    }

    func shutdownNow() {
        for c in chats.values { c.shutdown() }
        supervisor?.shutdownNow()
        for t in terminals { t.terminate() }
    }
}
