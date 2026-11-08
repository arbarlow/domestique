import Foundation
import Synchronization
import Testing

@testable import HostKit

/// Records calls; answers like a server would.
private final class FakeBackend: SandboxBackend {
    let calls = Mutex<[String]>([])
    private func note(_ s: String) { calls.withLock { $0.append(s) } }

    func sandbox(_ id: String) async throws -> BoatSandbox {
        note("get \(id)")
        if id == "bx_gone" { throw BoatAPIError(status: 404, code: "domestique_notFound", message: "gone") }
        return BoatSandbox(id: id, state: "idle")
    }
    func list() async throws -> [BoatSandbox] { note("list"); return [] }
    func create(_ request: BoatCreateRequest, idempotencyKey: String) async throws -> String {
        note("create \(request.name ?? "") \(request.from ?? "-") \(idempotencyKey)")
        return "bx_new"
    }
    func stop(_ id: String) async throws { note("stop \(id)") }
    func resume(_ id: String, ttlSeconds: Int?) async throws { note("resume \(id) \(ttlSeconds.map(String.init) ?? "keep")") }
    func setAutoStop(_ id: String, ttlSeconds: Int?) async throws { note("autostop \(id)") }
    func rename(_ id: String, name: String) async throws { note("rename \(id) \(name)") }
    func delete(_ id: String) async throws { note("delete \(id)") }
    func recover(_ id: String) async throws { note("recover \(id)") }
    func sshAccess(_ id: String, publicKey: String) async throws -> BoatSSHAccess {
        note("ssh \(id)")
        return BoatSSHAccess(machineIp: "10.0.0.1", sshUser: "user", sshEndpoint: nil, hostKey: "ssh-ed25519 AAAA")
    }
    func desktopURL(_ id: String, dark: Bool?) async throws -> URL { URL(string: "https://desk.example")! }
    func hostedURL(_ id: String, port: Int, public isPublic: Bool, title: String?) async throws -> URL {
        URL(string: "https://\(port).example")!
    }
    func me() async throws -> BoatUser { BoatUser(login: "session", email: nil, displayName: nil) }
    func limits() async throws -> BoatLimits { BoatLimits(canStart: true, trialLine: nil, startBlockedReason: nil, machineTypes: nil) }
}

/// `BoatClient.routing` is process-wide, so these run one at a time and reset it.
@Suite(.serialized) struct SandboxRoutingTests {
    @Test func routedProvidersNeverUseTheLocalKey() async throws {
        let fake = FakeBackend()
        let account = "api-key.routing-test-\(UUID().uuidString)"
        let usable = Mutex(false)
        BoatClient.routing = SandboxRouting(
            backend: { $0 == account ? fake : nil },
            isConfigured: { $0 == account && usable.withLock { $0 } })
        defer { BoatClient.routing = nil }

        // Configured follows the server (connected + has a key), not this Mac's Keychain.
        #expect(!BoatClient.isConfigured(account: account))
        usable.withLock { $0 = true }
        #expect(BoatClient.isConfigured(account: account))

        let c = BoatClient(account: account)
        #expect(try await c.sandbox("bx_1").phase == .running)
        let id = try await c.create(
            BoatCreateRequest(name: "stride · galibier", type: "large", ttlSeconds: nil, environment: nil, from: "stride", labels: nil),
            idempotencyKey: "ws-1")
        #expect(id == "bx_new")
        try await c.resume("bx_1")
        try await c.stop("bx_1")
        try await c.delete("bx_1")
        #expect(try await c.sshAccess("bx_1", publicKey: "ssh-ed25519 me").hostKey.hasPrefix("ssh-ed25519"))
        #expect(try await c.me().login == "session")
        #expect(fake.calls.withLock { $0 } == [
            "get bx_1", "create stride · galibier stride ws-1", "resume bx_1 keep", "stop bx_1", "delete bx_1", "ssh bx_1",
        ])

        // A server's NOT_FOUND arrives as a 404, so "deleted on boat.dev" handling still works.
        let e = await #expect(throws: BoatAPIError.self) { try await c.sandbox("bx_gone") }
        #expect(e?.status == 404)
    }

    @Test func otherProvidersStayDirect() {
        BoatClient.routing = SandboxRouting(backend: { _ in nil }, isConfigured: { _ in true })
        defer { BoatClient.routing = nil }
        // No route: the answer comes from this Mac's credentials, whatever routing.isConfigured says.
        let account = "api-key.unrouted-\(UUID().uuidString)"
        #expect(BoatClient.isConfigured(account: account) == (BoatClient.credential(account: account) != nil))
    }

    @Test func createRequestSendsSnapshotAndNeverAutoStop() throws {
        let r = BoatCreateRequest(name: "n", type: "large", ttlSeconds: 3600, disableAutoStop: true, environment: "base", from: "stride", labels: nil)
        let obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        #expect(obj["from"] as? String == "stride")
        #expect(obj["environment"] as? String == "base")
        // disableAutoStop is spelled `"ttlSeconds": null`.
        #expect(obj.keys.contains("ttlSeconds") && obj["ttlSeconds"] is NSNull)
        let fresh = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(BoatCreateRequest(name: nil, type: nil, ttlSeconds: 60, environment: nil, labels: nil)))
                as? [String: Any])
        #expect(fresh["from"] == nil && fresh["ttlSeconds"] as? Int == 60)
    }
}
