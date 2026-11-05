import DQCore
import Foundation
import GitHubKit
import GitKit
import Observation
import ProcessKit

// MARK: right panel (fork R)

/// Local git state the right panel needs beyond the diff: uncommitted files and unpushed commits.
/// Kept per workspace in a registry so it survives panel re-renders without touching WorkspaceModel's storage.
@MainActor
@Observable
final class PanelGitState {
    private static var registry: [UUID: PanelGitState] = [:]

    static func of(_ model: WorkspaceModel) -> PanelGitState {
        if let s = registry[model.id] { return s }
        let s = PanelGitState()
        registry[model.id] = s
        return s
    }

    /// Files with uncommitted (staged, unstaged or untracked) changes.
    private(set) var uncommitted = 0
    /// Commits on HEAD not on its upstream; nil when the branch has never been pushed.
    private(set) var unpushed: Int?
    private(set) var hasUpstream = false
    /// Current HEAD commit, to tell whether anything was committed since branching.
    private(set) var head: String?
    @ObservationIgnored private var refreshing = false

    func refresh(path: String, host: any ExecutionHost = LocalHost.shared) {
        guard !refreshing, !host.isLocal || FileManager.default.fileExists(atPath: path) else { return }
        refreshing = true
        Task {
            defer { self.refreshing = false }
            let status = (try? await Git.status(path: path, host: host)) ?? []
            self.uncommitted = status.count
            let r = try? await host.run("git", ["rev-list", "--count", "@{upstream}..HEAD"], cwd: path, check: false)
            if let r, r.succeeded, let n = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
                self.unpushed = n
                self.hasUpstream = true
            } else {
                self.unpushed = nil
                self.hasUpstream = false
            }
            let h = try? await host.run("git", ["rev-parse", "HEAD"], cwd: path, check: false)
            self.head = h.flatMap { $0.succeeded ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        }
    }
}

/// What the panel header's primary button should do right now.
enum PrimaryShipAction: Equatable {
    case createPR
    case commitAndPush
    case merge
    /// Checks still running: merge once they pass.
    case mergeWhenReady
    /// Already queued to merge when green.
    case waitingToMerge
    case fixCI
    case updateBranch
    case resolveConflicts
    case needsReview
    case pushToTrunk
    /// Work has landed (PR merged/closed, or pushed to trunk): offer to archive the workspace.
    case archive
    case none
}

extension WorkspaceModel {
    var gitState: PanelGitState { PanelGitState.of(self) }

    func refreshGitState() {
        guard remoteReady, let path = workspace?.path else { return }
        gitState.refresh(path: path, host: host)
    }

    /// Refresh everything the right panel shows.
    func refreshPanel() {
        refreshDiff()
        refreshGitState()
        if panelTab == .files || files.isEmpty { refreshFiles() }
        if shipMode == .pullRequest { refreshPR() }
    }

    var hasLocalChanges: Bool { gitState.uncommitted > 0 || (gitState.unpushed ?? 0) > 0 }

    /// The work has been pushed to the base branch (recorded, or detected for a clean tree).
    var isPushedToTrunk: Bool { workspace?.isPushedToTrunk == true || (shipMode == .trunk && isShippedToTrunk) }

    /// Uncommitted changes or commits not yet on origin/<base>, i.e. something to push again.
    var hasWorkSinceTrunkPush: Bool { gitState.uncommitted > 0 || (aheadBehind?.ahead ?? 0) > 0 }

    var primaryShipAction: PrimaryShipAction {
        // Pushed to trunk behaves like a merged PR: archive, unless there's new work to push.
        if prStatus == nil, isPushedToTrunk, !hasWorkSinceTrunkPush { return .archive }
        if shipMode == .trunk { return .pushToTrunk }
        guard slug != nil else { return .none }
        guard let pr = prStatus?.pr else { return .createPR }
        switch pr.state {
        case .open: return hasLocalChanges ? .commitAndPush : mergeAction
        case .merged, .closed: return hasLocalChanges ? .createPR : .archive
        }
    }

    /// Trunk mode: nothing uncommitted, nothing ahead of origin/<base>, and HEAD has moved since we branched
    /// (so there was work, and it's now on the base branch).
    var isShippedToTrunk: Bool {
        guard gitState.uncommitted == 0, let ab = aheadBehind, ab.ahead == 0,
            let head = gitState.head, let baseCommit = workspace?.baseCommit, !baseCommit.isEmpty
        else { return false }
        return !head.hasPrefix(baseCommit) && !baseCommit.hasPrefix(head)
    }

    /// Short status for the panel header.
    var panelStatusText: String {
        if let pr = prStatus?.pr {
            switch pr.state {
            case .merged: return "Merged"
            case .closed: return "Closed"
            case .open:
                if gitState.uncommitted > 0 { return "Uncommitted changes" }
                if let n = gitState.unpushed, n > 0 { return "\(n) unpushed commit\(n == 1 ? "" : "s")" }
                switch prStatus?.overall {
                case .passing: return "Checks passing"
                case .failing: return "Checks failing"
                case .pending: return "Checks running"
                default: return pr.isDraft ? "Draft" : "Open"
                }
            }
        }
        if isPushedToTrunk {
            if gitState.uncommitted > 0 { return "Pushed to \(base) · uncommitted changes" }
            if let n = aheadBehind?.ahead, n > 0 { return "Pushed to \(base) · \(n) new commit\(n == 1 ? "" : "s")" }
            return "Pushed to \(base)"
        }
        if gitState.uncommitted > 0 { return "Uncommitted changes" }
        if let ab = aheadBehind, ab.ahead > 0 {
            return "\(ab.ahead) commit\(ab.ahead == 1 ? "" : "s") ahead of \(workspace?.baseBranch ?? "main")"
        }
        return workspace?.branch ?? ""
    }

    /// Sensible default commit message: the active chat's title.
    var defaultCommitMessage: String {
        let title = selectedChat?.tab?.title ?? ""
        return title.isEmpty || title == "New chat" ? "Update \(workspace?.name ?? "workspace")" : title
    }

    func askAgentToRebase() {
        let base = workspace?.baseBranch ?? "main"
        sendToAgent(
            "This branch is behind origin/\(base). Please run `git fetch origin && git rebase origin/\(base)`, resolve any conflicts preserving both sides' intent, and re-run the relevant tests. Don't push."
        )
    }

    /// Most recently started task run (for "Send to agent").
    var latestRun: TaskRun? {
        guard let supervisor else { return nil }
        let all = supervisor.runs + supervisor.adhocRuns + [supervisor.setupRun].compactMap { $0 }
        return all.filter { $0.startedAt != nil }.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }
}
