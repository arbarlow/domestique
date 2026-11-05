import AppKit
import DQCore
import Foundation
import HostKit
import Observation

/// Live status and lifecycle actions for every workspace's cloud machine.
///
/// Polls boat.dev for each non-archived remote workspace: every few seconds while a machine is
/// starting/stopping or on screen, every 30s otherwise. `BoatHost.prepare()` also reports here, so
/// a resume triggered by sending a message shows up immediately.
@MainActor
@Observable
final class CloudMachines {
    @ObservationIgnored unowned let app: AppModel

    /// machine id -> last known sandbox.
    private(set) var status: [String: BoatSandbox] = [:]
    /// machine id -> action in flight ("Stopping…").
    private(set) var busy: [String: String] = [:]
    /// machine id -> last error from an action or poll.
    var errors: [String: String] = [:]
    /// Whether a boat.dev credential is available (refreshed from Settings).
    private(set) var boatConfigured = BoatClient.isConfigured

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var observed: Set<String> = []
    @ObservationIgnored private var lastPoll: [String: Date] = [:]

    init(app: AppModel) {
        self.app = app
        startPolling()
    }

    func refreshCredentialState() { boatConfigured = BoatClient.isConfigured }

    func sandbox(for ws: Workspace) -> BoatSandbox? { ws.host.flatMap { status[$0.machineID] } }
    func phase(for ws: Workspace) -> BoatPhase? { sandbox(for: ws)?.phase }

    /// Hook the host so prepare() (resume on send) updates the UI live.
    func observe(_ host: BoatHost) {
        guard observed.insert(host.machineID).inserted else { return }
        Task {
            await host.setObserver { [weak self] s in
                Task { @MainActor in self?.update(s) }
            }
        }
    }

    private func update(_ s: BoatSandbox) {
        if status[s.id] != s { status[s.id] = s }
        if s.phase == .running { errors[s.id] = nil }
    }

    // MARK: polling

    private var remoteWorkspaces: [Workspace] {
        app.state.workspaces.filter { !$0.isArchived && $0.host != nil }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollDue()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollDue() async {
        let now = Date()
        for ws in remoteWorkspaces {
            guard let h = ws.host, h.provider == .boat else { continue }
            let id = h.machineID
            observe(Hosts.boatHost(id))
            let s = status[id]
            let selected = app.selectedWorkspaceID == ws.id
            let fast = s == nil || s!.phase.isTransitional || busy[id] != nil
            let interval: TimeInterval = fast ? 3 : (selected ? 10 : 30)
            if let last = lastPoll[id], now.timeIntervalSince(last) < interval { continue }
            lastPoll[id] = now
            await poll(id)
        }
    }

    func poll(_ id: String) async {
        guard BoatClient.isConfigured else { return }
        do {
            let s = try await BoatClient.shared.sandbox(id)
            update(s)
            if s.phase != .running {
                // Stopped under us (auto-stop): make the next command go through prepare() again.
                await Hosts.boatHost(id).invalidate()
            }
        } catch let e as BoatAPIError where e.status == 404 {
            status[id] = BoatSandbox(id: id, state: "cancelled", error: "Deleted on boat.dev")
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    // MARK: actions

    private func run(_ ws: Workspace, _ label: String, _ body: @escaping (String) async throws -> Void) {
        guard let id = ws.host?.machineID else { return }
        busy[id] = label
        errors[id] = nil
        Task {
            do {
                try await body(id)
            } catch {
                self.errors[id] = error.localizedDescription
            }
            self.busy[id] = nil
            self.lastPoll[id] = nil
            await self.poll(id)
        }
    }

    func stop(_ ws: Workspace) {
        // Stop what runs on it first so nothing reconnects (and resumes it) right away.
        if let m = app.existingModel(for: ws.id) { m.machineWillStop() }
        run(ws, "Stopping…") { id in
            await Hosts.boatHost(id).disconnect()
            try await BoatClient.shared.stop(id)
        }
    }

    func resume(_ ws: Workspace) {
        run(ws, "Starting…") { id in
            try await Hosts.boatHost(id).prepare()
            await self.app.existingModel(for: ws.id)?.machineDidStart()
        }
    }

    /// Restart a machine that stopped answering (disk untouched).
    func recover(_ ws: Workspace) {
        run(ws, "Recovering…") { id in
            await Hosts.boatHost(id).disconnect()
            try await BoatClient.shared.recover(id)
            _ = try await BoatClient.shared.waitUntilRunning(id)
        }
    }

    /// Push the auto-stop deadline to now + `minutes`; nil = keep running until stopped.
    func setAutoStop(_ ws: Workspace, minutes: Int?) {
        run(ws, minutes == nil ? "Turning off auto-stop…" : "Extending…") { id in
            try await BoatClient.shared.setAutoStop(id, ttlSeconds: minutes.map { $0 * 60 })
        }
    }

    func openDesktop(_ ws: Workspace) {
        run(ws, "Opening desktop…") { id in
            try await Hosts.boatHost(id).prepare()
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let url = try await BoatClient.shared.desktopURL(id, dark: dark)
            NSWorkspace.shared.open(url)
        }
    }

    /// Copies a stable HTTPS URL for a port (private = carries an access token).
    func copyHostedURL(_ ws: Workspace, port: Int, isPublic: Bool) {
        run(ws, "Getting URL…") { id in
            let url = try await BoatClient.shared.hostedURL(id, port: port, public: isPublic, title: ws.name)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            self.app.toast = "Copied \(isPublic ? "public" : "private") URL for :\(port)"
        }
    }

    func openDashboard() { NSWorkspace.shared.open(BoatClient.dashboardURL) }

    func copySSHCommand(_ ws: Workspace) {
        guard let id = ws.host?.machineID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("boat ssh \(id)", forType: .string)
        app.toast = "Copied `boat ssh \(id)`"
    }

    func label(for ws: Workspace) -> String {
        guard let id = ws.host?.machineID else { return "" }
        if let b = busy[id] { return b }
        guard let s = status[id] else { return "Connecting…" }
        return s.phase.label
    }

    /// "1h 12m left" while running with auto-stop on.
    func autoStopText(for ws: Workspace, now: Date = .now) -> String? {
        guard let s = sandbox(for: ws), s.phase == .running else { return nil }
        guard let at = s.archiveAfter else { return "Always on" }
        let secs = max(0, Int(at.timeIntervalSince(now)))
        if secs < 60 { return "stops in <1m" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        return h > 0 ? "stops in \(h)h \(m)m" : "stops in \(m)m"
    }

    func minutesLeft(for ws: Workspace, now: Date = .now) -> Int? {
        guard let s = sandbox(for: ws), s.phase == .running, let at = s.archiveAfter else { return nil }
        return max(0, Int(at.timeIntervalSince(now)) / 60)
    }
}
