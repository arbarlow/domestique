import Foundation

/// Where a sandbox provider's API calls go when it isn't this Mac's own Keychain key: a server
/// that owns the provider (its key stays there). The app implements it on top of the Domestique protocol.
///
/// Errors should be `BoatAPIError`s with HTTP-like statuses (404 = gone, 503 = try again) so callers
/// treat both routes the same.
public protocol SandboxBackend: Sendable {
    func sandbox(_ id: String) async throws -> BoatSandbox
    func list() async throws -> [BoatSandbox]
    func create(_ request: BoatCreateRequest, idempotencyKey: String) async throws -> String
    func stop(_ id: String) async throws
    func resume(_ id: String, ttlSeconds: Int?) async throws
    func setAutoStop(_ id: String, ttlSeconds: Int?) async throws
    func rename(_ id: String, name: String) async throws
    func delete(_ id: String) async throws
    func recover(_ id: String) async throws
    func sshAccess(_ id: String, publicKey: String) async throws -> BoatSSHAccess
    func desktopURL(_ id: String, dark: Bool?) async throws -> URL
    func hostedURL(_ id: String, port: Int, public isPublic: Bool, title: String?) async throws -> URL
    func me() async throws -> BoatUser
    func limits() async throws -> BoatLimits
}

/// How a provider's calls are routed. Set by the app, which knows which providers live on which
/// Server; nil (or a nil answer) means "use this Mac's Keychain / BOAT_API_KEY / boat login".
public struct SandboxRouting: Sendable {
    /// The backend for a provider's Keychain account (`SandboxProviderConfig.credentialAccount`).
    public var backend: @Sendable (_ account: String) -> (any SandboxBackend)?
    /// Whether that backend can be used right now (its server is connected and has a key).
    public var isConfigured: @Sendable (_ account: String) -> Bool

    public init(
        backend: @escaping @Sendable (String) -> (any SandboxBackend)?, isConfigured: @escaping @Sendable (String) -> Bool
    ) {
        self.backend = backend
        self.isConfigured = isConfigured
    }
}
