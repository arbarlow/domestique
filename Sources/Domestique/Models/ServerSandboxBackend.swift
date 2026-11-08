import DQCore
import Foundation
import HostKit
import ServerKit

/// A sandbox provider that lives on a server: every boat.dev call becomes a Domestique protocol request, so
/// the API key stays on the server. `BoatClient` uses this through `BoatClient.routing`, so cloud
/// workspaces, `BoatHost` and Settings work the same whichever server owns the provider.
struct ServerSandboxBackend: SandboxBackend {
    /// The provider's id on the server.
    let providerID: String
    /// The server's connected client (waits for the connection).
    let client: @Sendable () async throws -> ServerClient

    private func call<T: Sendable>(_ body: (ServerClient) async throws -> T) async throws -> T {
        do {
            return try await body(try await client())
        } catch let e as ServerError {
            throw Self.boatError(e)
        }
    }

    /// HTTP-like statuses, so callers that check for 404 (deleted) or 401 (don't retry) behave the
    /// same as with a direct boat.dev call.
    static func boatError(_ e: ServerError) -> BoatAPIError {
        let status: Int =
            switch e.code {
            case .notFound: 404
            case .invalidArgument: 400
            // No key on the server, or boat.dev rejected it: retrying won't help.
            case .failedPrecondition, .unauthenticated: 401
            case .permissionDenied: 403
            case .unavailable: 503
            case .unimplemented: 501
            default: 500
            }
        var message = e.message
        if e.code == .permissionDenied { message += " Use a server token with more access." }
        if e.code == .unimplemented { message = "This server doesn't support sandbox providers yet. Update it." }
        return BoatAPIError(status: status, code: "domestique_\(e.code)", message: message)
    }

    // MARK: SandboxBackend

    func sandbox(_ id: String) async throws -> BoatSandbox {
        try await call { try await $0.sandbox(providerID: providerID, sandboxID: id) }.boat
    }

    func list() async throws -> [BoatSandbox] {
        try await call { try await $0.sandboxes(providerID: providerID) }.map(\.boat)
    }

    func create(_ request: BoatCreateRequest, idempotencyKey: String) async throws -> String {
        var req = Proto_CreateSandbox()
        req.providerID = providerID
        req.name = request.name ?? ""
        req.machineType = request.type ?? ""
        if request.disableAutoStop {
            req.disableAutoStop = true
        } else if let ttl = request.ttlSeconds {
            req.autoStopMinutes = UInt32(max(1, ttl / 60))
        }
        req.environment = request.environment ?? ""
        req.fromSnapshot = request.from ?? ""
        req.labels = request.labels ?? [:]
        return try await call { try await $0.createSandbox(req, idempotencyKey: idempotencyKey) }.id
    }

    private func change(_ id: String, _ action: Proto_SandboxAction, ttl: Int? = nil, name: String = "") async throws {
        var req = Proto_ChangeSandbox()
        req.providerID = providerID
        req.sandboxID = id
        req.action = action
        if let ttl { req.ttlSeconds = Int32(clamping: ttl) }
        req.name = name
        try await call { try await $0.changeSandbox(req) }
    }

    func stop(_ id: String) async throws { try await change(id, .stop) }
    func resume(_ id: String, ttlSeconds: Int?) async throws { try await change(id, .resume, ttl: ttlSeconds) }
    func setAutoStop(_ id: String, ttlSeconds: Int?) async throws { try await change(id, .setAutoStop, ttl: ttlSeconds) }
    func rename(_ id: String, name: String) async throws { try await change(id, .rename, name: name) }
    func delete(_ id: String) async throws { try await change(id, .delete) }
    func recover(_ id: String) async throws { try await change(id, .recover) }

    private func access(_ id: String, _ kind: Proto_OpenSandboxAccess.OneOf_Kind) async throws -> Proto_SandboxAccess {
        var req = Proto_OpenSandboxAccess()
        req.providerID = providerID
        req.sandboxID = id
        req.kind = kind
        return try await call { try await $0.openSandboxAccess(req) }
    }

