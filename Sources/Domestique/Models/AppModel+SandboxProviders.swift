import DQCore
import Foundation
import HostKit
import ServerKit

/// Sandbox providers belong to servers. Each server keeps its providers' API keys and makes every
/// boat.dev call; the app mirrors the providers into `settings.sandboxProviders` (for the picker,
/// the sidebar and cloud workspaces) and routes `BoatClient` through the owning server.
///
/// - This Mac's server takes over the providers set up before server (`home == nil`) the first time it
///   connects: same ids, Keychain key copied over. Until then, or with `DOMESTIQUE_LEGACY_ENGINE=1`,
///   those keep using the Keychain directly.
/// - A remote server's providers appear when it connects and disappear when it drops them.
/// - Editing a provider saves it to its server (ADMIN token for remote servers).
extension AppModel {
    // MARK: routing

    /// Points `BoatClient` at the servers. Called once at launch.
    func installSandboxRouting() {
        let table = SandboxRouteTable.shared
        BoatClient.routing = SandboxRouting(
            backend: { [weak self] account in
                guard let route = table.route(account) else { return nil }
                return ServerSandboxBackend(providerID: route.providerID) { [weak self] in
                    guard let self else { throw ServerError(code: .unavailable, message: "Domestique is quitting") }
                    return try await self.serverClient(for: route.home)
                }
            },
            isConfigured: { table.route($0)?.usable ?? false })
        refreshSandboxRoutes()
    }

    /// The link of the server that owns providers at `home` (nil if that server isn't in Settings).
    func link(for home: SandboxProviderHome) -> ServerLink? {
        switch home {
        case .thisMac: server
        case .server(let id): remoteServers[id]
        }
    }

    func serverClient(for home: SandboxProviderHome) async throws -> ServerClient {
        guard let link = link(for: home) else {
            throw ServerError(code: .unavailable, message: "That server isn't in Settings → Servers any more.")
        }
        return try await link.ready()
    }

    func serverName(for home: SandboxProviderHome) -> String {
        switch home {
        case .thisMac: "This Mac"
        case .server(let id): settings.servers.first { $0.id == id }?.name ?? "Missing server"
        }
    }

    /// Rebuilds the route table from settings and connection state.
    func refreshSandboxRoutes() {
        var routes: [String: SandboxRouteTable.Route] = [:]
        for p in settings.sandboxProviders {
            guard let home = p.home else { continue }
            // With the in-app engine, This Mac's server isn't running: keep using the Keychain.
            if home == .thisMac, server?.isEnabled != true { continue }
            let usable = link(for: home)?.isConnected == true && (p.serverStatus?.hasKey ?? false)
            routes[p.credentialAccount] = .init(providerID: p.id.uuidString.lowercased(), home: home, usable: usable)
        }
        SandboxRouteTable.shared.set(routes)
        cloud?.refreshCredentialState()
    }

    /// ServerLink calls this on every status change.
    func serverStatusChanged(_ link: ServerLink, wasConnected: Bool) {
        refreshSandboxRoutes()
        if link.isConnected, !wasConnected {
            Task { await syncSandboxProviders(link) }
        }
    }

    // MARK: sync

    private func home(of link: ServerLink) -> SandboxProviderHome? {
        if link.isLocal { return .thisMac }
        return link.serverID.map { .server($0) }
    }

    /// Mirrors a server's providers into settings (and, for This Mac's server, hands it the pre–server ones).
    func syncSandboxProviders(_ link: ServerLink) async {
        guard let home = home(of: link), let c = try? await link.ready() else { return }
        var list: [Proto_SandboxProvider]
        do {
            list = try await c.sandboxProviders()
        } catch let e as ServerError where e.code == .unimplemented {
            return  // an older server: providers stay where they are
        } catch {
            return
        }
        if link.isLocal, await adoptLegacyProviders(c, onServer: list) {
            list = (try? await c.sandboxProviders()) ?? list
        }
        mergeSandboxProviders(list, home: home)
    }

    /// Saves providers that predate server to This Mac's server, with their Keychain key. True if any moved.
    private func adoptLegacyProviders(_ c: ServerClient, onServer: [Proto_SandboxProvider]) async -> Bool {
        let onServerIDs = Set(onServer.compactMap { UUID(uuidString: $0.id) })
        var moved = false
        for p in settings.sandboxProviders where p.home == nil {
            if !onServerIDs.contains(p.id) {
                // Only a key saved in Domestique moves; BOAT_API_KEY and `boat login` also work on the server.
                let cred = BoatClient.credential(account: p.credentialAccount)
                let key = cred?.source == .keychain ? cred?.token : nil
                do {
                    _ = try await c.saveSandboxProvider(Self.radioProvider(p), apiKey: key)
                } catch {
                    continue  // try again next launch
                }
            }
            updateProviderRecord(p.id) { $0.home = .thisMac }
            moved = true
        }
        return moved
    }

