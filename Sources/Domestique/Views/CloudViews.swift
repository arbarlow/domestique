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
        // boat.dev's mark, tinted by machine state (running green, stopped grey, …).
        BoatMark()
            .fill(phase?.color ?? Theme.text3)
            .opacity(phase == .stopped || phase == .gone ? 0.55 : 1)
            .aspectRatio(BoatMark.aspectRatio, contentMode: .fit)
            .frame(height: size)
            .help("\(app.settings.provider(for: workspace.host)?.name ?? "boat.dev") · \(app.cloud.label(for: workspace))")
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
            Section("\(app.settings.provider(for: workspace.host)?.name ?? "boat.dev") · \(id)") {
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
                    Button("Archive") { Task { await app.archive(workspace) } }
                        .buttonStyle(.softCompact)
                        .disabled(app.archiving.contains(workspace.id))
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
