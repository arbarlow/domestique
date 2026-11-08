import DQCore
import ServerKit
import SwiftUI

enum Route: Hashable {
    case workspace(server: UUID, id: String)
    case server(UUID)
}

/// Home: every active workspace on every server, grouped by server, with what needs you on top.
struct RootView: View {
    @Environment(ServerList.self) private var serverList
    @State private var path: [Route] = []
    @State private var sheet: Sheet?

    enum Sheet: Identifiable, Hashable {
        case addServer(ServerLink?)
        case newWorkspace
        var id: Self { self }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if serverList.servers.isEmpty {
                    emptyState
                } else {
                    workspaceList
                }
            }
            .navigationTitle("Domestique")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Servers", systemImage: "server.side") {
                        ForEach(serverList.servers) { server in
                            Button(server.name, systemImage: "gearshape") { path.append(.server(server.id)) }
                        }
                        Divider()
                        Button("Add server", systemImage: "plus") { sheet = .addServer(nil) }
                    }
                }
                if !serverList.servers.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New workspace", systemImage: "square.and.pencil") { sheet = .newWorkspace }
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .workspace(let serverID, let id):
                    if let server = serverList.connection(id: serverID) {
                        WorkspaceView(server: server, workspaceID: id)
                    } else {
                        ContentUnavailableView("Server removed", systemImage: "server.side")
                    }
                case .server(let id):
                    if let server = serverList.connection(id: id) { ServerDetailView(server: server) }
                }
            }
        }
        .onOpenURL { url in
            if let link = ServerLink(url) { sheet = .addServer(link) }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .addServer(let link):
                AddServerView(editing: serverList.servers.first { $0.url == link?.url }, prefill: link)
            case .newWorkspace:
                NewWorkspaceView { server, ws in path.append(.workspace(server: server, id: ws)) }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No servers yet", systemImage: "server.side")
        } description: {
            Text("Domestique on iPhone drives the agents on your servers. Add one with its URL and a token from `domestique token create --scope operate`.")
        } actions: {
            Button("Add server") { sheet = .addServer(nil) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var workspaceList: some View {
        List {
            ForEach(serverList.allConnections) { server in
                ServerSection(server: server) { path.append(.server(server.id)) }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { serverList.wake() }
    }
}

private struct ServerSection: View {
    let server: ServerConnection
    let showServer: () -> Void

    var body: some View {
        Section {
            if case .offline(let why) = server.status, !server.loaded {
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !server.loaded {
                HStack {
                    ProgressView()
                    Text("Connecting…").foregroundStyle(.secondary)
                }
            } else if server.activeWorkspaces.isEmpty {
                Text("No workspaces").foregroundStyle(.secondary)
            }
            ForEach(sorted, id: \.id) { ws in
                NavigationLink(value: Route.workspace(server: server.id, id: ws.id)) {
                    WorkspaceRow(server: server, workspace: ws)
                }
                .swipeActions {
                    if server.canTrigger {
                        Button("Archive", systemImage: "archivebox") {
                            Task { try? await server.archive(ws.id) }
                        }
                        .tint(.gray)
                    }
                }
            }
        } header: {
            Button(action: showServer) {
                HStack(spacing: 6) {
                    StatusDot(status: server.status)
                    Text(server.name)
                    if case .offline = server.status, server.loaded {
                        Text("· offline").foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Needs input first, then running, then newest.
    private var sorted: [Proto_Workspace] {
        server.activeWorkspaces.sorted { a, b in
            let ra = rank(server.activity(of: a.id)), rb = rank(server.activity(of: b.id))
            return ra != rb ? ra < rb : a.createdAtMs > b.createdAtMs
        }
    }

    private func rank(_ a: Proto_SessionActivity) -> Int {
        switch a {
        case .awaitingInput: 0
        case .running: 1
        default: 2
        }
    }
}

struct WorkspaceRow: View {
    let server: ServerConnection
    let workspace: Proto_Workspace

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(workspace.name).font(.body.weight(.medium))
                    if workspace.hasUnread_p {
                        Circle().fill(Palette.running).frame(width: 7, height: 7).accessibilityLabel("Unread")
                    }
                }
                HStack(spacing: 4) {
                    if let repo = server.repositories[workspace.repositoryID] {
                        Text(repo.title)
                        Text("·")
                    }
                    Text(workspace.branch).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let label = workspace.stateLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(workspace.state == .failed ? Palette.removed : .secondary)
                        .lineLimit(2)
                }
                if let status = liveStatus {
                    Text(status).font(.caption).foregroundStyle(Palette.running).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if workspace.prNumber > 0 {
                Text("#\(workspace.prNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ActivityIndicator(activity: server.activity(of: workspace.id))
        }
        .padding(.vertical, 2)
    }

    private var liveStatus: String? {
        server.sessions(in: workspace.id).first { !$0.status.isEmpty && $0.activity != .idle }?.status
    }
}