    private func mergeSandboxProviders(_ list: [Proto_SandboxProvider], home: SandboxProviderHome) {
        var seen: Set<UUID> = []
        var providers = settings.sandboxProviders
        for r in list {
            guard let id = UUID(uuidString: r.id) else { continue }
            seen.insert(id)
            if let i = providers.firstIndex(where: { $0.id == id }) {
                Self.apply(r, home: home, to: &providers[i])
            } else {
                var p = SandboxProviderConfig(id: id, name: r.name)
                Self.apply(r, home: home, to: &p)
                providers.append(p)
            }
        }
        // Gone from the server: forget it unless workspaces still use it.
        providers.removeAll { p in
            p.home == home && !seen.contains(p.id) && activeWorkspaces(on: p).isEmpty
        }
        if providers != settings.sandboxProviders { settings.sandboxProviders = providers }
        refreshSandboxRoutes()
    }

    /// The server's view of a provider onto the app's record (keeps this Mac's own preferences).
    private static func apply(_ r: Proto_SandboxProvider, home: SandboxProviderHome, to p: inout SandboxProviderConfig) {
        p.name = r.name
        p.kind = .boat
        p.home = home
        p.serverStatus = SandboxProviderServerStatus(credentialSource: r.credentialSource.settingsName, fromConfig: r.fromConfig)
        let d = r.defaults
        p.boat.machineType = d.machineType.isEmpty ? "default" : d.machineType
        p.boat.autoStopMinutes = d.hasAutoStopMinutes ? Int(d.autoStopMinutes) : nil
        p.boat.environment = d.environment.isEmpty ? nil : d.environment
        p.boat.fromSnapshot = d.fromSnapshot.isEmpty ? nil : d.fromSnapshot
        p.boat.deleteOnArchive = d.deleteOnArchive
    }

    static func radioProvider(_ p: SandboxProviderConfig) -> Proto_SandboxProvider {
        var r = Proto_SandboxProvider()
        r.id = p.id.uuidString.lowercased()
        r.kind = .boat
        r.name = p.name
        var d = Proto_SandboxDefaults()
        d.machineType = p.boat.machineType
        if let m = p.boat.autoStopMinutes { d.autoStopMinutes = UInt32(max(0, m)) }
        d.environment = p.boat.environment ?? ""
        d.fromSnapshot = p.boat.fromSnapshot ?? ""
        d.deleteOnArchive = p.boat.deleteOnArchive
        r.defaults = d
        return r
    }

    private func updateProviderRecord(_ id: UUID, _ mutate: (inout SandboxProviderConfig) -> Void) {
        guard let i = settings.sandboxProviders.firstIndex(where: { $0.id == id }) else { return }
        mutate(&settings.sandboxProviders[i])
    }

    // MARK: places to run

    /// Every server, This Mac's first.
    var servers: [SandboxProviderHome] { [.thisMac] + settings.servers.map { .server($0.id) } }

    /// The server a location runs on. Providers from before server count as This Mac's.
    func server(of loc: WorkspaceLocation) -> SandboxProviderHome {
        switch loc {
        case .local: return .thisMac
        case .server(let id): return .server(id)
        case .sandbox, .cloud: return settings.provider(for: loc)?.home ?? .thisMac
        }
    }

    /// The worktree location on `server` (whether or not worktrees are on there).
    func worktreeLocation(on server: SandboxProviderHome) -> WorkspaceLocation {
        switch server {
        case .thisMac: .local
        case .server(let id): .server(id)
        }
    }

    func isWorktree(_ loc: WorkspaceLocation) -> Bool {
        switch loc {
        case .local, .server: true
        case .sandbox, .cloud: false
        }
    }

    /// `server`'s sandbox providers (This Mac's include ones still in the Keychain).
    func sandboxProviders(on server: SandboxProviderHome) -> [SandboxProviderConfig] {
        settings.sandboxProviders.filter { ($0.home ?? .thisMac) == server }
    }

    /// What `server` offers: a worktree (unless turned off), then its sandbox providers.
    func locations(on server: SandboxProviderHome) -> [WorkspaceLocation] {
        var out: [WorkspaceLocation] = []
        if settings.preferences(for: server).worktrees { out.append(worktreeLocation(on: server)) }
        out += sandboxProviders(on: server).map { .sandbox($0.id) }
        return out
    }

