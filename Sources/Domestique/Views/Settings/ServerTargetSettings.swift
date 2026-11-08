import DQCore
import HostKit
import SwiftUI

/// Inside each server's card in Settings → Servers: what new workspaces on that server can be. A git
/// worktree on the server itself (can be turned off), and a sandbox from any of the server's sandbox
/// providers (boat.dev accounts the server keeps the API key for). One of them is the server's default.
struct ServerTargets: View {
    @Environment(AppModel.self) private var app
    let link: ServerLink
    @State private var adding = false

    private var server: SandboxProviderHome { link.serverID.map { .server($0) } ?? .thisMac }
    private var offered: [WorkspaceLocation] { app.locations(on: server) }
    private var serverDefault: WorkspaceLocation? { app.defaultLocation(on: server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New workspaces here").font(Theme.smallMedium).foregroundStyle(Theme.text2)
                Spacer()
                if !adding {
                    Button("Add Sandbox Provider…") { withAnimation(.snappy(duration: 0.2)) { adding = true } }
                        .buttonStyle(.softCompact)
                        .disabled(!canAdd)
                        .help(canAdd ? "Add a boat.dev account to this server" : "\(link.displayName) needs to be connected to add providers")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 6)
            WorktreeRow(link: link, server: server, isDefault: serverDefault == app.worktreeLocation(on: server), showDefault: offered.count > 1)
            ForEach(app.sandboxProviders(on: server)) { p in
                Hairline().padding(.leading, 50)
                ProviderRow(provider: p, isDefault: serverDefault == .sandbox(p.id), showDefault: offered.count > 1)
            }
            if offered.isEmpty {
                Hairline().padding(.leading, 14)
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
                    Text("Nothing can run here. Turn worktrees on or add a sandbox provider.")
                        .font(Theme.small).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            if adding {
                Hairline().padding(.leading, 14)
                AddProviderForm(home: addHome, onDone: { withAnimation(.snappy(duration: 0.2)) { adding = false } })
            }
        }
    }

    /// This Mac's server when it runs (else this Mac's Keychain); a remote server once it's connected.
    private var addHome: SandboxProviderHome? {
        if link.isLocal { return link.isEnabled ? .thisMac : nil }
        return server
    }

    private var canAdd: Bool { link.isLocal || link.isConnected }
}

/// "Default" when it's what the server makes, else a button to make it so.
private struct DefaultMark: View {
    let isDefault: Bool
    let makeDefault: () -> Void

    var body: some View {
        if isDefault {
            Text("Default")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Theme.hover, in: Capsule())
                .help("New workspaces on this server start here")
        } else {
            Button("Make Default", action: makeDefault).buttonStyle(.softCompact)
        }
    }
}

/// Git worktrees on the server's own disk, with the switch to turn them off.
private struct WorktreeRow: View {
    @Environment(AppModel.self) private var app
    let link: ServerLink
    let server: SandboxProviderHome
    let isDefault: Bool
    let showDefault: Bool

    private var enabled: Bool { app.settings.preferences(for: server).worktrees }

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: "arrow.triangle.branch", tint: enabled ? .orange : .gray, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktrees").font(Theme.uiMedium).foregroundStyle(enabled ? Theme.text : Theme.text3)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 12)
            if enabled, showDefault {
                DefaultMark(isDefault: isDefault) { app.makeServerDefault(app.worktreeLocation(on: server)) }
            }
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { on in app.updateServerPreferences(server) { $0.worktrees = on } }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .help(enabled ? "Stop offering worktrees on \(link.displayName). Existing ones keep working" : "Offer worktrees on \(link.displayName)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        guard enabled else { return "Off: new workspaces here are sandboxes only" }
        if link.isLocal { return "A git worktree on this Mac, the stack running locally" }
        return link.isConnected ? "A git worktree on \(link.displayName), driven over the Domestique protocol" : "\(link.displayName) is offline"
    }
}

/// What the provider's account looks like right now (checked when the card appears).
private struct AccountState: Equatable {
    var checking = false
    var signedIn = false
    var summary: String?
    var error: String?
    var machineTypes: [BoatLimits.MachineType] = []
}

