import DQCore
import Foundation
import GitHubKit

/// Shipping is delegated to the agent (it writes the commit messages and PR description);
/// the app links the result: the PR it opened, or the commits that landed on the default branch.
enum AgentShipKind: Equatable {
    case createPR
    case updatePR
    case trunk
}

extension WorkspaceModel {
    var base: String { repo?.defaultBranch ?? workspace?.baseBranch ?? "main" }

    /// The agent is currently carrying out a ship instruction.
    var isAgentShipping: Bool {
        agentShip != nil && (selectedChat?.isRunning ?? false)
    }

    var agentShipLabel: String {
        switch agentShip {
        case .createPR: "Agent is opening a PR…"
        case .updatePR: "Agent is pushing…"
        case .trunk: "Agent is shipping to \(base)…"
        case nil: ""
        }
    }

    private func shipPromptContext(_ ws: Workspace) -> ShipPromptContext {
        let checks = (config?.trunkGate ?? []).compactMap { config?.task($0)?.command }
        return ShipPromptContext(base: base, branch: ws.branch, prNumber: prStatus?.pr.number, checks: checks)
    }

    func agentCreatePR() {
        guard let ws = workspace else { return }
        shipMessage = nil
        agentShip = .createPR
        recordGhMergeBase()
        watchForPullRequest()
        sendToAgent(app.settings.shipPrompt(.createPR, shipPromptContext(ws)))
    }

    func agentCommitAndPush() {
        guard let ws = workspace else { return }
        shipMessage = nil
        agentShip = .updatePR
        sendToAgent(app.settings.shipPrompt(.push, shipPromptContext(ws)))
    }

    func agentShipToTrunk() {
        guard let ws = workspace else { return }
        shipMessage = nil
        agentShip = .trunk
        sendToAgent(app.settings.shipPrompt(.trunk, shipPromptContext(ws)))
    }

    /// `gh pr create` takes its default base from this git config key (same trick as T3 Code),
    /// so an agent that omits `--base` still targets the right branch.
    func recordGhMergeBase() {
        guard let ws = workspace else { return }
        let key = "branch.\(ws.branch).gh-merge-base"
        let target = base
        let host = self.host
        Task { try? await host.run("git", ["config", key, target], cwd: ws.path) }
    }

    /// Like Conductor: while the agent is opening the PR, look the branch up on GitHub every few
    /// seconds, so the PR is linked even if its URL never appears in a tool result.
    func watchForPullRequest() {
        Task { [weak self] in
            for _ in 0..<60 {  // ~10 minutes
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.agentShip == .createPR || self.selectedChat?.isRunning == true else { return }
                if self.workspace?.prNumber != nil { return }
                self.refreshPR()
            }
        }
    }

    /// Called when a turn in this workspace ends: link whatever the ship instruction produced.
    func finishAgentShip() {
        guard let kind = agentShip else {
            // The agent may have opened a PR on its own initiative.
            if shipMode == .pullRequest, prStatus == nil { refreshPR() }
            return
        }
        agentShip = nil
        switch kind {
        case .createPR, .updatePR:
            refreshPR()
            refreshDiff()
        case .trunk:
            refreshDiff()
            refreshGitState()
            Task {
                guard let ws = workspace else { return }
                try? await Task.sleep(for: .milliseconds(400))
                let ab = aheadBehind
                let dirty = (try? await GitKitBridge.hasUncommitted(ws.path, host: self.host)) ?? false
                if let ab, ab.ahead == 0, !dirty {
                    shipMessage = "Shipped to \(base) ✓"
                } else if let ab, ab.ahead > 0 {
                    shipMessage = "\(ab.ahead) commit\(ab.ahead == 1 ? "" : "s") not on \(base) yet — check the agent's reply."
                }
            }
        }
    }

    /// Spot a PR URL in tool output (e.g. from `gh pr create`) and link it immediately.
    func noticePullRequestURL(in text: String) {
        guard let slug, workspace?.prNumber == nil, text.contains("/pull/") else { return }
        let pattern = "https://github\\.com/\(NSRegularExpression.escapedPattern(for: slug))/pull/(\\d+)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let urlRange = Range(m.range, in: text), let numRange = Range(m.range(at: 1), in: text),
            let number = Int(text[numRange])
        else { return }
        let url = String(text[urlRange])
        app.updateWorkspace(id) {
            $0.prNumber = number
            $0.prURL = url
        }
        refreshPR()
    }
}

import GitKit

/// Small indirection so this file doesn't depend on GitKit details elsewhere.
enum GitKitBridge {
    static func hasUncommitted(_ path: String, host: any ExecutionHost) async throws -> Bool {
        try await Git.hasUncommittedChanges(path: path, host: host)
    }
}

// MARK: - PR status: readiness, alerts, merge-when-ready

