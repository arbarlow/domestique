import DQCore
import Foundation
import RaceRadioKit

/// Thread-safe view of Settings → Team Cars, for `Hosts.teamCarResolver` (called off the main actor
/// whenever git, a task or a terminal needs a workspace's host).
final class TeamCarDirectory: @unchecked Sendable {  // guarded by `lock`
    static let shared = TeamCarDirectory()
    private let lock = NSLock()
    private var cars: [UUID: TeamCarConfig] = [:]
    private var hosts: [UUID: TeamCarHost] = [:]

    func update(_ list: [TeamCarConfig]) {
        lock.withLock {
            cars = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            hosts = [:]  // URL or token may have changed
        }
    }

    func host(for h: WorkspaceHost) -> (any ExecutionHost)? {
        guard let id = UUID(uuidString: h.machineID) else { return nil }
        return lock.withLock {
            if let host = hosts[id] { return host }
            guard let cfg = cars[id] else { return nil }
            let host = TeamCarHost(carID: id, name: cfg.name, url: cfg.url, token: TeamCarTokens.get(id))
            hosts[id] = host
            return host
        }
    }
}
