import DQCore
import ServerKit
import SwiftUI

/// Settings → Servers: This Mac's server and any remote ones, one card each, plus adding new ones.
/// Each card also says what new workspaces on that server can be (a worktree, or a sandbox from one of
/// its sandbox providers). The list is app-wide: every repository can create workspaces on every server.
struct ServerSettings: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(
                title: "Servers",
                subtitle: "Machines that run your agents and workspaces. Each one can make git worktrees on itself and start cloud sandboxes from its sandbox providers, which it keeps the API keys for. This Mac always has one."
            ) {
                if !adding {
                    Button("Add server…") { withAnimation(.snappy(duration: 0.2)) { adding = true } }
                        .buttonStyle(.softCompact)
                }
            }
            if adding {
                AddServerForm(onDone: { withAnimation(.snappy(duration: 0.2)) { adding = false } })
            }
            DefaultServerSection()
            VStack(spacing: 14) {
                ServerCard(link: app.server)
                ForEach(app.settings.servers) { cfg in
                    if let link = app.remoteServers[cfg.id] { ServerCard(link: link) }
                }
            }
            Text("You're in charge of reaching remote servers (Tailscale, a VPN or a reverse proxy) and of TLS. Tokens are kept in your Keychain. Saving a server's sandbox providers needs an admin token.")
                .font(Theme.small)
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
    }
}

// MARK: - Default

