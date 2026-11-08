import DQCore
import ServerKit
import SwiftUI

/// A workspace: its chats (sessions) one at a time, switched from the title menu, plus its changes.
struct WorkspaceView: View {
    let server: ServerConnection
    let workspaceID: String
    @State private var selected: String?
    @State private var showDiff = false
    @State private var showShip = false
    @State private var showRun = false
    @State private var error: String?
    @State private var confirmArchive = false
    @Environment(\.dismiss) private var dismiss

    private var workspace: Proto_Workspace? { server.workspaces[workspaceID] }
    private var sessions: [Proto_Session] { server.sessions(in: workspaceID) }
    private var current: Proto_Session? {
        sessions.first { $0.id == selected } ?? sessions.first
    }

    var body: some View {
        Group {
            if let session = current {
                ChatView(chat: server.chat(for: session.id), canWrite: server.canTrigger) { provider, model in
                    switchProvider(of: session, to: provider, model: model)
                }
                .id(session.id)
            } else if let ws = workspace, ws.state == .creating || ws.state == .settingUp {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text(ws.stateLabel ?? "")
                }
            } else {
                ContentUnavailableView {
                    Label("No chats", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(workspace?.stateLabel ?? "Start a chat with an agent in this workspace.")
                } actions: {
                    if server.canTrigger {
                        Button("New chat") { newChat() }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { titleMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Changes", systemImage: "plusminus") { showDiff = true }
                    if server.canTrigger {
                        Button("Ship", systemImage: "paperplane") { showShip = true }
                    }
                    if server.canOperate {
                        Button("Run & preview", systemImage: "play") { showRun = true }
                    }
                    if server.canTrigger {
                        Button("New chat", systemImage: "plus.bubble") { newChat() }
                        if let session = current {
                            Button("Close this chat", systemImage: "xmark.bubble", role: .destructive) {
                                close(session.id)
                            }
                        }
                        Divider()
                        Button("Archive workspace", systemImage: "archivebox", role: .destructive) { confirmArchive = true }
                    }
                    if let url = workspace.flatMap({ URL(string: $0.prURL) }), workspace?.prNumber ?? 0 > 0 {
                        Link(destination: url) { Label("Open PR #\(workspace!.prNumber)", systemImage: "arrow.triangle.pull") }
                    }
                }
            }
        }
        .sheet(isPresented: $showDiff) {
            NavigationStack { DiffView(server: server, workspaceID: workspaceID) }
        }
        .sheet(isPresented: $showShip) {
            NavigationStack {
                ShipView(server: server, workspaceID: workspaceID, chat: current.map { server.chat(for: $0.id) }) {
                    confirmArchive = true
                }
            }
        }
        .sheet(isPresented: $showRun) {
            NavigationStack { RunView(server: server, workspaceID: workspaceID) }
        }
        .confirmationDialog("Archive \(workspace?.name ?? "workspace")?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                Task {
                    do {
                        try await server.archive(workspaceID)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("The worktree is removed on \(server.name). The branch stays.")
        }
        .alert("Something went wrong", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var titleMenu: some View {
        Menu {
            ForEach(sessions, id: \.id) { r in
                Button {
                    selected = r.id
                } label: {
                    if r.activity == .awaitingInput {
                        Label("\(r.displayTitle) · needs input", systemImage: "hand.raised.fill")
                    } else if r.id == current?.id {
                        Label(r.displayTitle, systemImage: "checkmark")
                    } else if r.activity == .running {
                        Label(r.displayTitle, systemImage: "ellipsis")
                    } else {
                        Text(r.displayTitle)
                    }
                }
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(workspace?.name ?? "Workspace").font(.headline)
                    if sessions.count > 1 {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let session = current {
                    Text(session.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
        .disabled(sessions.count < 2)
        .accessibilityLabel("Chats")
    }

    /// A new chat with the agent in use; the composer's model menu can change it before the first message.
    private func newChat() {
        let provider = current?.providerKind ?? server.providers.first ?? .claude
        Task {
            do {
                let r = try await server.openSession(workspaceID: workspaceID, provider: provider)
                selected = r.id
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// A session's agent is fixed, so changing it means replacing the (still empty) chat.
    private func switchProvider(of session: Proto_Session, to provider: ProviderKind, model: String) {
        let draft = server.chat(for: session.id).draft
        Task {
            do {
                let r = try await server.openSession(
                    workspaceID: workspaceID, provider: provider, model: model, permission: session.permissionMode)
                server.chat(for: r.id).draft = draft
                selected = r.id
                try await server.closeSession(session.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func close(_ id: String) {
        Task {
            do {
                try await server.closeSession(id)
                if selected == id { selected = nil }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension ProviderKind {
    var symbol: String { self == .claude ? "asterisk" : "hexagon" }
}
