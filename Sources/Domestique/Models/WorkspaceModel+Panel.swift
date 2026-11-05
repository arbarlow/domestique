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
    @ObservationIgnored private var refreshing = false

    func refresh(path: String) {
        guard !refreshing, FileManager.default.fileExists(atPath: path) else { return }
        refreshing = true
        Task {
            defer { self.refreshing = false }
            let status = (try? await Git.status(path: path)) ?? []
            self.uncommitted = status.count
            let r = try? await Shell.run("git", ["rev-list", "--count", "@{upstream}..HEAD"], cwd: path, check: false)
            if let r, r.succeeded, let n = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
                self.unpushed = n
                self.hasUpstream = true
            } else {
                self.unpushed = nil
                self.hasUpstream = false
            }
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
    case none
}

extension WorkspaceModel {
    var gitState: PanelGitState { PanelGitState.of(self) }

    func refreshGitState() {
        if let path = workspace?.path { gitState.refresh(path: path) }
    }

    /// Refresh everything the right panel shows.
    func refreshPanel() {
        refreshDiff()
        refreshGitState()
        if panelTab == .files || files.isEmpty { refreshFiles() }
        if shipMode == .pullRequest { refreshPR() }
    }

    var hasLocalChanges: Bool { gitState.uncommitted > 0 || (gitState.unpushed ?? 0) > 0 }

    var primaryShipAction: PrimaryShipAction {
        if shipMode == .trunk { return .pushToTrunk }
        guard slug != nil else { return .none }
        guard let pr = prStatus?.pr else { return .createPR }
        switch pr.state {
        case .open: return hasLocalChanges ? .commitAndPush : mergeAction
        case .merged, .closed: return hasLocalChanges ? .createPR : .none
        }
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