    /// Where new workspaces can run, grouped by server: This Mac's, then each remote server's.
    var workspaceLocations: [WorkspaceLocation] { servers.flatMap(locations(on:)) }

    /// What a new workspace on `server` becomes: its chosen default, else the first thing it offers.
    func defaultLocation(on server: SandboxProviderHome) -> WorkspaceLocation? {
        let offered = locations(on: server)
        if let id = settings.preferences(for: server).defaultSandbox, offered.contains(.sandbox(id)) { return .sandbox(id) }
        return offered.first
    }

    /// The app-wide default: the default server's default, else anything on offer.
    var appDefaultLocation: WorkspaceLocation {
        defaultLocation(on: settings.defaultServer ?? .thisMac) ?? workspaceLocations.first ?? .local
    }

    /// Whether `loc` can take a new workspace right now: its server is connected and a provider has a key.
    func isUsable(_ loc: WorkspaceLocation) -> Bool {
        switch loc {
        case .local: return true
        case .server(let id): return remoteServers[id]?.isConnected == true
        case .sandbox, .cloud:
            return settings.provider(for: loc).map { BoatClient.isConfigured(account: $0.credentialAccount) } ?? false
        }
    }

    /// What the sidebar's + offers when there's more than one usable place to run (nil otherwise: +
    /// just creates on the default). Usable locations only; the default stays even if it's offline.
    func newWorkspaceChoices(for repo: Repository) -> [WorkspaceLocation]? {
        let def = defaultLocation(for: repo)
        let choices = workspaceLocations.filter { $0 == def || isUsable($0) }
        return choices.count > 1 ? choices : nil
    }

    /// One server's share of a list of locations, for menus and pickers with a section per server.
    struct ServerLocations: Identifiable {
        var server: SandboxProviderHome
        var locations: [WorkspaceLocation]
        var id: String { server.key }
    }

    func groupedByServer(_ locs: [WorkspaceLocation]) -> [ServerLocations] {
        servers.compactMap { server in
            let mine = locs.filter { self.server(of: $0) == server }
            return mine.isEmpty ? nil : ServerLocations(server: server, locations: mine)
        }
    }

    /// The full name: "This Mac", "hetzner-box", "boat.dev", "boat.dev · hetzner-box".
    func locationName(_ loc: WorkspaceLocation) -> String {
        switch loc {
        case .server(let id): return settings.servers.first { $0.id == id }?.name ?? "Missing server"
        case .sandbox, .cloud:
            guard let p = settings.provider(for: loc) else { return "Missing sandbox provider" }
            // A remote server's provider says which server drives it.
            if case .server = p.home { return "\(p.name) · \(serverName(for: p.home!))" }
            return p.name
        case .local: return loc.displayName
        }
    }

    /// The name within its server's section: "Worktree" or the provider's name.
    func targetName(_ loc: WorkspaceLocation) -> String {
        isWorktree(loc) ? "Worktree" : settings.provider(for: loc)?.name ?? "Missing sandbox provider"
    }

    /// "Worktree on This Mac", "boat.dev on hetzner-box".
    func longLocationName(_ loc: WorkspaceLocation) -> String {
        "\(targetName(loc)) on \(serverName(for: server(of: loc)))"
    }

    // MARK: per-server choices

    func updateServerPreferences(_ server: SandboxProviderHome, _ mutate: (inout ServerPreferences) -> Void) {
        var p = settings.preferences(for: server)
        mutate(&p)
        settings.setPreferences(p, for: server)
    }

    /// Makes `loc` what new workspaces on its server become.
    func makeServerDefault(_ loc: WorkspaceLocation) {
        let server = server(of: loc)
        updateServerPreferences(server) { $0.defaultSandbox = settings.provider(for: loc)?.id }
    }

    // MARK: editing

    /// Adds a boat.dev provider to `home`'s server (nil = this Mac's Keychain, when This Mac has no server).
    /// `apiKey` nil = the server's `BOAT_API_KEY` / `boat login`.
    func addSandboxProvider(name: String, apiKey: String?, home: SandboxProviderHome?, boat: BoatSettings = BoatSettings()) async {
        var p = SandboxProviderConfig(name: name, boat: boat)
        let key = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        guard let home else {
            if let key { BoatClient.saveAPIKey(key, account: p.credentialAccount) }
            settings.sandboxProviders.append(p)
            cloud.refreshCredentialState()
            return
        }
        do {
            let saved = try await serverClient(for: home).saveSandboxProvider(Self.radioProvider(p), apiKey: key)
            Self.apply(saved, home: home, to: &p)
            settings.sandboxProviders.append(p)
            refreshSandboxRoutes()
        } catch {
            alert = AppAlert(title: "Couldn't add \(name) to \(serverName(for: home))", message: Self.serverErrorMessage(error))
        }
    }

