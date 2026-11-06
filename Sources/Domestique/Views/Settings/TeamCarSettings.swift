import DQCore
import RaceRadioKit
import SwiftUI

/// Settings → Team Cars: This Mac's server and any remote ones, one card each, plus adding new ones.
/// Each card also says what new workspaces on that car can be (a worktree, or a sandbox from one of
/// its sandbox providers). The list is app-wide: every repository can create workspaces on every car.
struct TeamCarSettings: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(
                title: "Team Cars",
                subtitle: "Machines that run your agents and workspaces. Each one can make git worktrees on itself and start cloud sandboxes from its sandbox providers, which it keeps the API keys for. This Mac always has one."
            ) {
                if !adding {
                    Button("Add Team Car…") { withAnimation(.snappy(duration: 0.2)) { adding = true } }
                        .buttonStyle(.softCompact)
                }
            }
            if adding {
                AddTeamCarForm(onDone: { withAnimation(.snappy(duration: 0.2)) { adding = false } })
            }
            DefaultCarSection()
            VStack(spacing: 14) {
                CarCard(link: app.teamCar)
                ForEach(app.settings.teamCars) { cfg in
                    if let link = app.remoteCars[cfg.id] { CarCard(link: link) }
                }
            }
            Text("You're in charge of reaching remote cars (Tailscale, a VPN or a reverse proxy) and of TLS. Tokens are kept in your Keychain. Saving a car's sandbox providers needs an admin token.")
                .font(Theme.small)
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
    }
}

// MARK: - Default

