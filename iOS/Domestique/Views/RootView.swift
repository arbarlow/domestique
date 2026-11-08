import DQCore
import ServerKit
import SwiftUI

enum Route: Hashable {
    case workspace(server: UUID, id: String)
    case server(UUID)
}

/// Home: like the Mac sidebar, every project with its active workspaces underneath.
struct RootView: View {
    @Environment(ServerList.self) private var serverList
    @State private var path: [Route] = []
    @State private var sheet: Sheet?
    /// The project a workspace is being created in.
    @State private var starting: String?
    @State private var error: String?

    enum Sheet: Identifiable, Hashable {
        case addServer(ServerLink?)
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
                    ToolbarItem(placement: .topBarTrailing) { newWorkspaceMenu }
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
            }
        }
        .alert("Couldn't start the workspace", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var writableServers: [ServerConnection] {
        serverList.allConnections.filter { $0.canTrigger && !$0.repositories.isEmpty }
    }

    private var newWorkspaceMenu: some View {
        Menu("New workspace", systemImage: "square.and.pencil") {
            ForEach(writableServers) { server in
                Section(serverList.servers.count > 1 ? server.name : "") {
                    ForEach(server.sortedRepositories, id: \.id) { repo in
                        Button(repo.title) { start(in: repo, on: server) }
                    }
                }
            }
        }
        .disabled(writableServers.isEmpty || starting != nil)
    }

    /// One tap, no form: the workspace opens straight onto an empty chat, as on the Mac.
    private func start(in repo: Proto_Repository, on server: ServerConnection) {
        guard starting == nil else { return }
        starting = repo.id
        Task {
            defer { starting = nil }
            do {
                let ws = try await server.createWorkspace(repositoryID: repo.id, provider: server.providers.first ?? .claude)
                path.append(.workspace(server: server.id, id: ws.id))
            } catch {
                self.error = error.localizedDescription
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
                if server.loaded && !server.repositories.isEmpty {
                    ForEach(server.sortedRepositories, id: \.id) { repo in
                        ProjectSection(
                            server: server, repo: repo, showsServer: serverList.servers.count > 1,
                            isStarting: starting == repo.id
                        ) { start(in: repo, on: server) }
                    }
                } else {
                    ServerPlaceholderSection(server: server) { path.append(.server(server.id)) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .refreshable { serverList.wake() }
    }
}

/// A project and its active workspaces, newest first.
private struct ProjectSection: View {
    let server: ServerConnection
    let repo: Proto_Repository
    let showsServer: Bool
    let isStarting: Bool
    let newWorkspace: () -> Void

    private var workspaces: [Proto_Workspace] {
        server.activeWorkspaces.filter { $0.repositoryID == repo.id }
    }

    var body: some View {
        Section {
            ForEach(workspaces, id: \.id) { ws in
                NavigationLink(value: Route.workspace(server: server.id, id: ws.id)) {
                    WorkspaceRow(server: server, workspace: ws)
                }
                .listRowBackground(Palette.canvas)
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
            HStack(spacing: 8) {
                RepoMonogram(name: repo.title)
                Text(repo.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                if server.status != .connected { StatusDot(status: server.status) }
                if showsServer {
                    Text(server.name).font(.caption).foregroundStyle(Palette.text3).lineLimit(1)
                }
                Spacer(minLength: 4)
                if server.canTrigger {
                    Button(action: newWorkspace) {
                        Group {
                            if isStarting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                            }
                        }
                        .foregroundStyle(Palette.text2)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isStarting)
                    .accessibilityLabel("New workspace in \(repo.title)")
                }
            }
            .textCase(nil)
        }
    }
}

/// A server with nothing to list yet: connecting, offline, or no projects.
private struct ServerPlaceholderSection: View {
    let server: ServerConnection
    let showServer: () -> Void

    var body: some View {
        Section {
            Group {
                if case .offline(let why) = server.status, !server.loaded {
                    Label(why, systemImage: "exclamationmark.triangle")
                } else if !server.loaded {
                    HStack {
                        ProgressView()
                        Text("Connecting…")
                    }
                } else {
                    Text("No projects yet. Add a repository from the server's page.")
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.text2)
            .listRowBackground(Palette.canvas)
        } header: {
            Button(action: showServer) {
                HStack(spacing: 6) {
                    StatusDot(status: server.status)
                    Text(server.name)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.text)
            }
            .buttonStyle(.plain)
            .textCase(nil)
        }
    }
}

/// The Mac's coloured initial for a project.
private struct RepoMonogram: View {
    let name: String

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
            .accessibilityHidden(true)
    }

    private var color: Color {
        let palette: [Color] = [.indigo, .teal, .orange, .pink, .blue, .green, .purple, .brown]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }
}

struct WorkspaceRow: View {
    let server: ServerConnection
    let workspace: Proto_Workspace

    private var sessions: [Proto_Session] { server.sessions(in: workspace.id) }

    /// The chat's title once it has one, like the Mac sidebar; the workspace's name until then.
    private var title: String {
        switch workspace.state {
        case .creating: return "Creating \(workspace.name)…"
        case .settingUp: return "Setting up \(workspace.name)…"
        case .failed: return "\(workspace.name) (failed)"
        default:
            let named = sessions.first { !$0.title.isEmpty && $0.title != "New chat" }
            return named?.title ?? workspace.name.capitalized
        }
    }

    private var liveStatus: String? {
        sessions.first { !$0.status.isEmpty && $0.activity != .idle }?.status
    }

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceGlyph(workspace: workspace, activity: server.activity(of: workspace.id))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(workspace.hasUnread_p ? .semibold : .regular))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(liveStatus ?? workspace.branch)
                    .font(.caption)
                    .foregroundStyle(liveStatus == nil ? Palette.text2 : Palette.running)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if workspace.prNumber > 0 {
                Text(verbatim: "#\(workspace.prNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.text2)
            }
            if workspace.hasUnread_p {
                Circle().fill(Palette.running).frame(width: 7, height: 7).accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Branch glyph that doubles as status, as in the Mac sidebar.
private struct WorkspaceGlyph: View {
    let workspace: Proto_Workspace
    let activity: Proto_SessionActivity

    var body: some View {
        switch workspace.state {
        case .creating, .settingUp:
            ProgressView().controlSize(.small).accessibilityLabel("Setting up")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning).accessibilityLabel("Failed")
        default:
            if activity == .awaitingInput || activity == .running {
                ActivityIndicator(activity: activity)
            } else {
                Image(systemName: workspace.prNumber > 0 ? "arrow.triangle.pull" : "arrow.triangle.branch")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.text2)
                    .accessibilityHidden(true)
            }
        }
    }
}
