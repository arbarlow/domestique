import GitHubKit
import SwiftUI

/// "#816 ↗  Uncommitted changes                [Commit and push]"
struct PanelHeader: View {
    let model: WorkspaceModel
    @AppStorage("dq.mergeMethod") private var mergeMethodRaw = MergeMethod.squash.rawValue

    private var mergeMethod: MergeMethod { MergeMethod(rawValue: mergeMethodRaw) ?? .squash }

    var body: some View {
        HStack(spacing: 10) {
            if let pr = model.prStatus?.pr {
                PRChip(number: pr.number, url: pr.url, state: pr.state, overall: model.prStatus?.overall)
            }
            Text(model.prStatusLine ?? model.panelStatusText)
                .font(Theme.uiMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let busy = model.shipBusy ?? (model.isAgentShipping ? model.agentShipLabel : nil) {
                HStack(spacing: 6) {
                    Spinner(size: 11)
                    Text(busy).font(Theme.small).foregroundStyle(Theme.text2).lineLimit(1)
                }
            } else {
                primaryAction
            }
        }
        .padding(.horizontal, 14)
        .headerBar()
        .background(Theme.panel)
    }

    @ViewBuilder private var primaryAction: some View {
        switch model.primaryShipAction {
        case .createPR:
            Button {
                model.agentCreatePR()
            } label: {
                Label("Create PR", systemImage: "arrow.triangle.pull")
            }
            .buttonStyle(.softProminent)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Ask the agent to commit, push and open a pull request (⇧⌘P)")
        case .commitAndPush:
            Button {
                model.agentCommitAndPush()
            } label: {
                Label("Commit and push", systemImage: "arrow.up.circle")
            }
            .buttonStyle(.softProminent)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Ask the agent to commit and push to the PR branch (⇧⌘P)")
        case .pushToTrunk:
            Button {
                model.agentShipToTrunk()
            } label: {
                Label("Push to \(model.base)", systemImage: "arrow.up.to.line")
            }
            .buttonStyle(.softProminent)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Ask the agent to commit, rebase onto origin/\(model.base) and push (⇧⌘P)")
        case .merge:
            HStack(spacing: 4) {
                Button {
                    Task { await model.merge(method: mergeMethod) }
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.softProminent)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("\(mergeMethod.displayName) (⇧⌘P)")
                MergeOptionsMenu(model: model, methodRaw: $mergeMethodRaw)
            }
        case .mergeWhenReady:
            HStack(spacing: 4) {
                Button {
                    Task { await model.requestMergeWhenReady(method: mergeMethod) }
                } label: {
                    Label("Merge when ready", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.softProminent)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("Merge automatically once checks pass (⇧⌘P)")
                MergeOptionsMenu(model: model, methodRaw: $mergeMethodRaw)
            }
        case .waitingToMerge:
            Button {
                Task { await model.cancelMergeWhenReady() }
            } label: {
                Label("Cancel auto-merge", systemImage: "xmark.circle")
            }
            .buttonStyle(.soft)
            .help("Stop waiting to merge")
        case .fixCI:
            HStack(spacing: 4) {
                Button {
                    Task { await model.fixCI() }
                } label: {
                    Label("Fix CI", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.softProminent)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("Send the failing logs to the agent (⇧⌘P)")
                MergeOptionsMenu(model: model, methodRaw: $mergeMethodRaw)
            }
        case .updateBranch:
            Button {
                Task { await model.updateBranch() }
            } label: {
                Label("Update branch", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.softProminent)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Merge \(model.base) into the PR branch on GitHub (⇧⌘P)")
        case .resolveConflicts:
            Button {
                model.askAgentToRebase()
            } label: {
                Label("Resolve conflicts", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.softProminent)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Ask the agent to rebase onto \(model.base) and resolve conflicts (⇧⌘P)")
        case .needsReview:
            Label("Needs review", systemImage: "person.crop.circle.badge.questionmark")
                .font(Theme.ui)
                .foregroundStyle(Theme.text2)
        case .none:
            EmptyView()
        }
    }
}

/// PR number chip with an external-link arrow.
struct PRChip: View {
    let number: Int
    let url: String
    let state: PRState
    let overall: ChecksOverall?
    @State private var hovering = false

    var body: some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 0) {
                Text(verbatim: "#\(number)")
                    .padding(.horizontal, 7)
                Hairline(vertical: true).frame(height: 16)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .font(Theme.smallMedium.monospacedDigit())
            .foregroundStyle(color)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open pull request on GitHub")
    }

    private var color: Color {
        switch state {
        case .merged: return Theme.merged
        case .closed: return Theme.text2
        case .open:
            switch overall {
            case .failing: return Theme.removed
            case .passing: return Theme.added
            case .pending: return Theme.warning
            default: return Theme.text2
            }
        }
    }
}

/// Merge method + auto-merge options next to the Merge button.
struct MergeOptionsMenu: View {
    let model: WorkspaceModel
    @Binding var methodRaw: String

    var body: some View {
        Menu {
            Section("Merge method") {
                ForEach(MergeMethod.allCases) { m in
                    Button {
                        methodRaw = m.rawValue
                    } label: {
                        if m.rawValue == methodRaw { Label(m.displayName, systemImage: "checkmark") } else { Text(m.displayName) }
                    }
                }
            }
            Divider()
            let method = MergeMethod(rawValue: methodRaw) ?? .squash
            if model.mergeAction == .waitingToMerge {
                Button("Cancel merge when ready") { Task { await model.cancelMergeWhenReady() } }
            } else {
                Button("Merge when ready") { Task { await model.requestMergeWhenReady(method: method) } }
            }
            // GitHub decides; e.g. non-required checks failing or an admin override.
            Button("Merge now") { Task { await model.merge(method: method) } }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 0.5))
        .help("Merge options")
    }
}
