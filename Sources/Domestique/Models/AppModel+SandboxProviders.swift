import DQCore
import Foundation
import HostKit
import RaceRadioKit

/// Sandbox providers belong to Team Cars. Each car keeps its providers' API keys and makes every
/// boat.dev call; the app mirrors the providers into `settings.sandboxProviders` (for the picker,
/// the sidebar and cloud workspaces) and routes `BoatClient` through the owning car.
///
/// - This Mac's car takes over the providers set up before Team Car (`home == nil`) the first time it
///   connects: same ids, Keychain key copied over. Until then, or with `DOMESTIQUE_LEGACY_ENGINE=1`,
///   those keep using the Keychain directly.
/// - A remote car's providers appear when it connects and disappear when it drops them.
/// - Editing a provider saves it to its car (ADMIN token for remote cars).
extension AppModel {
    // MARK: routing

    /// Points `BoatClient` at the cars. Called once at launch.
    func installSandboxRouting() {
        let table = SandboxRouteTable.shared
        BoatClient.routing = SandboxRouting(
            backend: { [weak self] account in
                guard let route = table.route(account) else { return nil }
                return TeamCarSandboxBackend(providerID: route.providerID) { [weak self] in
                    guard let self else { throw TeamCarError(code: .unavailable, message: "Domestique is quitting") }
                    return try await self.carClient(for: route.home)
                }
            },
            isConfigured: { table.route($0)?.usable ?? false })
        refreshSandboxRoutes()
    }

    /// The link of the car that owns providers at `home` (nil if that car isn't in Settings).
    func link(for home: SandboxProviderHome) -> TeamCarLink? {
        switch home {
        case .thisMac: teamCar
        case .teamCar(let id): remoteCars[id]
        }
    }

    func carClient(for home: SandboxProviderHome) async throws -> TeamCarClient {
        guard let link = link(for: home) else {
            throw TeamCarError(code: .unavailable, message: "That Team Car isn't in Settings → Team Cars any more.")
        }
        return try await link.ready()
    }

    func carName(for home: SandboxProviderHome) -> String {
        switch home {
        case .thisMac: "This Mac"
        case .teamCar(let id): settings.teamCars.first { $0.id == id }?.name ?? "Missing Team Car"
        }
    }

    /// Rebuilds the route table from settings and connection state.
    func refreshSandboxRoutes() {
        var routes: [String: SandboxRouteTable.Route] = [:]
        for p in settings.sandboxProviders {
            guard let home = p.home else { continue }
            // With the in-app engine, This Mac's car isn't running: keep using the Keychain.
            if home == .thisMac, teamCar?.isEnabled != true { continue }
            let usable = link(for: home)?.isConnected == true && (p.carStatus?.hasKey ?? false)
            routes[p.credentialAccount] = .init(providerID: p.id.uuidString.lowercased(), home: home, usable: usable)
        }
        SandboxRouteTable.shared.set(routes)
        cloud?.refreshCredentialState()
    }

    /// TeamCarLink calls this on every status change.
    func teamCarStatusChanged(_ link: TeamCarLink, wasConnected: Bool) {
        refreshSandboxRoutes()
        if link.isConnected, !wasConnected {
            Task { await syncSandboxProviders(link) }
        }
    }

    // MARK: sync

    private func home(of link: TeamCarLink) -> SandboxProviderHome? {
        if link.isLocal { return .thisMac }
        return link.carID.map { .teamCar($0) }
    }

    /// Mirrors a car's providers into settings (and, for This Mac's car, hands it the pre–Team Car ones).
    func syncSandboxProviders(_ link: TeamCarLink) async {
        guard let home = home(of: link), let c = try? await link.ready() else { return }
        var list: [Radio_SandboxProvider]
        do {
            list = try await c.sandboxProviders()
        } catch let e as TeamCarError where e.code == .unimplemented {
            return  // an older Team Car: providers stay where they are
        } catch {
            return
        }
        if link.isLocal, await adoptLegacyProviders(c, onCar: list) {
            list = (try? await c.sandboxProviders()) ?? list
        }
        mergeSandboxProviders(list, home: home)
    }

