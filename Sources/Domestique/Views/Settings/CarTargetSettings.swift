import DQCore
import HostKit
import SwiftUI

/// Settings → Sandbox Providers: accounts on sandbox services (boat.dev today) that new workspaces can
/// run on. Several can exist: separate accounts or teams, or presets like "boat · large".
struct SandboxProviderSettings: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(
                title: "Sandbox Providers",
                subtitle: "Run workspaces in a cloud sandbox instead of on this Mac. Each workspace gets its own machine with the repo cloned, your stack running there, and its ports forwarded to localhost. Providers belong to a Team Car, which keeps the API key and starts the sandboxes."
            ) {
                if !adding {
                    Button("Add Provider…") { withAnimation(.snappy(duration: 0.2)) { adding = true } }
                        .buttonStyle(.softCompact)
                }
            }
            if adding {
                AddProviderForm(onDone: { withAnimation(.snappy(duration: 0.2)) { adding = false } })
            }
            if app.settings.sandboxProviders.isEmpty, !adding {
                EmptyProviders(onAdd: { withAnimation(.snappy(duration: 0.2)) { adding = true } })
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups, id: \.title) { g in
                    if groups.count > 1 || g.home != nil {
                        Text(g.title).font(Theme.smallMedium).foregroundStyle(Theme.text3).padding(.top, 4)
                    }
                    ForEach(g.providers) { p in ProviderCard(provider: p) }
                }
            }
        }
    }
}

extension SandboxProviderSettings {
    struct Group {
        var home: SandboxProviderHome?
        var title: String
        var providers: [SandboxProviderConfig]
    }

    /// This Mac's car first, then each remote car in Settings order; providers not yet on a car last.
    var groups: [Group] {
        let all = app.settings.sandboxProviders
        var out: [Group] = []
        let mac = all.filter { $0.home == .thisMac }
        if !mac.isEmpty { out.append(Group(home: .thisMac, title: "On This Mac's Team Car", providers: mac)) }
        for car in app.settings.teamCars {
            let ps = all.filter { $0.remoteCarID == car.id }
            if !ps.isEmpty { out.append(Group(home: .teamCar(car.id), title: "On \(car.name)", providers: ps)) }
        }
        let local = all.filter { $0.home == nil }
        if !local.isEmpty { out.append(Group(home: nil, title: "On this Mac (Keychain)", providers: local)) }
        return out
    }
}

