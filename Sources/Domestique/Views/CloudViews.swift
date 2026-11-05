import DQCore
import HostKit
import SwiftUI

// MARK: - Status colours

extension BoatPhase {
    var color: Color {
        switch self {
        case .running: Theme.added
        case .starting, .stopping: Theme.warning
        case .stopped, .gone: Theme.text3
        case .error: Theme.removed
        }
    }
}

/// Small cloud glyph tinted by the machine's state (sidebar rows, headers).
struct MachineGlyph: View {
    @Environment(AppModel.self) private var app
    let workspace: Workspace
    var size: CGFloat = 10

    var body: some View {
        let phase = app.cloud.phase(for: workspace)
        Image(systemName: phase == .stopped || phase == .gone ? "cloud" : "cloud.fill")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(phase?.color ?? Theme.text3)
            .help("\(workspace.host?.provider.displayName ?? "Cloud") · \(app.cloud.label(for: workspace))")
    }
}

// MARK: - Header badge

/// "☁ boat · Running · stops in 1h 12m ▾": status plus everything you can do with the machine.
struct MachineBadge: View {
    @Environment(AppModel.self) private var app
    let model: WorkspaceModel
    let workspace: Workspace

    var body: some View {
        let cloud = app.cloud!
        let id = workspace.host?.machineID ?? ""
        let phase = cloud.phase(for: workspace)
        let busy = cloud.busy[id] != nil
        Menu {
            Section("\(workspace.host?.provider.displayName ?? "Cloud") · \(id)") {
                if let s = cloud.sandbox(for: workspace) {
                    Text(specLine(s))
                }
            }
            if phase == .running {
                Button("Open desktop", systemImage: "display") { cloud.openDesktop(workspace) }
                Button("New terminal on sandbox", systemImage: "terminal") { model.newTerminal() }
                Divider()
                PortsMenuContent(model: model, workspace: workspace)
                Divider()
                Menu("Auto-stop") {
                    ForEach([30, 60, 120, 240, 480, 1440], id: \.self) { m in
                        Button("Stop in \(Self.duration(m))") { cloud.setAutoStop(workspace, minutes: m) }
                    }
                    Divider()
                    Button("Keep running until I stop it") { cloud.setAutoStop(workspace, minutes: nil) }
                }
                Button("Stop sandbox", systemImage: "stop.circle") { cloud.stop(workspace) }
            } else if phase == .stopped || phase == .error {
                Button("Start sandbox", systemImage: "play.circle") { cloud.resume(workspace) }
                if phase == .error {
                    Button("Recover (restart the machine)", systemImage: "arrow.clockwise") { cloud.recover(workspace) }
                }
            }
            Divider()
            Button("Copy SSH command") { cloud.copySSHCommand(workspace) }
            Button("Open boat.dev dashboard") { cloud.openDashboard() }
        } label: {
            HStack(spacing: 6) {
                if busy || phase?.isTransitional == true {
                    Spinner(size: 10)
                } else {
                    Circle().fill(phase?.color ?? Theme.text3).frame(width: 6, height: 6)
                }
                Image(systemName: "cloud.fill").font(.system(size: 10)).foregroundStyle(Theme.text2)
                Text(cloud.label(for: workspace))
                    .font(Theme.small)
                    .foregroundStyle(Theme.text)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    if !busy, let left = cloud.autoStopText(for: workspace, now: ctx.date) {
                        Text(left)
                            .font(Theme.small.monospacedDigit())
                            .foregroundStyle((cloud.minutesLeft(for: workspace, now: ctx.date) ?? 99) < 10 ? Theme.warning : Theme.text3)
                    }
                }
                let forwarded = model.forwards.count
                if forwarded > 0 {
                    Text("⇄ \(forwarded)")
                        .font(Theme.small.monospacedDigit())
                        .foregroundStyle(Theme.text2)
                        .help("\(forwarded) port\(forwarded == 1 ? "" : "s") forwarded to this Mac")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Theme.hover, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(workspace.host?.provider.displayName ?? "Cloud") sandbox \(id)")
    }

    private func specLine(_ s: BoatSandbox) -> String {
        var parts = [s.phase.label]
        if let t = s.type { parts.append(t == "default" ? "medium" : t) }
        if let c = s.vcpu, let m = s.memoryGB { parts.append("\(c) vCPU · \(m) GB") }
        if s.health == "degraded" { parts.append("degraded") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Port rows for menus: open locally, toggle forwarding, copy a boat.dev HTTPS URL.
struct PortsMenuContent: View {
    @Environment(AppModel.self) private var app
    let model: WorkspaceModel
    let workspace: Workspace

    var body: some View {
        let ports = Array(Set(model.forwardablePorts + model.forwards.keys)).sorted()
        if ports.isEmpty {
            Text("No ports listening yet")
        } else {
            Section("Ports") {
                ForEach(ports, id: \.self) { port in
                    Menu(title(port)) {
                        if let local = model.forwards[port] {
                            Button("Open http://localhost:\(local)") {
                                NSWorkspace.shared.open(URL(string: "http://localhost:\(local)")!)
                            }
                            Button("Stop forwarding") { model.setForwarding(port, enabled: false) }
                        } else {
                            Button("Forward to this Mac") { model.setForwarding(port, enabled: true) }
                        }
                        Divider()
                        Button("Copy private HTTPS URL") { app.cloud.copyHostedURL(workspace, port: port, isPublic: false) }
                        Button("Copy public HTTPS URL") { app.cloud.copyHostedURL(workspace, port: port, isPublic: true) }
                    }
                }
            }
        }
    }

    private func title(_ port: Int) -> String {
        let owner = model.supervisor.flatMap { s in
            (s.runs + s.adhocRuns).first { $0.ports.contains(port) }?.name
        }
        let name = owner.map { "\($0) · " } ?? ""
        if let local = model.forwards[port] {
            return local == port ? "\(name):\(port)  ⇄ localhost" : "\(name):\(port)  ⇄ localhost:\(local)"
        }
        if let err = model.forwardErrors[port] { return "\(name):\(port)  (\(err.prefix(40)))" }
        return "\(name):\(port)  not forwarded"
    }
}

// MARK: - Banner

/// Under the tab bar: the machine is stopped / failing / about to auto-stop.
struct MachineBanner: View {
    @Environment(AppModel.self) private var app
    let workspace: Workspace

    var body: some View {
        let cloud = app.cloud!
        let id = workspace.host?.machineID ?? ""
        let phase = cloud.phase(for: workspace)
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let error = cloud.errors[id], cloud.busy[id] == nil {
                bar(icon: "exclamationmark.triangle.fill", tint: Theme.warning, text: error) {
                    Button("Retry") { cloud.resume(workspace) }.buttonStyle(.softCompact)
                    Button("Dismiss") { cloud.errors[id] = nil }.buttonStyle(.softCompact)
                }
            } else if phase == .stopped, cloud.busy[id] == nil {
                bar(
                    icon: "moon.zzz.fill", tint: Theme.text2,
                    text: "This sandbox is stopped and not billing. Its disk is kept; sending a message, running the stack or opening a terminal starts it again."
                ) {
                    Button("Start now") { cloud.resume(workspace) }.buttonStyle(.softCompact)
                }
            } else if phase == .gone {
                bar(icon: "trash", tint: Theme.removed, text: "This sandbox was deleted on boat.dev. Archive the workspace.") {
                    Button("Archive") { Task { await app.archive(workspace) } }.buttonStyle(.softCompact)
                }
            } else if let left = cloud.minutesLeft(for: workspace, now: ctx.date), left < 10, cloud.busy[id] == nil {
                bar(icon: "timer", tint: Theme.warning, text: "Auto-stop in \(max(left, 1)) min. Running agents, tasks and terminals will stop with it.") {
                    Button("+1 hour") { cloud.setAutoStop(workspace, minutes: left + 60) }.buttonStyle(.softCompact)
                    Button("Keep running") { cloud.setAutoStop(workspace, minutes: nil) }.buttonStyle(.softCompact)
                }
            }
        }
    }

    private func bar<Actions: View>(icon: String, tint: Color, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            Text(text).font(Theme.small).foregroundStyle(Theme.text2).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

// MARK: - Settings

struct CloudSettings: View {
    @Environment(AppModel.self) private var app
    @State private var apiKey = ""
    @State private var account: String?
    @State private var plan: String?
    @State private var checkError: String?
    @State private var checking = false
    @State private var machineTypes: [BoatLimits.MachineType] = []

    var body: some View {
        @Bindable var app = app
        let boat = Binding(get: { app.settings.boat }, set: { app.settings.boat = $0 })
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cloud").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Run workspaces on a cloud machine instead of this Mac. Each workspace gets its own sandbox with the repo cloned, your stack running there, and its ports forwarded to localhost.")
                    .font(Theme.ui).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 22)

            SettingsSection(
                title: "boat.dev",
                footer: "Domestique uses your boat CLI login when there is one (`boat login`), or an API key from boat.dev → Dashboard → API keys. The key is stored in your Keychain."
            ) {
                SettingsRow(title: "Account", subtitle: connectionSubtitle) {
                    HStack(spacing: 6) {
                        if checking { Spinner(size: 11) }
                        Button("Check") { Task { await check() } }.buttonStyle(.softCompact)
                    }
                }
                SettingsRow(title: "API key", subtitle: BoatClient.credential()?.source == .keychain ? "Saved in Keychain" : "Optional when the boat CLI is signed in") {
                    HStack(spacing: 6) {
                        SecureField("boat_…", text: $apiKey)
                            .textFieldStyle(.plain).font(Theme.ui)
                            .padding(.horizontal, 8).frame(width: 180, height: 26)
                            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 6))
                        Button("Save") {
                            BoatClient.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            apiKey = ""
                            app.cloud.refreshCredentialState()
                            Task { await check() }
                        }
                        .buttonStyle(.softCompact)
                        .disabled(apiKey.isEmpty)
                        if BoatClient.credential()?.source == .keychain {
                            Button("Remove") {
                                BoatClient.saveAPIKey(nil)
                                app.cloud.refreshCredentialState()
                                Task { await check() }
                            }
                            .buttonStyle(.softCompact)
                        }
                    }
                }
                SettingsRow(title: "Dashboard", subtitle: "Agents & Proxying: connect the Claude / ChatGPT accounts sandboxes use") {
                    HStack(spacing: 6) {
                        Button("Agents") { NSWorkspace.shared.open(BoatClient.agentsSetupURL) }.buttonStyle(.softCompact)
                        Button("Open") { app.cloud.openDashboard() }.buttonStyle(.softCompact)
                    }
                }
            }

            SettingsSection(title: "New boat.dev workspaces") {
                SettingsRow(title: "Machine size") {
                    Picker("", selection: boat.machineType) {
                        ForEach(["small", "default", "large", "xlarge"], id: \.self) { t in
                            Text(Self.sizeLabel(t)).tag(t)
                                .disabled(machineTypes.first { $0.type == t }?.available == false)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Auto-stop", subtitle: "Stopped sandboxes don't bill; they resume with their disk when you use them") {
                    Picker("", selection: boat.autoStopMinutes) {
                        ForEach([30, 60, 120, 240, 480, 1440], id: \.self) { Text("After \(MachineBadge.duration($0))").tag(Optional($0)) }
                        Text("Never").tag(Int?.none)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Environment", subtitle: "Named boat environment (repos, secrets, AI logins). Empty = your default") {
                    TextField("base", text: Binding(get: { boat.wrappedValue.environment ?? "" }, set: { boat.wrappedValue.environment = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.plain).font(Theme.ui)
                        .padding(.horizontal, 8).frame(width: 220, height: 26)
                        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 6))
                }
                SettingsRow(title: "Share my GitHub login", subtitle: "If boat.dev's GitHub app can't clone a repo, give the sandbox your `gh` token") {
                    Toggle("", isOn: boat.shareGitHubToken).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "Forward ports automatically", subtitle: "Every port the stack or agent listens on appears on the same localhost port") {
                    Toggle("", isOn: boat.autoForwardPorts).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "Delete sandbox on archive", subtitle: "Off: archiving stops it (kept 14 days). Deleting a workspace always deletes it") {
                    Toggle("", isOn: boat.deleteOnArchive).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
        .task { await check() }
    }

    private var connectionSubtitle: String {
        if let checkError { return checkError }
        guard let cred = BoatClient.credential() else { return "Not connected" }
        var s = account.map { "\($0) · " } ?? ""
        s += cred.source.label
        if let plan { s += " · \(plan)" }
        return s
    }

    private func check() async {
        app.cloud.refreshCredentialState()
        guard BoatClient.isConfigured else {
            account = nil
            plan = nil
            checkError = "Not connected. Run `boat login` in a terminal, or paste an API key."
            return
        }
        checking = true
        defer { checking = false }
        do {
            let me = try await BoatClient.shared.me()
            account = me.email ?? me.login ?? me.displayName
            let limits = try? await BoatClient.shared.limits()
            plan = limits?.trialLine ?? limits?.accessTier
            machineTypes = limits?.machineTypes ?? []
            checkError = nil
        } catch {
            checkError = error.localizedDescription
        }
    }

    static func sizeLabel(_ t: String) -> String {
        switch t {
        case "small": "Small · 2 vCPU, 4 GB"
        case "default": "Medium · 4 vCPU, 8 GB"
        case "large": "Large · 8 vCPU, 16 GB"
        case "xlarge": "XL · 16 vCPU, 32 GB"
        default: t
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.small)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
