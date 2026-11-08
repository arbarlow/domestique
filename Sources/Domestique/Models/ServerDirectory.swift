import DQCore
import Foundation
import ServerKit

/// Thread-safe view of Settings → Servers, for `Hosts.serverResolver` (called off the main actor
/// whenever git, a task or a terminal needs a workspace's host).
final class ServerDirectory: @unchecked Sendable {  // guarded by `lock`
    static let shared = ServerDirectory()
    private let lock = NSLock()
    private var servers: [UUID: ServerConfig] = [:]
    private var hosts: [UUID: ServerHost] = [:]

    func update(_ list: [ServerConfig]) {
        lock.withLock {
            servers = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            hosts = [:]  // URL or token may have changed
        }
    }

    func host(for h: WorkspaceHost) -> (any ExecutionHost)? {
        guard let id = UUID(uuidString: h.machineID) else { return nil }
        return lock.withLock {
            if let host = hosts[id] { return host }
            guard let cfg = servers[id] else { return nil }
            let host = ServerHost(serverID: id, name: cfg.name, url: cfg.url, token: ServerTokens.get(id))
            hosts[id] = host
            return host
        }
    }
}