private struct ProviderRow: View {
    @Environment(AppModel.self) private var app
    let provider: SandboxProviderConfig
    let isDefault: Bool
    let showDefault: Bool
    @State private var editing = false
    @State private var confirmRemove = false
    @State private var account = AccountState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = account.error, !account.checking {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
                    Text(error).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 50)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
            }
            if editing {
                Hairline().padding(.leading, 50)
                facts.padding(.leading, 36)
                Hairline().padding(.leading, 50)
                ProviderEditor(provider: provider, machineTypes: account.machineTypes, onChangedKey: { Task { await check() } })
                    .padding(.leading, 36)
            }
        }
        .task(id: checkKey) { await check() }
        .confirmationDialog("Remove \(provider.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await app.removeSandboxProvider(provider) } }
        } message: {
            Text(app.activeWorkspaces(on: provider).isEmpty
                ? (provider.home.map { "It's removed from \(app.serverName(for: $0)) with its API key. Sandboxes it created stay on boat.dev." }
                    ?? "Its saved API key is deleted from your Keychain. Sandboxes it created stay on boat.dev.")
                : "Archive its \(app.activeWorkspaces(on: provider).count) workspace(s) first.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BoatTile(size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(Theme.uiMedium).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 12)
            pill
            if showDefault { DefaultMark(isDefault: isDefault) { app.makeServerDefault(.sandbox(provider.id)) } }
            Button(editing ? "Done" : "Edit") { withAnimation(.snappy(duration: 0.2)) { editing.toggle() } }
                .buttonStyle(.softCompact)
            Menu {
                Button("Check Account") { Task { await check() } }
                Button("Open boat.dev Dashboard") { app.cloud.openDashboard() }
                Button("Connect Claude / ChatGPT on boat.dev") { NSWorkspace.shared.open(BoatClient.agentsSetupURL) }
                Divider()
                Button("Remove…", role: .destructive) { confirmRemove = true }
                    .disabled(provider.serverStatus?.fromConfig == true)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Re-check when the key's location or the server's connection changes.
    private var checkKey: String {
        let connected = provider.home.flatMap { app.link(for: $0)?.isConnected } ?? true
        return "\(provider.credentialAccount)|\(provider.serverStatus?.credentialSource ?? "-")|\(connected)"
    }

    /// "alex@… · boat CLI login · 2 boxes, 75 new/day…", else how it would sign in.
    private var subtitle: String {
        if let s = account.summary { return s }
        if provider.home != nil { return "boat.dev · \(Self.serverKeyLabel(provider.serverStatus))" }
        guard let cred = BoatClient.credential(account: provider.credentialAccount) else { return "boat.dev · not signed in" }
        return "boat.dev · \(cred.source.label)"
    }

    /// Where a server keeps the provider's key, in words.
    static func serverKeyLabel(_ s: SandboxProviderServerStatus?) -> String {
        switch s?.credentialSource {
        case "stored": "API key saved on the server"
        case "config": "API key from server.toml"
        case "environment": "BOAT_API_KEY on the server"
        case "cli": "the server's boat login"
        default: "no API key on the server"
        }
    }

    private var pill: some View {
        let (label, color): (String, Color) =
            account.checking ? ("Checking", Theme.running)
            : account.signedIn ? ("Signed in", Theme.added)
            : ("Not signed in", Theme.warning)
        return HStack(spacing: 5) {
            if account.checking { ProgressView().controlSize(.mini) } else { Circle().fill(color).frame(width: 6, height: 6) }
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var facts: some View {
        HStack(spacing: 0) {
            ProviderFact(label: "Machine", value: MachineSize.label(provider.boat.machineType, short: true))
            ProviderFact(label: "Auto-stop", value: provider.boat.autoStopMinutes.map { "After \(MachineBadge.duration($0))" } ?? "Never")
            ProviderFact(label: "Environment", value: provider.boat.environment ?? "Default")
            ProviderFact(label: "Snapshot", value: provider.boat.fromSnapshot ?? "None")
            ProviderFact(label: "Workspaces", value: "\(app.activeWorkspaces(on: provider).count)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func check() async {
        app.cloud.refreshCredentialState()
        let acct = provider.credentialAccount
        let source: String
        if let home = provider.home {
            guard app.link(for: home)?.isConnected == true else {
                account = AccountState(error: "\(app.serverName(for: home)) isn't connected. Its providers work again once it is.")
                return
            }
            guard provider.serverStatus?.hasKey == true else {
                account = AccountState(error: "No API key on \(app.serverName(for: home)). Paste one with Edit, or set BOAT_API_KEY / run boat login on that machine.")
                return
            }
            source = Self.serverKeyLabel(provider.serverStatus)
        } else {
            guard let cred = BoatClient.credential(account: acct) else {
                account = AccountState(error: "Not signed in. Paste an API key with Edit, or run boat login in a terminal.")
                return
            }
            source = cred.source.label
        }
        account.checking = true
        let client = BoatClient.client(account: acct)
        do {
            let me = try await client.me()
            let limits = try? await client.limits()
            let who = me.email ?? me.login ?? me.displayName
            account = AccountState(
                signedIn: true,
                summary: [who, source, limits?.trialLine ?? limits?.accessTier].compactMap { $0 }.joined(separator: " · "),
                machineTypes: limits?.machineTypes ?? [])
        } catch {
            account = AccountState(error: error.localizedDescription)
        }
    }
}

private struct ProviderFact: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.text3)
            Text(value).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail).help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MachineSize {
    static let all = ["small", "default", "large", "xlarge"]

    static func label(_ t: String, short: Bool = false) -> String {
        switch (t, short) {
        case ("small", true): "Small"
        case ("default", true): "Medium"
        case ("large", true): "Large"
        case ("xlarge", true): "XL"
        case ("small", false): "Small · 2 vCPU, 4 GB"
        case ("default", false): "Medium · 4 vCPU, 8 GB"
        case ("large", false): "Large · 8 vCPU, 16 GB"
        case ("xlarge", false): "XL · 16 vCPU, 32 GB"
        default: t
        }
    }
}

// MARK: - Editing

/// One provider's name, credentials and defaults for new workspaces. Changes save as you go.
private struct ProviderEditor: View {
    @Environment(AppModel.self) private var app
    let provider: SandboxProviderConfig
    let machineTypes: [BoatLimits.MachineType]
    let onChangedKey: () -> Void
    @State private var apiKey = ""

    private func binding<T>(_ path: WritableKeyPath<SandboxProviderConfig, T>) -> Binding<T> {
        Binding(
            get: { (app.settings.sandboxProviders.first { $0.id == provider.id } ?? provider)[keyPath: path] },
            set: { v in
                var p = app.settings.sandboxProviders.first { $0.id == provider.id } ?? provider
                p[keyPath: path] = v
                app.updateSandboxProvider(p)
            })
    }

    /// Set in the server's server.toml: only this Mac's own preferences can change here.
    private var readOnly: Bool { provider.serverStatus?.fromConfig == true }

    private var hasOwnKey: Bool {
        if provider.home != nil { return provider.serverStatus?.credentialSource == "stored" }
        return BoatClient.credential(account: provider.credentialAccount)?.source == .keychain
    }

    private var keySubtitle: String {
        if let home = provider.home {
            let server = app.serverName(for: home)
            return hasOwnKey
                ? "Saved on \(server). It never leaves that machine"
                : "Optional: without one, \(server) uses its BOAT_API_KEY or boat login session"
        }
        return hasOwnKey ? "Saved in your Keychain" : "Optional: without one, uses your boat login session (or BOAT_API_KEY)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if readOnly {
                SettingsRow(title: "Set in server.toml", subtitle: "Change this provider's name, key and defaults in that server's config file") {
                    EmptyView()
                }
            }
            SettingsRow(title: "Name", subtitle: "Shown in the sidebar and \"New workspace on…\"") {
                TextField("boat.dev", text: binding(\.name)).modifier(FieldStyle()).disabled(readOnly)
            }
            if !readOnly {
                SettingsRow(title: "API key", subtitle: keySubtitle) {
                    HStack(spacing: 6) {
                        SecureField(hasOwnKey ? "Replace key…" : "boat_…", text: $apiKey).modifier(FieldStyle())
                        Button("Save") {
                            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            apiKey = ""
                            Task {
                                await app.setSandboxProviderKey(provider, apiKey: key)
                                onChangedKey()
                            }
                        }
                        .buttonStyle(.softCompact)
                        .disabled(apiKey.isEmpty)
                        if hasOwnKey {
                            Button("Forget") {
                                Task {
                                    await app.setSandboxProviderKey(provider, apiKey: "")
                                    onChangedKey()
                                }
                            }
                            .buttonStyle(.softDestructive)
                        }
                    }
                }
            }
            SettingsRow(title: "Machine size") {
                Picker("", selection: binding(\.boat.machineType)) {
                    ForEach(MachineSize.all, id: \.self) { t in
                        Text(MachineSize.label(t)).tag(t)
                            .disabled(machineTypes.first { $0.type == t }?.available == false)
                    }
                }
                .labelsHidden().fixedSize()
                .disabled(readOnly)
            }
            SettingsRow(title: "Auto-stop", subtitle: "Stopped sandboxes don't bill; they resume with their disk when you use them") {
                Picker("", selection: binding(\.boat.autoStopMinutes)) {
                    ForEach([30, 60, 120, 240, 480, 1440], id: \.self) { Text("After \(MachineBadge.duration($0))").tag(Optional($0)) }
                    Text("Never").tag(Int?.none)
                }
                .labelsHidden().fixedSize()
                .disabled(readOnly)
            }
            SettingsRow(title: "Environment", subtitle: "Named boat environment (repos, secrets, AI logins). Empty = your default") {
                TextField("base", text: Binding(
                    get: { binding(\.boat.environment).wrappedValue ?? "" },
                    set: { binding(\.boat.environment).wrappedValue = $0.isEmpty ? nil : $0 }
                ))
                .modifier(FieldStyle())
                .disabled(readOnly)
            }
            SettingsRow(title: "Start from snapshot", subtitle: "A boat saved snapshot with your toolchains installed (boat snapshot <id> <name>). Empty = a fresh machine") {
                TextField("stride", text: Binding(
                    get: { binding(\.boat.fromSnapshot).wrappedValue ?? "" },
                    set: { binding(\.boat.fromSnapshot).wrappedValue = $0.isEmpty ? nil : $0 }
                ))
                .modifier(FieldStyle())
                .disabled(readOnly)
            }
            SettingsRow(title: "Share my GitHub login", subtitle: "If boat.dev's GitHub app can't clone a repo, give the sandbox your gh token") {
                Toggle("", isOn: binding(\.boat.shareGitHubToken)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsRow(title: "Forward ports automatically", subtitle: "Every port the stack or agent listens on appears on the same localhost port") {
                Toggle("", isOn: binding(\.boat.autoForwardPorts)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsRow(title: "Delete sandbox on archive", subtitle: "Off: archiving stops it (kept 14 days). Deleting a workspace always deletes it") {
                Toggle("", isOn: binding(\.boat.deleteOnArchive)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(readOnly)
            }
        }
    }
}

/// A new boat.dev provider on one server (`home` nil = this Mac's Keychain, when This Mac has no server).
private struct AddProviderForm: View {
    @Environment(AppModel.self) private var app
    let home: SandboxProviderHome?
    let onDone: () -> Void
    @State private var name = ""
    @State private var apiKey = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Service") {
                HStack(spacing: 6) {
                    BoatMark().fill(BoatMark.brandBlue).aspectRatio(BoatMark.aspectRatio, contentMode: .fit).frame(height: 13)
                    Text("boat.dev").font(Theme.ui).foregroundStyle(Theme.text)
                }
            }
            SettingsRow(title: "Name", subtitle: "Shown in \"New workspace on…\" under this server") {
                TextField(defaultName, text: $name).modifier(FieldStyle())
            }
            SettingsRow(
                title: "API key",
                subtitle: home == nil
                    ? "boat.dev → Dashboard → API keys. Leave empty to use your boat login session"
                    : "boat.dev → Dashboard → API keys. Saved on that server only. Leave empty to use its BOAT_API_KEY or boat login"
            ) {
                SecureField("boat_…", text: $apiKey).modifier(FieldStyle())
            }
            SettingsRow(title: "") {
                HStack(spacing: 6) {
                    Button("Cancel", action: onDone).buttonStyle(.softCompact)
                    Button(saving ? "Adding…" : "Add Sandbox Provider") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        saving = true
                        Task {
                            await app.addSandboxProvider(
                                name: n.isEmpty ? defaultName : n,
                                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
                            saving = false
                            onDone()
                        }
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true, compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
                }
            }
            Text("One provider per boat.dev account or team, or several for one account with different defaults (e.g. a \"large\" one for heavy repos).")
                .font(Theme.small).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 12)
        }
    }

    /// "boat.dev", then "boat.dev 2", …
    private var defaultName: String {
        let used = Set(app.settings.sandboxProviders.map(\.name))
        if !used.contains("boat.dev") { return "boat.dev" }
        return (2...).lazy.map { "boat.dev \($0)" }.first { !used.contains($0) }!
    }
}