extension WorkspaceModel {
    /// What merging needs right now, from GitHub's mergeStateStatus + checks + reviews.
    var mergeAction: PrimaryShipAction {
        guard let s = prStatus else { return .merge }
        if s.autoMergeEnabled || mergeWhenReady != nil { return .waitingToMerge }
        if s.mergeable == .conflicting || s.mergeStateStatus == "DIRTY" { return .resolveConflicts }
        if s.overall == .failing { return .fixCI }
        if s.mergeStateStatus == "BEHIND" { return .updateBranch }
        if s.overall == .pending { return .mergeWhenReady }
        if s.reviewDecision == "REVIEW_REQUIRED" || s.reviewDecision == "CHANGES_REQUESTED" { return .needsReview }
        if s.mergeStateStatus == "BLOCKED" { return .mergeWhenReady }
        return .merge
    }

    /// Short line for the panel header.
    var prStatusLine: String? {
        guard let s = prStatus, s.pr.state == .open else { return nil }
        let failing = s.checks.filter(\.isFailing).count
        let pending = s.checks.filter(\.isPending).count
        let passed = s.checks.filter(\.isPassing).count
        switch mergeAction {
        case .waitingToMerge: return pending > 0 ? "Merging when \(pending) check\(pending == 1 ? "" : "s") pass" : "Merging…"
        case .resolveConflicts: return "Conflicts with \(base)"
        case .fixCI: return "\(failing) check\(failing == 1 ? "" : "s") failing"
        case .updateBranch: return "Behind \(base)"
        case .mergeWhenReady: return pending > 0 ? "\(pending) check\(pending == 1 ? "" : "s") running" : "Waiting on requirements"
        case .needsReview: return s.reviewDecision == "CHANGES_REQUESTED" ? "Changes requested" : "Needs review"
        default: return s.checks.isEmpty ? "Ready to merge" : "\(passed) checks passed"
        }
    }

    /// Merge once it can: GitHub auto-merge if the repo allows it, otherwise the app merges on a green poll.
    func requestMergeWhenReady(method: MergeMethod) async {
        guard let status = prStatus else { return }
        shipBusy = "Queuing merge…"
        defer { shipBusy = nil }
        do {
            try await GitHubClient.shared.enableAutoMerge(prNodeID: status.pr.nodeID, method: method)
            shipMessage = "Auto-merge on: GitHub merges #\(status.pr.number) when checks pass."
        } catch {
            // Repo doesn't allow auto-merge (or token can't): watch it ourselves.
            mergeWhenReady = method
            shipMessage = "Will merge #\(status.pr.number) as soon as checks pass (keep Domestique open)."
        }
        refreshPR()
    }

    func cancelMergeWhenReady() async {
        if mergeWhenReady != nil {
            mergeWhenReady = nil
            shipMessage = nil
        } else if prStatus?.autoMergeEnabled == true {
            await setAutoMerge(false, method: .squash)
        }
    }

    func updateBranch() async {
        guard let slug, let status = prStatus else { return }
        shipBusy = "Updating branch…"
        defer { shipBusy = nil }
        do {
            try await GitHubClient.shared.updateBranch(slug: slug, number: status.pr.number)
            shipMessage = "Merged \(base) into the PR branch on GitHub. Pull it locally before more changes."
            refreshPR()
        } catch {
            shipMessage = Self.friendlyGitHubError(error, base: base)
        }
    }

    /// Plain-English versions of GitHub's merge refusals.
    static func friendlyGitHubError(_ error: Error, base: String) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("unstable") {
            return "GitHub won't merge yet: some checks haven't passed. Use Merge when ready to merge automatically once they're green."
        }
        if lower.contains("not mergeable") || lower.contains("conflict") || lower.contains("dirty") {
            return "The PR has conflicts with \(base). Resolve them (or ask the agent) and push."
        }
        if lower.contains("base branch was modified") || lower.contains("behind") {
            return "\(base) moved on. Update the branch, then merge."
        }
        if lower.contains("review") {
            return "The PR needs an approving review before it can merge."
        }
        if lower.contains("auto merge") || lower.contains("auto-merge") {
            return "Auto-merge isn't enabled for this repository on GitHub."
        }
        return raw
    }

    /// Called after every poll: alert on transitions, run the app-side merge-when-ready.
    func prStatusChanged(from old: PullRequestStatus?, to new: PullRequestStatus) {
        // Merge-when-ready (app side).
        if let method = mergeWhenReady, new.pr.state == .open, new.overall != .pending, new.overall != .failing,
            new.mergeable != .conflicting, shipBusy == nil
        {
            mergeWhenReady = nil
            Task { await self.merge(method: method) }
        } else if mergeWhenReady != nil, new.overall == .failing {
            mergeWhenReady = nil
            shipMessage = "Didn't merge: checks failed."
        }
        guard let old, old.pr.number == new.pr.number else { return }
        var alert: String?
        if old.pr.state != .merged, new.pr.state == .merged {
            alert = "PR #\(new.pr.number) merged"
            mergeWhenReady = nil
        } else if old.overall != new.overall {
            switch new.overall {
            case .passing: alert = "Checks passed on PR #\(new.pr.number)"
            case .failing: alert = "Checks failed on PR #\(new.pr.number)"
            default: break
            }
        }
        if let alert { notify(alert) }
    }

    private func notify(_ text: String) {
        if app.selectedWorkspaceID != id { app.updateWorkspace(id) { $0.hasUnread = true } }
        Notifier.post(title: workspace.map { app.repo($0.repoID)?.title ?? $0.name } ?? "Domestique", body: text)
    }
}
