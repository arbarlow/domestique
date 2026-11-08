import DQCore
import ServerKit
import SwiftUI

/// Getting a workspace's work out: open a pull request or push to the default branch (the agent does these, as on the
/// Mac, writing the commit messages and description), then follow the PR through to merged.
struct ShipView: View {
    let server: ServerConnection
    let workspaceID: String
    let chat: SessionChat?
    let onArchive: () -> Void

    @State private var pr: PullRequestInfo?
    @State private var branch: BranchState?
    @State private var loaded = false
    @State private var loadError: String?
    @State private var busy: String?
    @State private var error: String?
    @State private var confirmTrunk = false
    @State private var confirmMerge = false
    @Environment(\.dismiss) private var dismiss

    private var workspace: Proto_Workspace? { server.workspaces[workspaceID] }
    private var base: String { workspace.map(server.defaultBranch(of:)) ?? "main" }
    private var agentBusy: Bool { chat?.isRunning ?? true }

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            if let pr { pullRequestSection(pr) }
            if let branch { branchSection(branch) }
            actions
        }
        .navigationTitle("Ship")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", systemImage: "xmark") { dismiss() }
            }
        }
        .overlay {
            if !loaded && server.canOperate { ProgressView() }
        }
        .task {
            guard server.canOperate else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .confirmationDialog("Push to \(base)?", isPresented: $confirmTrunk, titleVisibility: .visible) {
            Button("Push to \(base)", role: .destructive) { shipToTrunk() }
        } message: {
            Text("The agent commits this work, rebases it and pushes straight to \(base), with no pull request.")
        }
        .confirmationDialog("Merge pull request?", isPresented: $confirmMerge, titleVisibility: .visible) {
            ForEach(MergeMethod.allCases) { method in
                Button(method.title) { merge(method) }
            }
        }
        .alert("Something went wrong", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: Sections

    private func pullRequestSection(_ pr: PullRequestInfo) -> some View {
        Section("Pull request") {
            if let url = URL(string: pr.url) {
                Link(destination: url) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(pr.number) \(pr.title)").foregroundStyle(.primary)
                        Text(statusLine(pr)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func branchSection(_ branch: BranchState) -> some View {
        Section(workspace?.branch ?? "Branch") {
            LabeledContent("Uncommitted files", value: String(branch.uncommitted))
            LabeledContent("Commits ahead of \(base)", value: String(branch.ahead))
        }
    }

    @ViewBuilder private var actions: some View {
        Section {
            if let busy {
                Label { Text(busy) } icon: { ProgressView() }
            } else if let pr, pr.isOpen {
                openPullRequestActions(pr)
            } else if pr?.isMerged == true, branch?.hasWork != true {
                Button("Archive workspace", systemImage: "archivebox") {
                    dismiss()
                    onArchive()
                }
            } else {
                Button("Create pull request", systemImage: "arrow.triangle.pull") { createPR() }
                    .disabled(agentBusy)
                Button("Push to \(base)", systemImage: "arrow.up.to.line") { confirmTrunk = true }
                    .disabled(agentBusy)
            }
        } footer: {
            if chat == nil {
                Text("Open a chat first: the agent does the shipping.")
            } else if agentBusy && busy == nil {
                Text("The agent is working. Shipping unlocks when it finishes.")
            } else if !server.canOperate {
                Text("This token can ship, but can't see pull request status or merge.")
            }
        }
    }

    @ViewBuilder private func openPullRequestActions(_ pr: PullRequestInfo) -> some View {
        if branch?.hasUnpushed == true {
            Button("Push updates", systemImage: "arrow.up") { pushUpdates(pr) }.disabled(agentBusy)
        }
        if pr.autoMergeRequest != nil {
            Button("Cancel auto-merge", systemImage: "xmark.circle") {
                perform("Cancelling…", "gh pr merge --disable-auto \(pr.number)")
            }
        } else if pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" {
            Button("Ask agent to resolve conflicts", systemImage: "sparkles") {
                ask("Pull request #\(pr.number) has conflicts with \(base). Merge origin/\(base) into this branch, resolve the conflicts preserving both sides' intent, and push. Don't force-push.")
            }
            .disabled(agentBusy)
        } else if pr.checks.contains(where: \.isFailing) {
            Button("Ask agent to fix checks", systemImage: "sparkles") {
                ask("Checks are failing on pull request #\(pr.number). Use `gh pr checks \(pr.number)` and the failed logs to find out why, fix it, and push.")
            }
            .disabled(agentBusy)
        } else if pr.mergeStateStatus == "BEHIND" {
            Button("Update branch", systemImage: "arrow.triangle.2.circlepath") {
                perform("Updating branch…", "gh pr update-branch \(pr.number)")
            }
        } else if pr.checks.contains(where: \.isPending) || pr.mergeStateStatus == "BLOCKED" {
            Button("Merge when ready", systemImage: "clock") {
                perform("Queuing merge…", "gh pr merge --auto --squash \(pr.number)")
            }
        } else {
            Button("Merge", systemImage: "arrow.triangle.merge") { confirmMerge = true }
        }
    }

    private func statusLine(_ pr: PullRequestInfo) -> String {
        if pr.isMerged { return "Merged" }
        if !pr.isOpen { return "Closed" }
        if pr.autoMergeRequest != nil { return "Merging when requirements pass" }
        if pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" { return "Conflicts with \(base)" }
        let failing = pr.checks.filter(\.isFailing).count
        if failing > 0 { return "\(failing) check\(failing == 1 ? "" : "s") failing" }
        let pending = pr.checks.filter(\.isPending).count
        if pending > 0 { return "\(pending) check\(pending == 1 ? "" : "s") running" }
        if pr.mergeStateStatus == "BEHIND" { return "Behind \(base)" }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
        if pr.reviewDecision == "REVIEW_REQUIRED" { return "Needs review" }
        if pr.mergeStateStatus == "BLOCKED" { return "Waiting on requirements" }
        return "Ready to merge"
    }

    // MARK: Actions

    private func refresh() async {
        guard server.canOperate else { return }
        do {
            async let pullRequest = server.pullRequest(of: workspaceID)
            async let state = server.branchState(of: workspaceID, base: base)
            (pr, branch) = try await (pullRequest, state)
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func context() -> ShipPromptContext? {
        guard let ws = workspace else { return nil }
        return ShipPromptContext(base: base, branch: ws.branch, prNumber: pr?.number)
    }

    private func ask(_ prompt: String) {
        chat?.submit(prompt)
        dismiss()
    }

    private func createPR() {
        guard let ws = workspace, let ctx = context() else { return }
        Task { await server.recordMergeBase(ws) }
        ask(ShipPrompts.render(ShipPromptKind.createPR.defaultTemplate, ctx))
    }

    private func pushUpdates(_ pr: PullRequestInfo) {
        guard let ctx = context() else { return }
        ask(ShipPrompts.render(ShipPromptKind.push.defaultTemplate, ctx))
    }

    /// Runs the repo's trunk gate first, like the Mac.
    private func shipToTrunk() {
        guard var ctx = context() else { return }
        busy = "Preparing…"
        Task {
            defer { busy = nil }
            let config = try? await server.repoConfig(of: workspaceID)
            ctx.checks = (config?.trunkGate ?? []).compactMap { config?.task($0)?.command }
            ask(ShipPrompts.render(ShipPromptKind.trunk.defaultTemplate, ctx))
        }
    }

    private func merge(_ method: MergeMethod) {
        guard let pr else { return }
        perform("Merging…", "gh pr merge --\(method.rawValue) \(pr.number)")
    }

    private func perform(_ label: String, _ script: String) {
        busy = label
        Task {
            defer { busy = nil }
            do {
                try await server.runChecked(in: workspaceID, script)
            } catch {
                self.error = error.localizedDescription
            }
            await refresh()
        }
    }
}