/// Which server new workspaces go to, and what that server makes by default.
private struct DefaultServerSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let current = app.settings.defaultServer ?? .thisMac
        let servers = app.servers.filter { $0 == current || !app.locations(on: $0).isEmpty }
        SettingsSection(title: "New workspaces") {
            SettingsRow(
                title: "Default server",
                subtitle: "Starts as \(app.longLocationName(app.appDefaultLocation)). Change what a server starts with on its card; repositories can pick their own in their settings"
            ) {
                Picker("", selection: Binding(
                    get: { current },
                    set: { c in app.settings.defaultServer = c == .thisMac ? nil : c }
                )) {
                    ForEach(servers, id: \.self) { Text(app.serverName(for: $0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}

// MARK: - Server card

private struct ServerCard: View {
    @Environment(AppModel.self) private var app
    let link: ServerLink
    @State private var editing = false
    @State private var confirmRemove = false
    @State private var restarting = false
    @State private var pairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if case .unavailable(let why) = link.status {
                Hairline().padding(.leading, 14)
                ProblemRow(problem: ConnectionProblem(why, server: link.server))
            }
            Hairline().padding(.leading, 14)
            facts
            if link.isLocal {
                Hairline().padding(.leading, 14)
                keepRunning
            }
            if link.isLocal || link.welcome?.scope == .admin {
                Hairline().padding(.leading, 14)
                phoneRow
            }
            Hairline().padding(.leading, 14)
            ServerTargets(link: link)
            if editing, case .remote(let cfg) = link.server {
                Hairline().padding(.leading, 14)
                EditServerForm(config: cfg, onDone: { withAnimation(.snappy(duration: 0.2)) { editing = false } })
            }
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 0.5))
        .sheet(isPresented: $pairing) { PairPhoneSheet(link: link) }
        .confirmationDialog("Remove \(link.displayName)?", isPresented: $confirmRemove) {
            if case .remote(let cfg) = link.server {
                Button("Remove", role: .destructive) { app.removeServer(cfg.id) }
            }
        } message: {
            Text("Its workspaces disappear from this Mac but keep running on the server. Add it again to get them back.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: link.isLocal ? "laptopcomputer" : "server.rack", tint: link.isLocal ? .gray : .blue, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.displayName).font(Theme.uiMedium).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if isDefaultServer, app.settings.servers.count > 0 {
                Text("Default")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Theme.hover, in: Capsule())
                    .help("New workspaces go to this server unless a repository picks another")
            }
            StatusPill(status: link.status)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var isDefaultServer: Bool {
        (app.settings.defaultServer ?? .thisMac) == (link.serverID.map { .server($0) } ?? .thisMac)
    }

    /// Who answers on the other end: "Alexs-Mac · dev · darwin/arm64", else where we're trying to reach.
    private var subtitle: String {
        if let w = link.welcome {
            return [w.serverName, w.serverVersion, link.info?.platform].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        switch link.server {
        case .local:
            return app.settings.keepServerRunning
                ? "Starts with Domestique and keeps agents working after it quits" : "Starts and stops with Domestique"
        case .remote: return "Remote server"
        }
    }

    @ViewBuilder private var actions: some View {
        switch link.server {
        case .local:
            Menu {
                Button("Use for New Workspaces") { app.settings.defaultServer = nil }
                    .disabled(isDefaultServer || app.locations(on: .thisMac).isEmpty)
                Divider()
                Button("Show Log") { NSWorkspace.shared.open(LocalServer.dataFile("log", in: LocalServer.home)) }
                Button("Show Data in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LocalServer.home]) }
                Divider()
                Button(restarting ? "Restarting…" : "Restart server") { restart() }
                    .disabled(working > 0 || restarting || !link.isEnabled)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(working > 0 ? "Restart is available once agents finish" : "More")
        case .remote:
            Menu {
                Button("Edit…") { withAnimation(.snappy(duration: 0.2)) { editing = true } }
                if let id = link.serverID {
                    Button("Use for New Workspaces") { app.settings.defaultServer = .server(id) }
                        .disabled(isDefaultServer || app.locations(on: .server(id)).isEmpty)
                }
                Divider()
                Button("Remove…", role: .destructive) { confirmRemove = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    private var phoneRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("iPhone").font(Theme.uiMedium).foregroundStyle(Theme.text)
                Text(link.isLocal
                    ? (app.settings.phoneAccessAddress.map { "Listening for phones on \($0)" } ?? "Not reachable from a phone yet")
                    : "Pair the iPhone app with this server")
                    .font(Theme.small).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 12)
            Button("Connect iPhone…") { pairing = true }
                .buttonStyle(.softCompact)
                .disabled(!link.isConnected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var keepRunning: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep running after Domestique quits").font(Theme.uiMedium).foregroundStyle(Theme.text)
                Text(app.settings.keepServerRunning
                    ? "Agents keep working while Domestique is closed"
                    : "Quitting Domestique stops this server and any agents still working")
                    .font(Theme.small).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { app.settings.keepServerRunning },
                set: { app.settings.keepServerRunning = $0 }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var facts: some View {
        HStack(spacing: 0) {
            Fact(label: "Agents", value: agents, warn: link.info?.providers.isEmpty == true)
            Fact(label: "Workspaces", value: "\(workspaceCount)")
            Fact(label: "Working now", value: working > 0 ? "\(working)" : "None")
            if link.isLocal {
                Fact(label: "Data", value: LocalServer.home.path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"), mono: true)
            } else if case .remote(let cfg) = link.server {
                Fact(label: "URL", value: cfg.url, mono: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var agents: String {
        guard let info = link.info else { return "–" }
        if info.providers.isEmpty { return "None found" }
        return info.providers.map { ProviderKind(proto: $0).displayName }.joined(separator: ", ")
    }

    private var workspaceCount: Int {
        app.state.workspaces.filter { link.manages($0) && !$0.isArchived }.count
    }

    private var working: Int {
        link.activity.values.filter { $0 == .running || $0 == .awaitingInput }.count
    }

    private func restart() {
        restarting = true
        Task {
            await link.restart()
            restarting = false
        }
    }
}

/// One labelled value in a card's facts strip.
private struct Fact: View {
    let label: String
    let value: String
    var mono = false
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.text3)
            Text(value)
                .font(mono ? Theme.monoSmall : Theme.small)
                .foregroundStyle(warn ? Theme.warning : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusPill: View {
    let status: ServerLink.Status

    var body: some View {
        HStack(spacing: 5) {
            if status == .starting {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var label: String {
        switch status {
        case .connected: "Connected"
        case .starting: "Connecting"
        case .unavailable: "Offline"
        case .disabled: "Off"
        }
    }

    private var color: Color {
        switch status {
        case .connected: Theme.added
        case .starting: Theme.running
        case .unavailable: Theme.warning
        case .disabled: Theme.text3
        }
    }
}

// MARK: - Connection problems

/// A connection error in plain words, with the raw error kept for the tooltip.
struct ConnectionProblem {
    var message: String
    var hint: String?
    var raw: String

    init(_ raw: String, server: ServerLink.Server) {
        self.raw = raw
        let lower = raw.lowercased()
        let target: String = switch server {
        case .local: "This Mac's server"
        case .remote(let cfg): URL(string: cfg.url).map { u in [u.host, u.port.map(String.init)].compactMap { $0 }.joined(separator: ":") } ?? cfg.url
        }
        if lower.contains("unauthenticated") || lower.contains("invalid token") || lower.contains("token is required") {
            message = "The token was rejected."
            hint = "Create a new one on the server (domestique token create) and paste it with Edit."
        } else if lower.contains("refused") || lower.contains("error 61") || lower.contains("nwerror") {
            message = "Nothing is answering at \(target)."
            hint = "Check that domestique is running there and that this Mac can reach it. Retrying automatically."
        } else if lower.contains("timed out") || lower.contains("timeout") {
            message = "\(target) didn't answer in time."
            hint = "Retrying automatically."
        } else if lower.contains("reconnecting") {
            message = "Reconnecting…"
            hint = nil
        } else {
            message = raw.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
            hint = "Retrying automatically."
        }
    }
}

private struct ProblemRow: View {
    let problem: ConnectionProblem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.message).font(Theme.small).foregroundStyle(Theme.text)
                if let hint = problem.hint {
                    Text(hint).font(Theme.small).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .help(problem.raw)
    }
}

// MARK: - Adding and editing

/// Name, URL and token, with a connection test.
private struct ServerFields: View {
    @Binding var name: String
    @Binding var url: String
    @Binding var token: String
    var tokenPlaceholder = "dq_…"
    @State private var testing = false
    @State private var result: Result<String, Error>?

    var body: some View {
        SettingsRow(title: "Name", subtitle: "Shown in the sidebar and pickers") {
            TextField("hetzner-box", text: $name).modifier(FieldStyle())
        }
        SettingsRow(title: "URL", subtitle: "ws:// or wss://, e.g. wss://box.tailnet.ts.net:7420") {
            TextField("wss://host:7420", text: $url).modifier(FieldStyle())
        }
        SettingsRow(title: "Token", subtitle: "On the server: domestique token create --name mac --scope operate") {
            SecureField(tokenPlaceholder, text: $token).modifier(FieldStyle())
        }
        SettingsRow(title: "Connection") {
            HStack(spacing: 8) {
                switch result {
                case .success(let s):
                    Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.added)
                case .failure(let e):
                    Label(ConnectionProblem(e.localizedDescription, server: .remote(ServerConfig(name: name, url: url))).message,
                          systemImage: "xmark.circle.fill")
                        .foregroundStyle(Theme.removed)
                        .help(e.localizedDescription)
                case nil:
                    EmptyView()
                }
                Button(testing ? "Testing…" : "Test") { test() }
                    .buttonStyle(.softCompact)
                    .disabled(testing || url.isEmpty || token.isEmpty)
            }
            .font(Theme.small)
            .lineLimit(1)
        }
    }

    private func test() {
        testing = true
        result = nil
        let cfg = ServerConfig(name: name, url: url.trimmingCharacters(in: .whitespaces))
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let info = try await ServerLink.test(cfg, token: token)
                result = .success("\(info.serverName) · \(info.platform)")
            } catch {
                result = .failure(error)
            }
            testing = false
        }
    }
}

private struct AddServerForm: View {
    @Environment(AppModel.self) private var app
    let onDone: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        SettingsSection(title: "New server", footer: error) {
            ServerFields(name: $name, url: $url, token: $token)
            SettingsRow(title: "") {
                HStack(spacing: 6) {
                    Button("Cancel", action: onDone).buttonStyle(.softCompact)
                    Button("Add server", action: add)
                        .buttonStyle(SoftButtonStyle(prominent: true, compact: true))
                        .disabled(name.isEmpty || url.isEmpty || token.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func add() {
        do {
            try app.addServer(
                ServerConfig(name: name.trimmingCharacters(in: .whitespaces), url: url.trimmingCharacters(in: .whitespaces)),
                token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EditServerForm: View {
    @Environment(AppModel.self) private var app
    let config: ServerConfig
    let onDone: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ServerFields(name: $name, url: $url, token: $token, tokenPlaceholder: "Unchanged")
            SettingsRow(title: "", subtitle: error) {
                HStack(spacing: 6) {
                    Button("Cancel", action: onDone).buttonStyle(.softCompact)
                    Button("Save", action: save)
                        .buttonStyle(SoftButtonStyle(prominent: true, compact: true))
                        .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
        .onAppear {
            name = config.name
            url = config.url
        }
    }

    private func save() {
        var cfg = config
        cfg.name = name.trimmingCharacters(in: .whitespaces)
        cfg.url = url.trimmingCharacters(in: .whitespaces)
        do {
            try app.updateServer(cfg, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