/// Which car new workspaces go to, and what that car makes by default.
private struct DefaultCarSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let current = app.settings.defaultCar ?? .thisMac
        let cars = app.cars.filter { $0 == current || !app.locations(on: $0).isEmpty }
        SettingsSection(title: "New workspaces") {
            SettingsRow(
                title: "Default Team Car",
                subtitle: "Starts as \(app.longLocationName(app.appDefaultLocation)). Change what a car starts with on its card; repositories can pick their own in their settings"
            ) {
                Picker("", selection: Binding(
                    get: { current },
                    set: { c in app.settings.defaultCar = c == .thisMac ? nil : c }
                )) {
                    ForEach(cars, id: \.self) { Text(app.carName(for: $0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}

// MARK: - Car card

private struct CarCard: View {
    @Environment(AppModel.self) private var app
    let link: TeamCarLink
    @State private var editing = false
    @State private var confirmRemove = false
    @State private var restarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if case .unavailable(let why) = link.status {
                Hairline().padding(.leading, 14)
                ProblemRow(problem: ConnectionProblem(why, car: link.car))
            }
            Hairline().padding(.leading, 14)
            facts
            Hairline().padding(.leading, 14)
            CarTargets(link: link)
            if editing, case .remote(let cfg) = link.car {
                Hairline().padding(.leading, 14)
                EditTeamCarForm(config: cfg, onDone: { withAnimation(.snappy(duration: 0.2)) { editing = false } })
            }
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 0.5))
        .confirmationDialog("Remove \(link.displayName)?", isPresented: $confirmRemove) {
            if case .remote(let cfg) = link.car {
                Button("Remove", role: .destructive) { app.removeTeamCar(cfg.id) }
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
            if isDefaultCar, app.settings.teamCars.count > 0 {
                Text("Default")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Theme.hover, in: Capsule())
                    .help("New workspaces go to this car unless a repository picks another")
            }
            StatusPill(status: link.status)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var isDefaultCar: Bool {
        (app.settings.defaultCar ?? .thisMac) == (link.carID.map { .teamCar($0) } ?? .thisMac)
    }

    /// Who answers on the other end: "Alexs-Mac · dev · darwin/arm64", else where we're trying to reach.
    private var subtitle: String {
        if let w = link.welcome {
            return [w.serverName, w.serverVersion, link.info?.platform].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        switch link.car {
        case .local: return "Starts with Domestique and keeps agents working after it quits"
        case .remote: return "Remote Team Car"
        }
    }

    @ViewBuilder private var actions: some View {
        switch link.car {
        case .local:
            Menu {
                Button("Use for New Workspaces") { app.settings.defaultCar = nil }
                    .disabled(isDefaultCar || app.locations(on: .thisMac).isEmpty)
                Divider()
                Button("Show Log") { NSWorkspace.shared.open(LocalTeamCar.home.appending(path: "teamcar.log")) }
                Button("Show Data in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LocalTeamCar.home]) }
                Divider()
                Button(restarting ? "Restarting…" : "Restart Team Car") { restart() }
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
                if let id = link.carID {
                    Button("Use for New Workspaces") { app.settings.defaultCar = .teamCar(id) }
                        .disabled(isDefaultCar || app.locations(on: .teamCar(id)).isEmpty)
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

    private var facts: some View {
        HStack(spacing: 0) {
            Fact(label: "Agents", value: agents, warn: link.info?.providers.isEmpty == true)
            Fact(label: "Workspaces", value: "\(workspaceCount)")
            Fact(label: "Working now", value: working > 0 ? "\(working)" : "None")
            if link.isLocal {
                Fact(label: "Data", value: LocalTeamCar.home.path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"), mono: true)
            } else if case .remote(let cfg) = link.car {
                Fact(label: "URL", value: cfg.url, mono: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var agents: String {
        guard let info = link.info else { return "–" }
        if info.providers.isEmpty { return "None found" }
        return info.providers.map { ProviderKind(radio: $0).displayName }.joined(separator: ", ")
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
    let status: TeamCarLink.Status

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

    init(_ raw: String, car: TeamCarLink.Car) {
        self.raw = raw
        let lower = raw.lowercased()
        let target: String = switch car {
        case .local: "This Mac's Team Car"
        case .remote(let cfg): URL(string: cfg.url).map { u in [u.host, u.port.map(String.init)].compactMap { $0 }.joined(separator: ":") } ?? cfg.url
        }
        if lower.contains("unauthenticated") || lower.contains("invalid token") || lower.contains("token is required") {
            message = "The token was rejected."
            hint = "Create a new one on the server (teamcar token create) and paste it with Edit."
        } else if lower.contains("refused") || lower.contains("error 61") || lower.contains("nwerror") {
            message = "Nothing is answering at \(target)."
            hint = "Check that teamcar is running there and that this Mac can reach it. Retrying automatically."
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
private struct TeamCarFields: View {
    @Binding var name: String
    @Binding var url: String
    @Binding var token: String
    var tokenPlaceholder = "tc_…"
    @State private var testing = false
    @State private var result: Result<String, Error>?

    var body: some View {
        SettingsRow(title: "Name", subtitle: "Shown in the sidebar and pickers") {
            TextField("hetzner-box", text: $name).modifier(FieldStyle())
        }
        SettingsRow(title: "URL", subtitle: "ws:// or wss://, e.g. wss://box.tailnet.ts.net:7420") {
            TextField("wss://host:7420", text: $url).modifier(FieldStyle())
        }
        SettingsRow(title: "Token", subtitle: "On the server: teamcar token create --name mac --scope operate") {
            SecureField(tokenPlaceholder, text: $token).modifier(FieldStyle())
        }
        SettingsRow(title: "Connection") {
            HStack(spacing: 8) {
                switch result {
                case .success(let s):
                    Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.added)
                case .failure(let e):
                    Label(ConnectionProblem(e.localizedDescription, car: .remote(TeamCarConfig(name: name, url: url))).message,
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
        let cfg = TeamCarConfig(name: name, url: url.trimmingCharacters(in: .whitespaces))
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let info = try await TeamCarLink.test(cfg, token: token)
                result = .success("\(info.serverName) · \(info.platform)")
            } catch {
                result = .failure(error)
            }
            testing = false
        }
    }
}

private struct AddTeamCarForm: View {
    @Environment(AppModel.self) private var app
    let onDone: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        SettingsSection(title: "New Team Car", footer: error) {
            TeamCarFields(name: $name, url: $url, token: $token)
            SettingsRow(title: "") {
                HStack(spacing: 6) {
                    Button("Cancel", action: onDone).buttonStyle(.softCompact)
                    Button("Add Team Car", action: add)
                        .buttonStyle(SoftButtonStyle(prominent: true, compact: true))
                        .disabled(name.isEmpty || url.isEmpty || token.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func add() {
        do {
            try app.addTeamCar(
                TeamCarConfig(name: name.trimmingCharacters(in: .whitespaces), url: url.trimmingCharacters(in: .whitespaces)),
                token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EditTeamCarForm: View {
    @Environment(AppModel.self) private var app
    let config: TeamCarConfig
    let onDone: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            TeamCarFields(name: $name, url: $url, token: $token, tokenPlaceholder: "Unchanged")
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
            try app.updateTeamCar(cfg, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