    /// Saves an edited provider here and, debounced, on its server.
    func updateSandboxProvider(_ p: SandboxProviderConfig) {
        guard let i = settings.sandboxProviders.firstIndex(where: { $0.id == p.id }) else { return }
        settings.sandboxProviders[i] = p
        guard let home = p.home, p.serverStatus?.fromConfig != true else { return }
        providerSaveTasks[p.id]?.cancel()
        providerSaveTasks[p.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            do {
                _ = try await self.serverClient(for: home).saveSandboxProvider(Self.radioProvider(p))
            } catch {
                self.alert = AppAlert(title: "Couldn't save \(p.name) on \(self.serverName(for: home))", message: Self.serverErrorMessage(error))
            }
        }
    }

    /// Replaces ("" forgets) a provider's API key, wherever it's kept.
    func setSandboxProviderKey(_ p: SandboxProviderConfig, apiKey: String) async {
        guard let home = p.home else {
            BoatClient.saveAPIKey(apiKey.isEmpty ? nil : apiKey, account: p.credentialAccount)
            cloud.refreshCredentialState()
            return
        }
        do {
            let saved = try await serverClient(for: home).saveSandboxProvider(Self.radioProvider(p), apiKey: apiKey)
            updateProviderRecord(p.id) { Self.apply(saved, home: home, to: &$0) }
            refreshSandboxRoutes()
        } catch {
            alert = AppAlert(title: "Couldn't save the key on \(serverName(for: home))", message: Self.serverErrorMessage(error))
        }
    }

    /// Workspaces still on this provider (removing it would orphan their sandboxes).
    func activeWorkspaces(on p: SandboxProviderConfig) -> [Workspace] {
        state.workspaces.filter { !$0.isArchived && p.owns($0.host) }
    }

    func removeSandboxProvider(_ p: SandboxProviderConfig) async {
        guard activeWorkspaces(on: p).isEmpty else {
            alert = AppAlert(title: "Archive its workspaces first", message: "\(p.name) still has active workspaces.")
            return
        }
        if let home = p.home {
            do {
                try await serverClient(for: home).removeSandboxProvider(id: p.id.uuidString.lowercased())
            } catch let e as ServerError where e.code == .notFound {
                // Already gone there.
            } catch {
                alert = AppAlert(title: "Couldn't remove \(p.name) from \(serverName(for: home))", message: Self.serverErrorMessage(error))
                return
            }
        }
        forgetSandboxProvider(p)
    }

    /// Drops the app's record (and any Keychain key) without touching its server.
    func forgetSandboxProvider(_ p: SandboxProviderConfig) {
        settings.sandboxProviders.removeAll { $0.id == p.id }
        BoatClient.saveAPIKey(nil, account: p.credentialAccount)
        for repo in state.repositories where repo.defaultLocation == .sandbox(p.id) {
            updateRepo(repo.id) { $0.defaultLocation = nil }
        }
        let server = p.home ?? .thisMac
        if settings.preferences(for: server).defaultSandbox == p.id { updateServerPreferences(server) { $0.defaultSandbox = nil } }
        refreshSandboxRoutes()
    }

    static func serverErrorMessage(_ error: Error) -> String {
        if let e = error as? ServerError, e.code == .permissionDenied {
            return "\(e.message)\n\nChanging a server's sandbox providers or MCP servers needs an admin token."
        }
        if let e = error as? ServerError, e.code == .unimplemented {
            return "This server doesn't support this yet. Update it to the latest domestique."
        }
        return error.localizedDescription
    }
}

/// Thread-safe account → server table for `BoatClient.routing`, which is read off the main actor.
final class SandboxRouteTable: @unchecked Sendable {  // guarded by `lock`
    static let shared = SandboxRouteTable()

    struct Route: Sendable {
        var providerID: String
        var home: SandboxProviderHome
        /// The server is connected and has a key for it.
        var usable: Bool
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]

    func set(_ r: [String: Route]) { lock.withLock { routes = r } }
    func route(_ account: String) -> Route? { lock.withLock { routes[account] } }
}
