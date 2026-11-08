import Foundation
import Observation
import ServerKit
import Security

/// A server the phone knows about. The token lives in the Keychain, never here.
struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// `ws://` or `wss://`; the `/domestique/v1` path is added when missing.
    var url: String
}

/// A `domestique://add-server?url=…&token=…&name=…` link, from the Mac app's QR code. It only ever prefills
/// the add-server form: any website can open this scheme, so connecting stays a deliberate tap.
struct ServerLink: Hashable {
    var url: String
    var token: String
    var name: String

    init?(_ link: URL) {
        guard link.scheme == "domestique", link.host == "add-server",
            let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
            let url = items.first(where: { $0.name == "url" })?.value, !url.isEmpty
        else { return nil }
        self.url = url
        token = items.first { $0.name == "token" }?.value ?? ""
        name = items.first { $0.name == "name" }?.value ?? ""
    }
}

/// Every server on this phone, and one live connection per server.
@MainActor @Observable
final class ServerList {
    private(set) var servers: [ServerConfig] = []
    private var connections: [UUID: ServerConnection] = [:]

    private static let defaultsKey = "dq.cars"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let saved = try? JSONDecoder().decode([ServerConfig].self, from: data)
        {
            servers = saved
        }
        for server in servers { connection(for: server).start() }
    }

    func connection(for server: ServerConfig) -> ServerConnection {
        if let c = connections[server.id] { return c }
        let c = ServerConnection(config: server, token: ServerTokens.get(server.id))
        connections[server.id] = c
        return c
    }

    var allConnections: [ServerConnection] { servers.map(connection(for:)) }

    func connection(id: UUID) -> ServerConnection? {
        servers.first { $0.id == id }.map(connection(for:))
    }

    /// Saves a server (new or edited) and (re)connects to it.
    func save(_ server: ServerConfig, token: String?) throws {
        if let token { try ServerTokens.set(token, for: server.id) }
        if let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i] = server } else { servers.append(server) }
        persist()
        connections.removeValue(forKey: server.id)?.stop()
        connection(for: server).start()
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        connections.removeValue(forKey: id)?.stop()
        ServerTokens.delete(id)
        persist()
    }

    func move(from: IndexSet, to: Int) {
        servers.move(fromOffsets: from, toOffset: to)
        persist()
    }

    /// Back in the foreground: connections iOS tore down while suspended reconnect now, not after backoff.
    func wake() {
        for c in connections.values { c.wake() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    /// Stable per install; lets a server tell a reconnect from a new client.
    static var clientID: String {
        let key = "dq.clientID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "iphone-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static var clientName: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Domestique for iPhone \(version)"
    }

    /// Parses what the user typed into a Domestique protocol endpoint.
    static func endpoint(for url: String) throws -> ServerEndpoint {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "ws://" + text }
        guard let u = URL(string: text), let scheme = u.scheme?.lowercased(), ["ws", "wss", "http", "https"].contains(scheme),
            u.host != nil
        else {
            throw ServerError(code: .invalidArgument, message: "Use a ws:// or wss:// URL, like ws://100.64.0.5:7420")
        }
        return .url(u)
    }

    /// "Connect" in the add-server form: handshake and server info, then hang up.
    static func test(url: String, token: String) async throws -> Proto_ServerInfo {
        let c = ServerClient(endpoint: try endpoint(for: url), token: token, clientName: clientName, clientID: clientID)
        defer { Task { await c.close() } }
        _ = try await c.connect()
        return try await c.serverInfo()
    }
}

/// Server tokens in the Keychain, one item per server (this device only, available after first unlock so
/// background refreshes can reconnect).
enum ServerTokens {
    private static let service = "Domestique Team Car"

    private static func match(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    static func get(_ id: UUID) -> String? {
        var q = match(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ token: String, for id: UUID) throws {
        let data = Data(token.utf8)
        var status = SecItemUpdate(match(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match(id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't save the token in the Keychain (\(status)).",
            ])
        }
    }

    static func delete(_ id: UUID) {
        SecItemDelete(match(id) as CFDictionary)
    }
}