    /// Saves providers that predate Team Car to This Mac's car, with their Keychain key. True if any moved.
    private func adoptLegacyProviders(_ c: TeamCarClient, onCar: [Radio_SandboxProvider]) async -> Bool {
        let onCarIDs = Set(onCar.compactMap { UUID(uuidString: $0.id) })
        var moved = false
        for p in settings.sandboxProviders where p.home == nil {
            if !onCarIDs.contains(p.id) {
                // Only a key saved in Domestique moves; BOAT_API_KEY and `boat login` also work on the car.
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

    private func mergeSandboxProviders(_ list: [Radio_SandboxProvider], home: SandboxProviderHome) {
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
        // Gone from the car: forget it unless workspaces still use it.
        providers.removeAll { p in
            p.home == home && !seen.contains(p.id) && activeWorkspaces(on: p).isEmpty
        }
        if providers != settings.sandboxProviders { settings.sandboxProviders = providers }
        refreshSandboxRoutes()
    }

    /// The car's view of a provider onto the app's record (keeps this Mac's own preferences).
    private static func apply(_ r: Radio_SandboxProvider, home: SandboxProviderHome, to p: inout SandboxProviderConfig) {
        p.name = r.name
        p.kind = .boat
        p.home = home
        p.carStatus = SandboxProviderCarStatus(credentialSource: r.credentialSource.settingsName, fromConfig: r.fromConfig)
        let d = r.defaults
        p.boat.machineType = d.machineType.isEmpty ? "default" : d.machineType
        p.boat.autoStopMinutes = d.hasAutoStopMinutes ? Int(d.autoStopMinutes) : nil
        p.boat.environment = d.environment.isEmpty ? nil : d.environment
        p.boat.fromSnapshot = d.fromSnapshot.isEmpty ? nil : d.fromSnapshot
        p.boat.deleteOnArchive = d.deleteOnArchive
    }

    static func radioProvider(_ p: SandboxProviderConfig) -> Radio_SandboxProvider {
        var r = Radio_SandboxProvider()
        r.id = p.id.uuidString.lowercased()
        r.kind = .boat
        r.name = p.name
        var d = Radio_SandboxDefaults()
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

    /// Every Team Car, This Mac's first.
    var cars: [SandboxProviderHome] { [.thisMac] + settings.teamCars.map { .teamCar($0.id) } }

    /// The car a location runs on. Providers from before Team Car count as This Mac's.
    func car(of loc: WorkspaceLocation) -> SandboxProviderHome {
        switch loc {
        case .local: return .thisMac
        case .teamCar(let id): return .teamCar(id)
        case .sandbox, .cloud: return settings.provider(for: loc)?.home ?? .thisMac
        }
    }

    /// The worktree location on `car` (whether or not worktrees are on there).
    func worktreeLocation(on car: SandboxProviderHome) -> WorkspaceLocation {
        switch car {
        case .thisMac: .local
        case .teamCar(let id): .teamCar(id)
        }
    }

    func isWorktree(_ loc: WorkspaceLocation) -> Bool {
        switch loc {
        case .local, .teamCar: true
        case .sandbox, .cloud: false
        }
    }

    /// `car`'s sandbox providers (This Mac's include ones still in the Keychain).
    func sandboxProviders(on car: SandboxProviderHome) -> [SandboxProviderConfig] {
        settings.sandboxProviders.filter { ($0.home ?? .thisMac) == car }
    }

    /// What `car` offers: a worktree (unless turned off), then its sandbox providers.
    func locations(on car: SandboxProviderHome) -> [WorkspaceLocation] {
        var out: [WorkspaceLocation] = []
        if settings.preferences(for: car).worktrees { out.append(worktreeLocation(on: car)) }
        out += sandboxProviders(on: car).map { .sandbox($0.id) }
        return out
    }

    /// Where new workspaces can run, grouped by car: This Mac's, then each remote car's.
    var workspaceLocations: [WorkspaceLocation] { cars.flatMap(locations(on:)) }

    /// What a new workspace on `car` becomes: its chosen default, else the first thing it offers.
    func defaultLocation(on car: SandboxProviderHome) -> WorkspaceLocation? {
        let offered = locations(on: car)
        if let id = settings.preferences(for: car).defaultSandbox, offered.contains(.sandbox(id)) { return .sandbox(id) }
        return offered.first
    }

    /// The app-wide default: the default car's default, else anything on offer.
    var appDefaultLocation: WorkspaceLocation {
        defaultLocation(on: settings.defaultCar ?? .thisMac) ?? workspaceLocations.first ?? .local
    }

    /// Whether `loc` can take a new workspace right now: its car is connected and a provider has a key.
    func isUsable(_ loc: WorkspaceLocation) -> Bool {
        switch loc {
        case .local: return true
        case .teamCar(let id): return remoteCars[id]?.isConnected == true
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

    /// One car's share of a list of locations, for menus and pickers with a section per car.
    struct CarLocations: Identifiable {
        var car: SandboxProviderHome
        var locations: [WorkspaceLocation]
        var id: String { car.key }
    }

    func groupedByCar(_ locs: [WorkspaceLocation]) -> [CarLocations] {
        cars.compactMap { car in
            let mine = locs.filter { self.car(of: $0) == car }
            return mine.isEmpty ? nil : CarLocations(car: car, locations: mine)
        }
    }

    /// The full name: "This Mac", "hetzner-box", "boat.dev", "boat.dev · hetzner-box".
    func locationName(_ loc: WorkspaceLocation) -> String {
        switch loc {
        case .teamCar(let id): return settings.teamCars.first { $0.id == id }?.name ?? "Missing Team Car"
        case .sandbox, .cloud:
            guard let p = settings.provider(for: loc) else { return "Missing sandbox provider" }
            // A remote car's provider says which car drives it.
            if case .teamCar = p.home { return "\(p.name) · \(carName(for: p.home!))" }
            return p.name
        case .local: return loc.displayName
        }
    }

    /// The name within its car's section: "Worktree" or the provider's name.
    func targetName(_ loc: WorkspaceLocation) -> String {
        isWorktree(loc) ? "Worktree" : settings.provider(for: loc)?.name ?? "Missing sandbox provider"
    }

    /// "Worktree on This Mac", "boat.dev on hetzner-box".
    func longLocationName(_ loc: WorkspaceLocation) -> String {
        "\(targetName(loc)) on \(carName(for: car(of: loc)))"
    }

    // MARK: per-car choices

    func updateCarPreferences(_ car: SandboxProviderHome, _ mutate: (inout CarPreferences) -> Void) {
        var p = settings.preferences(for: car)
        mutate(&p)
        settings.setPreferences(p, for: car)
    }

    /// Makes `loc` what new workspaces on its car become.
    func makeCarDefault(_ loc: WorkspaceLocation) {
        let car = car(of: loc)
        updateCarPreferences(car) { $0.defaultSandbox = settings.provider(for: loc)?.id }
    }

    // MARK: editing

    /// Adds a boat.dev provider to `home`'s car (nil = this Mac's Keychain, when This Mac has no car).
    /// `apiKey` nil = the car's `BOAT_API_KEY` / `boat login`.
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
            let saved = try await carClient(for: home).saveSandboxProvider(Self.radioProvider(p), apiKey: key)
            Self.apply(saved, home: home, to: &p)
            settings.sandboxProviders.append(p)
            refreshSandboxRoutes()
        } catch {
            alert = AppAlert(title: "Couldn't add \(name) to \(carName(for: home))", message: Self.carErrorMessage(error))
        }
    }

    /// Saves an edited provider here and, debounced, on its car.
    func updateSandboxProvider(_ p: SandboxProviderConfig) {
        guard let i = settings.sandboxProviders.firstIndex(where: { $0.id == p.id }) else { return }
        settings.sandboxProviders[i] = p
        guard let home = p.home, p.carStatus?.fromConfig != true else { return }
        providerSaveTasks[p.id]?.cancel()
        providerSaveTasks[p.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            do {
                _ = try await self.carClient(for: home).saveSandboxProvider(Self.radioProvider(p))
            } catch {
                self.alert = AppAlert(title: "Couldn't save \(p.name) on \(self.carName(for: home))", message: Self.carErrorMessage(error))
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
            let saved = try await carClient(for: home).saveSandboxProvider(Self.radioProvider(p), apiKey: apiKey)
            updateProviderRecord(p.id) { Self.apply(saved, home: home, to: &$0) }
            refreshSandboxRoutes()
        } catch {
            alert = AppAlert(title: "Couldn't save the key on \(carName(for: home))", message: Self.carErrorMessage(error))
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
                try await carClient(for: home).removeSandboxProvider(id: p.id.uuidString.lowercased())
            } catch let e as TeamCarError where e.code == .notFound {
                // Already gone there.
            } catch {
                alert = AppAlert(title: "Couldn't remove \(p.name) from \(carName(for: home))", message: Self.carErrorMessage(error))
                return
            }
        }
        forgetSandboxProvider(p)
    }

    /// Drops the app's record (and any Keychain key) without touching its car.
    func forgetSandboxProvider(_ p: SandboxProviderConfig) {
        settings.sandboxProviders.removeAll { $0.id == p.id }
        BoatClient.saveAPIKey(nil, account: p.credentialAccount)
        for repo in state.repositories where repo.defaultLocation == .sandbox(p.id) {
            updateRepo(repo.id) { $0.defaultLocation = nil }
        }
        let car = p.home ?? .thisMac
        if settings.preferences(for: car).defaultSandbox == p.id { updateCarPreferences(car) { $0.defaultSandbox = nil } }
        refreshSandboxRoutes()
    }

    static func carErrorMessage(_ error: Error) -> String {
        if let e = error as? TeamCarError, e.code == .permissionDenied {
            return "\(e.message)\n\nChanging a Team Car's sandbox providers needs an admin token."
        }
        if let e = error as? TeamCarError, e.code == .unimplemented {
            return "This Team Car doesn't support sandbox providers yet. Update it to the latest teamcar."
        }
        return error.localizedDescription
    }
}

/// Thread-safe account → car table for `BoatClient.routing`, which is read off the main actor.
final class SandboxRouteTable: @unchecked Sendable {  // guarded by `lock`
    static let shared = SandboxRouteTable()

    struct Route: Sendable {
        var providerID: String
        var home: SandboxProviderHome
        /// The car is connected and has a key for it.
        var usable: Bool
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]

    func set(_ r: [String: Route]) { lock.withLock { routes = r } }
    func route(_ account: String) -> Route? { lock.withLock { routes[account] } }
}