    func sshAccess(_ id: String, publicKey: String) async throws -> BoatSSHAccess {
        let a = try await access(id, .sshPublicKey(publicKey))
        return BoatSSHAccess(
            machineIp: a.machineIp.nilIfEmpty, sshUser: a.sshUser.nilIfEmpty, sshEndpoint: a.sshEndpoint.nilIfEmpty,
            hostKey: a.hostKey)
    }

    func desktopURL(_ id: String, dark: Bool?) async throws -> URL {
        var d = Proto_DesktopAccess()
        if let dark { d.dark = dark }
        return try Self.url(try await access(id, .desktop(d)))
    }

    func hostedURL(_ id: String, port: Int, public isPublic: Bool, title: String?) async throws -> URL {
        var p = Proto_PortAccess()
        p.port = UInt32(clamping: port)
        p.public = isPublic
        p.title = title ?? ""
        return try Self.url(try await access(id, .port(p)))
    }

    private static func url(_ a: Proto_SandboxAccess) throws -> URL {
        guard let u = URL(string: a.url), !a.url.isEmpty else {
            throw BoatAPIError(status: 0, code: nil, message: "The server didn't return a URL")
        }
        return u
    }

    private func account() async throws -> Proto_SandboxAccount {
        let ps = try await call { try await $0.sandboxProviders(checkAccount: true) }
        guard let p = ps.first(where: { $0.id.caseInsensitiveCompare(providerID) == .orderedSame }) else {
            throw BoatAPIError(status: 404, code: "not_found", message: "This provider isn't on its server any more.")
        }
        return p.account
    }

    func me() async throws -> BoatUser {
        let a = try await account()
        if !a.error.isEmpty { throw BoatAPIError(status: 401, code: "account", message: a.error) }
        return BoatUser(login: a.login.nilIfEmpty, email: a.email.nilIfEmpty, displayName: a.displayName.nilIfEmpty)
    }

    func limits() async throws -> BoatLimits {
        let a = try await account()
        return BoatLimits(
            canStart: a.canStart, trialLine: a.trialLine.nilIfEmpty, startBlockedReason: a.startBlockedReason.nilIfEmpty,
            machineTypes: a.machineTypes.map { .init(type: $0.type, available: $0.available, reason: $0.reason.nilIfEmpty) })
    }
}

extension Proto_Sandbox {
    /// The app's boat.dev model. `state` is boat's own string, so `BoatPhase` reads it as before.
    var boat: BoatSandbox {
        var b = BoatSandbox(id: id, state: state.isEmpty ? "init" : state, error: error.nilIfEmpty)
        b.name = name.nilIfEmpty
        b.type = machineType.nilIfEmpty
        b.vcpu = vcpu == 0 ? nil : Int(vcpu)
        b.memoryGB = memoryGb == 0 ? nil : Int(memoryGb)
        b.ip = ip.nilIfEmpty
        b.sshEndpoint = sshEndpoint.nilIfEmpty
        b.url = url.nilIfEmpty
        b.desktopAvailable = hasDesktopAvailable ? desktopAvailable : nil
        b.archiveAfter = archiveAfterMs == 0 ? nil : Date(timeIntervalSince1970: Double(archiveAfterMs) / 1000)
        b.ttlSeconds = hasTtlSeconds ? Int(ttlSeconds) : nil
        b.health = health.nilIfEmpty
        b.healthReason = healthReason.nilIfEmpty
        b.hydrated = hasHydrated ? hydrated : nil
        b.createdAt = createdAtMs == 0 ? nil : Date(timeIntervalSince1970: Double(createdAtMs) / 1000)
        b.stoppedAt = stoppedAtMs == 0 ? nil : Date(timeIntervalSince1970: Double(stoppedAtMs) / 1000)
        b.environment = environment.nilIfEmpty
        return b
    }
}

extension Proto_SandboxCredentialSource {
    /// The string `SandboxProviderServerStatus.credentialSource` stores.
    var settingsName: String {
        switch self {
        case .stored: "stored"
        case .config: "config"
        case .environment: "environment"
        case .cli: "cli"
        default: "none"
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
