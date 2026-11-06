import DQCore
import Foundation
import Security

/// A boat.dev sandbox, as `GET /sandboxes/{id}` reports it. Only the fields Domestique uses.
public struct BoatSandbox: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    /// init, provisioning, provisioned, cloning, ready, idle, running, archiving, archived, error, cancelled.
    public var state: String
    public var error: String?
    public var type: String?
    public var vcpu: Int?
    public var memoryGB: Int?
    public var ip: String?
    public var sshEndpoint: String?
    public var url: String?
    public var desktopAvailable: Bool?
    /// When the sandbox stops by itself; nil = auto-stop off.
    public var archiveAfter: Date?
    public var ttlSeconds: Int?
    public var health: String?
    public var healthReason: String?
    public var hydrated: Bool?
    public var createdAt: Date?
    public var stoppedAt: Date?
    public var environment: String?

    public init(id: String, state: String, error: String? = nil) {
        self.id = id
        self.state = state
        self.error = error
    }

    public var phase: BoatPhase { BoatPhase(apiState: state) }
}

/// The five states the UI cares about (boat's API names several sub-states for each).
public enum BoatPhase: String, Sendable, Hashable {
    case starting, running, stopping, stopped, error, gone

    public init(apiState: String) {
        switch apiState {
        case "init", "provisioning", "provisioned", "cloning": self = .starting
        case "ready", "idle", "running": self = .running
        case "archiving": self = .stopping
        case "archived": self = .stopped
        case "cancelled": self = .gone
        default: self = .error
        }
    }

    public var label: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .error: "Error"
        case .gone: "Deleted"
        }
    }

    public var isTransitional: Bool { self == .starting || self == .stopping }
}

public struct BoatSSHAccess: Codable, Sendable, Hashable {
    public var machineIp: String?
    public var sshUser: String?
    public var sshEndpoint: String?
    public var hostKey: String

    public init(machineIp: String?, sshUser: String?, sshEndpoint: String?, hostKey: String) {
        self.machineIp = machineIp
        self.sshUser = sshUser
        self.sshEndpoint = sshEndpoint
        self.hostKey = hostKey
    }
}

public struct BoatUser: Codable, Sendable, Hashable {
    public var id: String?
    public var login: String?
    public var email: String?
    public var displayName: String?

    public init(id: String? = nil, login: String?, email: String?, displayName: String?) {
        self.id = id
        self.login = login
        self.email = email
        self.displayName = displayName
    }
}

public struct BoatLimits: Codable, Sendable, Hashable {
    public var canStart: Bool?
    public var trialLine: String?
    public var accessTier: String?
    public var startBlockedReason: String?
    public var machineTypes: [MachineType]?

    public init(canStart: Bool?, trialLine: String?, accessTier: String? = nil, startBlockedReason: String?, machineTypes: [MachineType]?) {
        self.canStart = canStart
        self.trialLine = trialLine
        self.accessTier = accessTier
        self.startBlockedReason = startBlockedReason
        self.machineTypes = machineTypes
    }

    public struct MachineType: Codable, Sendable, Hashable {
        public var type: String
        public var available: Bool
        public var reason: String?

        public init(type: String, available: Bool, reason: String?) {
            self.type = type
            self.available = available
            self.reason = reason
        }
    }
}

public struct BoatCreateRequest: Encodable, Sendable {
    public var name: String?
    public var type: String?
    /// Omitted = boat default (1h). `nil` with `disableAutoStop` = never.
    public var ttlSeconds: Int?
    public var disableAutoStop = false
    public var environment: String?
    /// Saved snapshot to start from (`boat new --from`). nil = a fresh machine.
    public var from: String?
    public var labels: [String: String]?

    public init(
        name: String?, type: String?, ttlSeconds: Int?, disableAutoStop: Bool = false, environment: String?, from: String? = nil,
        labels: [String: String]?
    ) {
        self.name = name
        self.type = type
        self.ttlSeconds = ttlSeconds
        self.disableAutoStop = disableAutoStop
        self.environment = environment
        self.from = from
        self.labels = labels
    }

    enum CodingKeys: String, CodingKey { case name, type, ttlSeconds, environment, from, labels }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(type, forKey: .type)
        if disableAutoStop { try c.encodeNil(forKey: .ttlSeconds) } else { try c.encodeIfPresent(ttlSeconds, forKey: .ttlSeconds) }
        try c.encodeIfPresent(environment, forKey: .environment)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encodeIfPresent(labels, forKey: .labels)
    }
}

