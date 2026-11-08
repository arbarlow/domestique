import DQCore
import GitHubKit
import GitKit
import SwiftUI

struct ChecksTab: View {
    let model: WorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let message = model.shipMessage {
                    InlineNote(text: message)
                }
                switch model.shipMode {
                case .trunk:
                    TrunkSection(model: model)
                case .pullRequest:
                    if model.slug == nil {
                        PanelMessage(text: "No GitHub remote", detail: "Pull requests need an origin on github.com. Switch this workspace to Trunk to push straight to \(model.repo?.defaultBranch ?? "main").")
                    } else if let status = model.prStatus {
                        PRSection(model: model, status: status)
                    } else {
                        GitStatusSection(model: model)
                        ShipHint(
                            text: "Create PR asks the agent to commit with proper messages, push \(model.workspace?.branch ?? "the branch") and open a pull request into \(model.base). It's linked here as soon as it exists.",
                            action: "Create PR", symbol: "arrow.triangle.pull"
                        ) { model.agentCreatePR() }
                    }
                }
                if let err = model.prError {
                    Text(err).font(Theme.small).foregroundStyle(Theme.removed).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model.refreshGitState()
            if model.shipMode == .pullRequest { model.refreshPR() }
        }
    }
}

// MARK: - PR

private struct PRSection: View {
    let model: WorkspaceModel
    let status: PullRequestStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(status.pr.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    StateTag(text: stateText, color: stateColor)
                    if status.pr.isDraft { StateTag(text: "Draft", color: Theme.text2) }
                    if status.mergeable == .conflicting { StateTag(text: "Conflicts", color: Theme.removed) }
                    if let review = status.reviewDecision {
                        StateTag(text: review.replacingOccurrences(of: "_", with: " ").capitalized, color: Theme.running)
                    }
                    if status.autoMergeEnabled { StateTag(text: "Auto-merge on", color: Theme.merged) }
                }
            }

            GitStatusSection(model: model)

            if !status.checks.isEmpty {
                SectionTitle("Checks")
                VStack(spacing: 0) {
                    ForEach(status.checks) { check in CheckRow(check: check) }
                }
                if !status.failingChecks.isEmpty {
                    Button {
                        Task { await model.fixCI() }
                    } label: {
                        Label("Fix CI with agent", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.soft)
                    .disabled(model.shipBusy != nil)
                }
            }

            if status.pr.state == .open {
                MergeControls(model: model, status: status)
            } else if status.pr.state == .merged, let ws = model.workspace {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Merged into \(status.pr.baseRefName)", systemImage: "arrow.triangle.merge")
                        .font(Theme.uiMedium)
                        .foregroundStyle(Theme.merged)
                    Button("Archive workspace") { Task { await model.app.archive(ws) } }
                        .buttonStyle(.soft)
                        .disabled(model.app.archiving.contains(ws.id))
                }
            }
        }
    }

    private var stateText: String {
        switch status.pr.state {
        case .merged: "Merged"
        case .closed: "Closed"
        case .open:
            switch status.overall {
            case .passing: "Checks passing"
            case .failing: "Checks failing"
            case .pending: "Checks running"
            case .none: "Open"
            }
        }
    }

    private var stateColor: Color {
        switch status.pr.state {
        case .merged: Theme.merged
        case .closed: Theme.text2
        case .open:
            switch status.overall {
            case .passing: Theme.added
            case .failing: Theme.removed
            case .pending: Theme.warning
            case .none: Theme.text2
            }
        }
    }
}

private struct CheckRow: View {
    let check: CheckRun
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if check.isPending {
                    Spinner(size: 11)
                } else if check.isFailing {
                    Image(systemName: "xmark").foregroundStyle(Theme.removed)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(Theme.added)
                }
            }
            .font(.system(size: 11, weight: .bold))
            .frame(width: 14)
            Text(check.name)
                .font(Theme.ui)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let c = check.conclusion, check.isFailing {
                Text(c.replacingOccurrences(of: "_", with: " "))
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 6)
            if let url = check.detailsURL {
                IconButton(symbol: "arrow.up.right", help: "Open details", size: 11) { NSWorkspace.shared.open(url) }
                    .opacity(hovering ? 1 : 0.6)
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovering ? Theme.hover : .clear))
        .onHover { hovering = $0 }
    }
}

private struct MergeControls: View {
    let model: WorkspaceModel
    let status: PullRequestStatus
    @AppStorage("dq.mergeMethod") private var methodRaw = MergeMethod.squash.rawValue