private struct EmptyProviders: View {
    let onAdd: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            BoatTile(size: 40)
            Text("No sandbox providers").font(Theme.uiMedium).foregroundStyle(Theme.text)
            Text("Add a boat.dev account to run workspaces in the cloud.")
                .font(Theme.small).foregroundStyle(Theme.text3)
            Button("Add boat.dev…", action: onAdd).buttonStyle(.softCompact)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - Provider card

/// What the provider's account looks like right now (checked when the card appears).
private struct AccountState: Equatable {
    var checking = false
    var signedIn = false
    var summary: String?
    var error: String?
    var machineTypes: [BoatLimits.MachineType] = []
}

private struct ProviderCard: View {
    @Environment(AppModel.self) private var app
    let provider: SandboxProviderConfig
    @State private var editing = false
    @State private var confirmRemove = false
    @State private var account = AccountState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = account.error, !account.checking {
                Hairline().padding(.leading, 14)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
                    Text(error).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Hairline().padding(.leading, 14)
            facts
            if editing {
                Hairline().padding(.leading, 14)
                ProviderEditor(provider: provider, machineTypes: account.machineTypes, onChangedKey: { Task { await check() } })
            }
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 0.5))
        .task(id: checkKey) { await check() }
        .confirmationDialog("Remove \(provider.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await app.removeSandboxProvider(provider) } }
        } message: {
            Text(app.activeWorkspaces(on: provider).isEmpty
                ? (provider.home.map { "It's removed from \(app.carName(for: $0)) with its API key. Sandboxes it created stay on boat.dev." }
                    ?? "Its saved API key is deleted from your Keychain. Sandboxes it created stay on boat.dev.")
                : "Archive its \(app.activeWorkspaces(on: provider).count) workspace(s) first.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BoatTile(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(Theme.uiMedium).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 12)
            pill
            Button(editing ? "Done" : "Edit") { withAnimation(.snappy(duration: 0.2)) { editing.toggle() } }
                .buttonStyle(.softCompact)
            Menu {
                Button("Check Account") { Task { await check() } }
                Button("Open boat.dev Dashboard") { app.cloud.openDashboard() }
                Button("Connect Claude / ChatGPT on boat.dev") { NSWorkspace.shared.open(BoatClient.agentsSetupURL) }
                Divider()
                Button("Remove…", role: .destructive) { confirmRemove = true }
                    .disabled(provider.carStatus?.fromConfig == true)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Re-check when the key's location or the car's connection changes.
    private var checkKey: String {
        let connected = provider.home.flatMap { app.link(for: $0)?.isConnected } ?? true
        return "\(provider.credentialAccount)|\(provider.carStatus?.credentialSource ?? "-")|\(connected)"
    }

    /// "alex@… · boat CLI login · 2 boxes, 75 new/day…", else how it would sign in.
    private var subtitle: String {
        if let s = account.summary { return s }
        if provider.home != nil { return "boat.dev · \(Self.carKeyLabel(provider.carStatus))" }
        guard let cred = BoatClient.credential(account: provider.credentialAccount) else { return "boat.dev · not signed in" }
        return "boat.dev · \(cred.source.label)"
    }

    /// Where a Team Car keeps the provider's key, in words.
    static func carKeyLabel(_ s: SandboxProviderCarStatus?) -> String {
        switch s?.credentialSource {
        case "stored": "API key saved on the Team Car"
        case "config": "API key from teamcar.toml"
        case "environment": "BOAT_API_KEY on the Team Car"
        case "cli": "the Team Car's boat login"
        default: "no API key on the Team Car"
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
                account = AccountState(error: "\(app.carName(for: home)) isn't connected. Its providers work again once it is.")
                return
            }
            guard provider.carStatus?.hasKey == true else {
                account = AccountState(error: "No API key on \(app.carName(for: home)). Paste one with Edit, or set BOAT_API_KEY / run boat login on that machine.")
                return
            }
            source = Self.carKeyLabel(provider.carStatus)
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

    /// Set in the car's teamcar.toml: only this Mac's own preferences can change here.
    private var readOnly: Bool { provider.carStatus?.fromConfig == true }

    private var hasOwnKey: Bool {
        if provider.home != nil { return provider.carStatus?.credentialSource == "stored" }
        return BoatClient.credential(account: provider.credentialAccount)?.source == .keychain
    }

    private var keySubtitle: String {
        if let home = provider.home {
            let car = app.carName(for: home)
            return hasOwnKey
                ? "Saved on \(car)'s Team Car. It never leaves that machine"
                : "Optional: without one, \(car) uses its BOAT_API_KEY or boat login session"
        }
        return hasOwnKey ? "Saved in your Keychain" : "Optional: without one, uses your boat login session (or BOAT_API_KEY)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if readOnly {
                SettingsRow(title: "Set in teamcar.toml", subtitle: "Change this provider's name, key and defaults in that Team Car's config file") {
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

private struct AddProviderForm: View {
    @Environment(AppModel.self) private var app
    let onDone: () -> Void
    @State private var name = ""
    @State private var apiKey = ""
    @State private var home: SandboxProviderHome?
    @State private var saving = false

    var body: some View {
        SettingsSection(
            title: "New sandbox provider",
            footer: "Use one provider per boat.dev account or team, or several for one account with different defaults (e.g. a \"large\" one for heavy repos). You can change everything later."
        ) {
            SettingsRow(title: "Service") {
                HStack(spacing: 6) {
                    BoatMark().fill(BoatMark.brandBlue).aspectRatio(BoatMark.aspectRatio, contentMode: .fit).frame(height: 13)
                    Text("boat.dev").font(Theme.ui).foregroundStyle(Theme.text)
                }
            }
            if !app.providerHomes.isEmpty {
                SettingsRow(title: "Team Car", subtitle: "The machine that keeps the key and starts its sandboxes") {
                    Picker("", selection: $home) {
                        ForEach(app.providerHomes, id: \.self) { h in Text(app.carName(for: h)).tag(Optional(h)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsRow(title: "Name", subtitle: "Shown in the sidebar and \"New workspace on…\"") {
                TextField(defaultName, text: $name).modifier(FieldStyle())
            }
            SettingsRow(
                title: "API key",
                subtitle: home == nil
                    ? "boat.dev → Dashboard → API keys. Leave empty to use your boat login session"
                    : "boat.dev → Dashboard → API keys. Saved on that Team Car only. Leave empty to use its BOAT_API_KEY or boat login"
            ) {
                SecureField("boat_…", text: $apiKey).modifier(FieldStyle())
            }
            SettingsRow(title: "") {
                HStack(spacing: 6) {
                    Button("Cancel", action: onDone).buttonStyle(.softCompact)
                    Button(saving ? "Adding…" : "Add Provider") {
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
        }
        // New providers go to This Mac's car (or the first connected one).
        .onAppear { if home == nil { home = app.providerHomes.first } }
    }

    /// "boat.dev", then "boat.dev 2", …
    private var defaultName: String {
        let used = Set(app.settings.sandboxProviders.map(\.name))
        if !used.contains("boat.dev") { return "boat.dev" }
        return (2...).lazy.map { "boat.dev \($0)" }.first { !used.contains($0) }!
    }
}