public struct BoatAPIError: Error, LocalizedError, Sendable {
    public var status: Int
    public var code: String?
    public var message: String
    /// e.g. the setup / billing URL boat returns with some errors.
    public var url: String?
    public var errorDescription: String? { message }

    public init(status: Int, code: String?, message: String, url: String? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.url = url
    }
}

/// Where the API key came from (shown in Settings).
public enum BoatCredentialSource: Sendable, Hashable {
    case keychain
    case environment
    case cli
    public var label: String {
        switch self {
        case .keychain: "API key saved in Domestique"
        case .environment: "BOAT_API_KEY environment variable"
        case .cli: "boat CLI login"
        }
    }
}

/// boat.dev HTTP API (`https://boat.dev/api/v1`). Auth: an API key from Settings (Keychain),
/// `BOAT_API_KEY`, or the token the `boat` CLI saved when you ran `boat login`.
public actor BoatClient {
    /// The original account (its key is the `api-key` Keychain item).
    public static let shared = BoatClient()

    /// Keychain account holding the original provider's API key. Other sandbox providers each get
    /// their own (`api-key.<provider id>`).
    public static let defaultAccount = "api-key"

    /// One client per Keychain account (sandbox provider).
    public static func client(account: String?) -> BoatClient {
        let account = account ?? defaultAccount
        if account == defaultAccount { return shared }
        return clientsLock.withLock {
            if let c = clients[account] { return c }
            let c = BoatClient(account: account)
            clients[account] = c
            return c
        }
    }
    nonisolated(unsafe) private static var clients: [String: BoatClient] = [:]
    private static let clientsLock = NSLock()

    /// Which Keychain item this client's API key lives in.
    public let account: String

    /// Set by the app: providers that live on a Team Car route their calls there instead of using a
    /// key on this Mac.
    nonisolated(unsafe) public static var routing: SandboxRouting?

    /// The Team Car backend for this client's provider, if it has one.
    private var backend: (any SandboxBackend)? { Self.routing?.backend(account) }

    public static let dashboardURL = URL(string: "https://boat.dev/dashboard")!
    public static let agentsSetupURL = URL(string: "https://boat.dev/dashboard?tab=agents")!

    private let session: URLSession
    private var baseURL = URL(string: "https://boat.dev/api/v1")!

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = iso.date(from: s) ?? isoNoFraction.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoNoFraction = ISO8601DateFormatter()

    public init(account: String = BoatClient.defaultAccount) {
        self.account = account
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    // MARK: credentials

    public static let keychainService = "dev.domestique.boat"

    /// The key to use and where it came from; nil when there's none. A provider's own key wins;
    /// without one it falls back to `BOAT_API_KEY`, then the `boat login` session.
    public nonisolated static func credential(account: String? = nil) -> (token: String, source: BoatCredentialSource)? {
        if let k = Keychain.read(service: keychainService, account: account ?? defaultAccount), !k.isEmpty { return (k, .keychain) }
        if let k = ProcessInfo.processInfo.environment["BOAT_API_KEY"], !k.isEmpty { return (k, .environment) }
        if let k = cliToken() { return (k, .cli) }
        return nil
    }

    public nonisolated static func saveAPIKey(_ key: String?, account: String? = nil) {
        let account = account ?? defaultAccount
        if let key, !key.isEmpty {
            Keychain.write(service: keychainService, account: account, value: key)
        } else {
            Keychain.delete(service: keychainService, account: account)
        }
    }

    /// Token saved by `boat login` (~/Library/Application Support/ascii/boat/config.json).
    nonisolated static func cliToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/ascii/boat/config.json"),
            home.appendingPathComponent(".config/ascii/boat/config.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let token = obj["token"] as? String, !token.isEmpty
            else { continue }
            return token
        }
        return nil
    }

    public nonisolated static var isConfigured: Bool { isConfigured(account: nil) }
    /// Whether this provider can make calls: its Team Car is connected and has a key, or (for a
    /// provider on this Mac) there's a Keychain key, `BOAT_API_KEY` or a `boat login` session.
    public nonisolated static func isConfigured(account: String?) -> Bool {
        let account = account ?? defaultAccount
        if let r = routing, r.backend(account) != nil { return r.isConfigured(account) }
        return credential(account: account) != nil
    }

    // MARK: sandboxes

    public func sandbox(_ id: String) async throws -> BoatSandbox {
        if let b = backend { return try await b.sandbox(id) }
        return try await call("GET", "/sandboxes/\(id)", as: BoatSandbox.self, key: "sandbox")
    }

    public func list() async throws -> [BoatSandbox] {
        if let b = backend { return try await b.list() }
        return try await call("GET", "/sandboxes?limit=200", as: [BoatSandbox].self, key: "sandboxes")
    }

    /// Creates a sandbox and returns its id straight away (it is still starting).
    public func create(_ request: BoatCreateRequest, idempotencyKey: String) async throws -> String {
        if let b = backend { return try await b.create(request, idempotencyKey: idempotencyKey) }
        let body = try JSONEncoder().encode(request)
        let obj = try await raw("POST", "/sandboxes", body: body, headers: ["Idempotency-Key": idempotencyKey])
        if let sandbox = obj["sandbox"] as? [String: Any], let id = sandbox["id"] as? String { return id }
        if let id = obj["id"] as? String { return id }
        throw BoatAPIError(status: 0, code: nil, message: "boat.dev didn't return a sandbox id")
    }

    public func stop(_ id: String) async throws {
        if let b = backend { return try await b.stop(id) }
        _ = try await raw("POST", "/sandboxes/\(id)/stop", body: Data("{}".utf8))
    }

    /// Resume a stopped sandbox. `ttlSeconds` nil keeps its current auto-stop setting.
    public func resume(_ id: String, ttlSeconds: Int? = nil) async throws {
        if let b = backend { return try await b.resume(id, ttlSeconds: ttlSeconds) }
        var body: [String: Any] = [:]
        if let ttlSeconds { body["ttlSeconds"] = ttlSeconds }
        _ = try await raw("POST", "/sandboxes/\(id)/resume", body: try JSONSerialization.data(withJSONObject: body))
    }

    /// Sets the auto-stop deadline to now + `ttlSeconds`; nil turns auto-stop off.
    public func setAutoStop(_ id: String, ttlSeconds: Int?) async throws {
        if let b = backend { return try await b.setAutoStop(id, ttlSeconds: ttlSeconds) }
        let body: [String: Any] = ["ttlSeconds": ttlSeconds.map { $0 as Any } ?? NSNull()]
        _ = try await raw("PATCH", "/sandboxes/\(id)", body: try JSONSerialization.data(withJSONObject: body))
    }

    public func rename(_ id: String, name: String) async throws {
        if let b = backend { return try await b.rename(id, name: name) }
        _ = try await raw("PATCH", "/sandboxes/\(id)", body: try JSONSerialization.data(withJSONObject: ["name": name]))
    }

    /// Permanently deletes the sandbox and its snapshots.
    public func delete(_ id: String) async throws {
        if let b = backend { return try await b.delete(id) }
        _ = try await raw("DELETE", "/sandboxes/\(id)", body: nil, headers: ["X-Ascii-Confirm-Delete": id])
    }

    public func recover(_ id: String) async throws {
        if let b = backend { return try await b.recover(id) }
        _ = try await raw("POST", "/sandboxes/\(id)/recover", body: Data("{}".utf8))
    }

    /// Authorizes `publicKey` on the sandbox and returns where to connect plus the host key to pin.
    public func sshAccess(_ id: String, publicKey: String) async throws -> BoatSSHAccess {
        if let b = backend { return try await b.sshAccess(id, publicKey: publicKey) }
        let body = try JSONSerialization.data(withJSONObject: ["key": publicKey])
        let data = try await rawData("POST", "/sandboxes/\(id)/sshkey", body: body)
        return try Self.decoder.decode(BoatSSHAccess.self, from: data)
    }

    /// Secret-bearing URL of the 60fps desktop stream.
    public func desktopURL(_ id: String, dark: Bool? = nil) async throws -> URL {
        if let b = backend { return try await b.desktopURL(id, dark: dark) }
        let theme = dark.map { $0 ? "?theme=dark" : "?theme=light" } ?? ""
        let obj = try await raw("POST", "/sandboxes/\(id)/desktop\(theme)", body: Data("{}".utf8))
        guard let s = obj["desktopUrl"] as? String ?? obj["viewerUrl"] as? String ?? obj["url"] as? String, let url = URL(string: s)
        else { throw BoatAPIError(status: 0, code: nil, message: "The desktop isn't available yet. Try again in a few seconds.") }
        return url
    }

    /// A stable HTTPS URL for a port inside the sandbox. Private URLs carry an access token.
    public func hostedURL(_ id: String, port: Int, public isPublic: Bool, title: String? = nil) async throws -> URL {
        if let b = backend { return try await b.hostedURL(id, port: port, public: isPublic, title: title) }
        var body: [String: Any] = ["port": port, "public": isPublic, "localhost": true]
        if let title { body["title"] = title }
        let obj = try await raw("POST", "/sandboxes/\(id)/host", body: try JSONSerialization.data(withJSONObject: body))
        guard let s = obj["url"] as? String, let url = URL(string: s) else {
            throw BoatAPIError(status: 0, code: nil, message: "boat.dev didn't return a URL for port \(port)")
        }
        return url
    }

    public func me() async throws -> BoatUser {
        if let b = backend { return try await b.me() }
        return try await call("GET", "/me", as: BoatUser.self, key: "user")
    }

    public func limits() async throws -> BoatLimits {
        if let b = backend { return try await b.limits() }
        let data = try await rawData("GET", "/limits", body: nil)
        return try Self.decoder.decode(BoatLimits.self, from: data)
    }

    /// Polls until the sandbox reaches `running` (or fails).
    public func waitUntilRunning(_ id: String, timeout: TimeInterval = 300, progress: (@Sendable (BoatSandbox) -> Void)? = nil)
        async throws -> BoatSandbox
    {
        let deadline = Date().addingTimeInterval(timeout)
        var delay: Double = 1
        while true {
            let s = try await sandbox(id)
            progress?(s)
            switch s.phase {
            case .running: return s
            case .error, .gone:
                throw BoatAPIError(status: 0, code: s.state, message: "Sandbox \(id) \(s.phase.label.lowercased())\(s.error.map { ": \($0)" } ?? "")")
            case .stopped:
                throw BoatAPIError(status: 0, code: "archived", message: "Sandbox \(id) is stopped")
            default: break
            }
            if Date() > deadline { throw BoatAPIError(status: 0, code: "timeout", message: "Sandbox \(id) is still \(s.phase.label.lowercased()) after \(Int(timeout))s") }
            try await Task.sleep(for: .seconds(delay))
            delay = min(delay * 1.4, 4)
        }
    }

    // MARK: transport

    private func call<T: Decodable>(_ method: String, _ path: String, as type: T.Type, key: String) async throws -> T {
        let data = try await rawData(method, path, body: nil)
        // Decode `{ "<key>": T }` without a dedicated wrapper type per endpoint.
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let inner = obj[key] else {
            throw BoatAPIError(status: 0, code: nil, message: "Unexpected boat.dev response")
        }
        let innerData = try JSONSerialization.data(withJSONObject: inner)
        return try Self.decoder.decode(T.self, from: innerData)
    }

    @discardableResult
    private func raw(_ method: String, _ path: String, body: Data?, headers: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await rawData(method, path, body: body, headers: headers)
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func rawData(_ method: String, _ path: String, body: Data?, headers: [String: String] = [:]) async throws -> Data {
        guard let (token, _) = Self.credential(account: account) else {
            throw BoatAPIError(
                status: 401, code: "unauthorized",
                message: "Not signed in to boat.dev. Add an API key in Settings → Sandbox Providers, or run `boat login`.")
        }
        var req = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Domestique", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            let err = Self.parseError(status: status, data: data)
            // Transient: capacity / restoring / rate limits on idempotent reads.
            let retryable = status == 503 || (status == 429 && method == "GET") || (status >= 500 && method == "GET")
            if retryable && attempt < 4 {
                try await Task.sleep(for: .seconds(Double(attempt) * 1.5))
                continue
            }
            throw err
        }
    }

    static func parseError(status: Int, data: Data) -> BoatAPIError {
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let inner = obj["error"] as? [String: Any]
        let code = obj["code"] as? String ?? inner?["code"] as? String
        var message = obj["message"] as? String ?? inner?["message"] as? String
            ?? String(decoding: data.prefix(300), as: UTF8.self)
        if message.isEmpty { message = "HTTP \(status)" }
        let details = inner?["details"] as? [String: Any]
        let url = details?["setupUrl"] as? String ?? details?["billingUrl"] as? String ?? obj["url"] as? String
        if status == 401 { message = "boat.dev rejected the API key (\(message)). Update it in Settings → Sandbox Providers." }
        return BoatAPIError(status: status, code: code, message: message, url: url)
    }
}

/// Minimal generic-password Keychain access.
enum Keychain {
    static func read(service: String, account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(service: String, account: String, value: String) {
        delete(service: service, account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(service: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