    var body: some View {
        let method = MergeMethod(rawValue: methodRaw) ?? .squash
        let action = model.mergeAction
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Merge")
            HStack(spacing: 8) {
                switch action {
                case .waitingToMerge:
                    Label(model.prStatusLine ?? "Waiting to merge", systemImage: "clock.arrow.circlepath")
                        .font(Theme.ui).foregroundStyle(Theme.text2)
                    Spacer()
                    Button("Cancel") { Task { await model.cancelMergeWhenReady() } }.buttonStyle(.softCompact)
                case .merge:
                    Button {
                        Task { await model.merge(method: method) }
                    } label: {
                        Label(method.displayName, systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(.softGo)
                    .disabled(model.shipBusy != nil)
                    MergeOptionsMenu(model: model, methodRaw: $methodRaw, go: true)
                    Spacer()
                default:
                    Button {
                        Task { await model.requestMergeWhenReady(method: method) }
                    } label: {
                        Label("Merge when ready", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(action == .mergeWhenReady ? .softGo : .soft)
                    .disabled(model.shipBusy != nil || action == .resolveConflicts)
                    .help("Merges automatically once checks pass")
                    MergeOptionsMenu(model: model, methodRaw: $methodRaw, go: action == .mergeWhenReady)
                    Spacer()
                }
            }
            switch action {
            case .resolveConflicts:
                Button("Ask agent to rebase and resolve conflicts") { model.askAgentToRebase() }.buttonStyle(.soft)
            case .updateBranch:
                Button("Update branch from \(model.base)") { Task { await model.updateBranch() } }.buttonStyle(.soft)
            case .fixCI:
                Button("Fix CI with agent") { Task { await model.fixCI() } }.buttonStyle(.soft)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Git status (Conductor style "○ 9 uncommitted changes — Commit and push")

private struct GitStatusSection: View {
    let model: WorkspaceModel

    var body: some View {
        let git = model.gitState
        let behind = model.aheadBehind?.behind ?? 0
        let base = model.workspace?.baseBranch ?? "main"
        let hasPR = model.prStatus?.pr.state == .open
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Git status")
            VStack(spacing: 0) {
                if git.uncommitted > 0 {
                    StatusRow(text: "\(git.uncommitted) uncommitted change\(git.uncommitted == 1 ? "" : "s")") {
                        if hasPR {
                            Button("Commit and push") { model.agentCommitAndPush() }
                                .buttonStyle(.softCompact)
                                .disabled(model.isAgentShipping)
                                .help("Ask the agent to commit and push")
                        }
                    }
                }
                if let unpushed = git.unpushed, unpushed > 0 {
                    StatusRow(text: "\(unpushed) commit\(unpushed == 1 ? "" : "s") not pushed") {
                        Button("Push") { Task { await model.pushUpdates(commitMessage: model.defaultCommitMessage) } }
                            .buttonStyle(.softCompact)
                    }
                }
                if behind > 0 {
                    StatusRow(text: "\(behind) commit\(behind == 1 ? "" : "s") behind \(base)") {
                        Button("Pull") { model.askAgentToRebase() }
                            .buttonStyle(.softCompact)
                            .help("Ask the agent to rebase onto origin/\(base)")
                    }
                }
                if git.uncommitted == 0 && (git.unpushed ?? 0) == 0 && behind == 0 {
                    StatusRow(text: "Up to date", done: true) { EmptyView() }
                }
            }
        }
    }
}

private struct StatusRow<Trailing: View>: View {
    let text: String
    var done = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: done ? "checkmark.circle" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(done ? Theme.added : Theme.text3)
                .frame(width: 14)
            Text(text).font(Theme.ui).foregroundStyle(Theme.text)
            Spacer(minLength: 6)
            trailing
        }
        .frame(height: 32)
        .padding(.horizontal, 4)
    }
}

// MARK: - Trunk

private struct TrunkSection: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isPushedToTrunk { pushed }
            GitStatusSection(model: model)
            if !model.isPushedToTrunk || model.hasWorkSinceTrunkPush {
                ShipHint(
                    text: model.isPushedToTrunk
                        ? "There's new work since the last push. Push again to commit it, rebase onto a fresh origin/\(model.base)\(gateText) and push."
                        : "Push to \(model.base) asks the agent to commit with proper messages, rebase onto a fresh origin/\(model.base)\(gateText), resolve any conflicts and push. No pull request.",
                    action: model.isPushedToTrunk ? "Push again" : "Push to \(model.base)", symbol: "arrow.up.to.line"
                ) { model.agentShipToTrunk() }
            }
        }
    }

    /// Like a merged PR: the work has landed; archive it, or keep going and push again.
    @ViewBuilder private var pushed: some View {
        if let ws = model.workspace {
            VStack(alignment: .leading, spacing: 8) {
                Label("Pushed to \(model.base)", systemImage: "arrow.up.to.line")
                    .font(Theme.uiMedium)
                    .foregroundStyle(Theme.merged)
                if let detail = pushedDetail(ws) {
                    Text(detail).font(Theme.small).foregroundStyle(Theme.text3).textSelection(.enabled)
                }
                if !model.hasWorkSinceTrunkPush {
                    Button("Archive workspace") { Task { await model.app.archive(ws) } }
                        .buttonStyle(.softProminent)
                        .disabled(model.app.archiving.contains(ws.id))
                }
            }
        }
    }

    private func pushedDetail(_ ws: Workspace) -> String? {
        var parts: [String] = []
        if let c = ws.trunkPushedCommit { parts.append(String(c.prefix(7))) }
        if let at = ws.trunkPushedAt { parts.append(at.formatted(.relative(presentation: .named))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var gateText: String {
        guard let gate = model.config?.trunkGate, !gate.isEmpty else { return "" }
        return ", run \(gate.joined(separator: ", "))"
    }
}

/// One line of explanation + the action that hands shipping to the agent.
private struct ShipHint: View {
    let text: String
    let action: String
    let symbol: String
    let run: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(text)
                .font(Theme.small)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: run) { Label(action, systemImage: symbol) }
                .buttonStyle(.soft)
        }
    }
}

// MARK: - Bits

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.smallMedium)
            .foregroundStyle(Theme.text2)
            .padding(.leading, 4)
    }
}

struct StateTag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(Theme.smallMedium)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(0.1)))
    }
}

struct InlineNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Theme.text2)
            Text(text).foregroundStyle(Theme.text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(Theme.ui)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.sunken))
    }
}
