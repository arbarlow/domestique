import Foundation
import SwiftProtobuf
import Synchronization

// MARK: - Public types

/// Where a server listens.
public enum ServerEndpoint: Sendable, Hashable, CustomStringConvertible {
    /// A local server's Unix socket (no token needed; the socket is 0600).
    case unix(path: String)
    /// `ws://host:port` or `wss://host:port` (`http`/`https` are accepted too). The path defaults to `/domestique/v1`.
    case url(URL)

    /// The WebSocket URL for `.url` endpoints, with the default path filled in. nil for `.unix` or an unsupported scheme.
    public var webSocketURL: URL? {
        guard case .url(let url) = self, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch c.scheme?.lowercased() {
        case "ws", "http": c.scheme = "ws"
        case "wss", "https": c.scheme = "wss"
        default: return nil
        }
        if c.path.isEmpty || c.path == "/" { c.path = "/radio/v1" }
        return c.url
    }

    public var description: String {
        switch self {
        case .unix(let path): "unix://\(path)"
        case .url(let url): url.absoluteString
        }
    }
}

public enum ServerConnectionState: Sendable, Equatable {
    case connecting
    case connected(Proto_Welcome)
    /// Why; the client keeps reconnecting unless it was closed or the token was rejected.
    case disconnected(String)
}

/// An error response from the server, or a local failure: `.unavailable` when the connection dropped
/// (retry; set an idempotency key on requests that create things), `.protocol` for a bad frame.
public struct ServerError: Error, LocalizedError, Sendable, Equatable {
    public var code: Proto_ErrorCode
    public var message: String
    /// True when the error came from this client (disconnect, timeout) rather than a server response.
    public var isLocal: Bool

    public init(code: Proto_ErrorCode, message: String) {
        self.init(code: code, message: message, local: false)
    }

    init(code: Proto_ErrorCode, message: String, local: Bool) {
        self.code = code
        self.message = message
        self.isLocal = local
    }

    init(_ error: Proto_Error) { self.init(code: error.code, message: error.message) }

    static func disconnected(_ message: String) -> ServerError { .init(code: .unavailable, message: message, local: true) }
    static func protocolError(_ message: String) -> ServerError { .init(code: .protocol, message: message, local: true) }
    static let closed = ServerError(code: .unavailable, message: "Server client closed", local: true)

    public var errorDescription: String? { message.isEmpty ? "Server error \(code)" : message }
}

// MARK: - Client

/// A Domestique protocol client. One connection multiplexes every request and subscription.
///
/// After the first successful `connect()` the client reconnects with backoff whenever the connection drops,
/// and resubscribes every live subscription: server subscriptions get a fresh `ServerSnapshot` (treat it as
/// a replacement), session subscriptions resume after the last seq they delivered. Requests in flight during
/// a drop fail with `ServerError(.unavailable)`.
public actor ServerClient {
    public let endpoint: ServerEndpoint
    private let token: String?
    private let clientName: String
    private let clientID: String

    static let pingInterval: Duration = .seconds(15)
    static let deadAfter: Duration = .seconds(45)
    static let handshakeTimeout: Duration = .seconds(10)
    /// How long a request waits for a connection while the client is reconnecting.
    static let connectWait: Duration = .seconds(10)
    static let maxBackoff: Duration = .seconds(10)

    private let broadcaster = StateBroadcaster()

    private var transport: WebSocketTransport?
    /// Bumped on every attach; stale read loops and heartbeats check it.
    private var generation = 0
    private var welcome: Proto_Welcome?
    private var started = false
    private var closed = false
    /// Set when the client gave up (closed, or the token was rejected).
    private var terminalError: ServerError?
    private var lastReceived = ContinuousClock.now
    private var nextRequestID: UInt64 = 0
    private var nextPingNonce: UInt64 = 0
    private var pending: [UInt64: Pending] = [:]
    private var connectWaiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private var nextWaiterID: UInt64 = 0
    /// Every live subscription.
    private var subscriptions: [ObjectIdentifier: ServerSubscription] = [:]
    /// Subscriptions registered on the current connection, by server subscription id.
    private var bySubID: [UInt64: ServerSubscription] = [:]
    /// Subscriptions with a Subscribe request in flight (prevents double subscribing).
    private var subscribing: Set<ObjectIdentifier> = []
    private var runTask: Task<Void, Never>?

    private struct Pending {
        var continuation: CheckedContinuation<Proto_Response, any Error>
        /// Registered in the read loop before the response is delivered, so no event can beat it.
        var subscription: ServerSubscription?
    }

    public init(endpoint: ServerEndpoint, token: String? = nil, clientName: String, clientID: String) {
        self.endpoint = endpoint
        self.token = token
        self.clientName = clientName
        self.clientID = clientID
    }

    /// Each call returns a new stream that starts with the current state.
    public nonisolated var states: AsyncStream<ServerConnectionState> { broadcaster.stream() }

    /// The latest handshake answer, while connected.
    public var currentWelcome: Proto_Welcome? { welcome }

    /// Performs the first handshake. Afterwards the client reconnects on its own until `close()`.
    @discardableResult
    public func connect() async throws -> Proto_Welcome {
        if closed { throw terminalError ?? ServerError.closed }
        if let welcome, transport != nil { return welcome }
        if started {
            try await waitConnected()
            guard let welcome else { throw ServerError.disconnected("Not connected") }
            return welcome
        }
        started = true
        broadcaster.set(.connecting)
        do {
            let (t, w) = try await handshake()
            if closed {
                t.close()
                throw ServerError.closed
            }
            attach(t, w)
            let gen = generation
            runTask = Task { await self.run(t, generation: gen) }
            return w
        } catch {
            started = false
            let e = error as? ServerError ?? ServerError.disconnected(error.localizedDescription)
            broadcaster.set(.disconnected(e.message))
            throw e
        }
    }

    /// Disconnects and ends every subscription. The client can't be reused.
    public func close() {
        guard !closed else { return }
        closed = true
        terminalError = terminalError ?? ServerError.closed
        runTask?.cancel()
        runTask = nil
        transport?.close()
        transport = nil
        generation += 1
        failPending(ServerError.closed)
        finishAllSubscriptions()
        broadcaster.set(.disconnected("Closed"))
        broadcaster.finish()
    }

    // MARK: Requests

    /// Sends a request and waits for its response. Throws `ServerError` for error responses and disconnects.
    public func send(_ command: Proto_Request.OneOf_Command, idempotencyKey: String? = nil) async throws -> Proto_Response {
        try await request(command, idempotencyKey: idempotencyKey, subscription: nil)
    }

    private func request(
        _ command: Proto_Request.OneOf_Command, idempotencyKey: String?, subscription: ServerSubscription?
    ) async throws -> Proto_Response {
        try await waitConnected()
        guard let transport else { throw ServerError.disconnected("Not connected") }
        nextRequestID += 1
        let id = nextRequestID
        var req = Proto_Request()
        req.id = id
        req.command = command
        if let idempotencyKey { req.idempotencyKey = idempotencyKey }
        var frame = Proto_ClientFrame()
        frame.request = req
        let data = try frame.serializedData()

        let response: Proto_Response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Proto_Response, any Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                pending[id] = Pending(continuation: cont, subscription: subscription)
                let gen = generation
                // Enqueued synchronously so requests hit the wire in call order.
                transport.send(data) { error in
                    guard let error else { return }
                    Task { await self.writeFailed(error, transport: transport, generation: gen, request: id) }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
        if case .error(let e) = response.result { throw ServerError(e) }
        return response
    }

    private func writeFailed(_ error: ServerError, transport: WebSocketTransport, generation gen: Int, request id: UInt64) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: error)
        if gen == generation { transport.cancel() }
    }

    private func cancelRequest(_ id: UInt64) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    /// Waits (bounded) for a connection while reconnecting.
    private func waitConnected() async throws {
        if let terminalError { throw terminalError }
        if transport != nil { return }
        guard started else { throw ServerError.disconnected("Not connected; call connect() first") }
        nextWaiterID += 1
        let id = nextWaiterID
        let timeout = Task {
            try? await Task.sleep(for: Self.connectWait)
            self.resumeWaiter(id, with: .failure(ServerError.disconnected("Server is unreachable (\(self.endpoint))")))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                connectWaiters[id] = cont
            }
        } onCancel: {
            Task { await self.resumeWaiter(id, with: .failure(CancellationError())) }
        }
    }

    private func resumeWaiter(_ id: UInt64, with result: Result<Void, any Error>) {
        connectWaiters.removeValue(forKey: id)?.resume(with: result)
    }

    private func resumeAllWaiters(_ result: Result<Void, any Error>) {
        let waiters = connectWaiters
        connectWaiters = [:]
        for (_, w) in waiters { w.resume(with: result) }
    }

    // MARK: Connection lifecycle

    private func handshake() async throws -> (WebSocketTransport, Proto_Welcome) {
        let t = try await WebSocketTransport.open(endpoint, timeout: Self.handshakeTimeout)
        do {
            var hello = Proto_Hello()
            hello.protocolVersion = .protocolVersion1
            hello.clientID = clientID
            hello.clientName = clientName
            if let token { hello.token = token }
            var frame = Proto_ClientFrame()
            frame.hello = hello
            try await t.send(frame.serializedData())
            let welcome = try await withThrowingTaskGroup(of: Proto_Welcome.self) { group in
                group.addTask {
                    while true {
                        guard case .binary(let data) = try await t.receive() else { continue }
                        let f = try Self.decode(data)
                        switch f.frame {
                        case .welcome(let w): return w
                        case .goodbye(let g): throw ServerError(code: g.code, message: g.message)
                        default: throw ServerError.protocolError("Expected Welcome, got \(String(describing: f.frame))")
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: Self.handshakeTimeout)
                    throw ServerError.disconnected("Timed out waiting for Welcome from \(self.endpoint)")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            return (t, welcome)
        } catch {
            t.cancel()
            throw error
        }
    }

    private static func decode(_ data: Data) throws -> Proto_ServerFrame {
        do {
            return try Proto_ServerFrame(serializedBytes: data)
        } catch {
            throw ServerError.protocolError("Malformed frame from the server: \(error)")
        }
    }

    private func attach(_ t: WebSocketTransport, _ w: Proto_Welcome) {
        transport = t
        welcome = w
        generation += 1
        lastReceived = .now
        broadcaster.set(.connected(w))
        resumeAllWaiters(.success(()))
        let gen = generation
        Task { await self.heartbeat(generation: gen) }
    }

    /// Reads frames, and reconnects when the connection drops, until closed.
    private func run(_ first: WebSocketTransport, generation firstGen: Int) async {
        var t = first
        var gen = firstGen
        while true {
            let reason = await readLoop(t, generation: gen)
            guard gen == generation, !closed else { return }
            detach(reason)
            guard let (next, w) = await reconnect() else { return }
            attach(next, w)
            t = next
            gen = generation
            resubscribeAll()
        }
    }

    private func readLoop(_ t: WebSocketTransport, generation gen: Int) async -> ServerError {
        while true {
            do {
                let message = try await t.receive()
                guard gen == generation else { return ServerError.disconnected("Superseded") }
                lastReceived = .now
                guard case .binary(let data) = message else { continue }
                let frame = try Self.decode(data)
                if let goodbye = handle(frame) { return goodbye }
            } catch {
                return error as? ServerError ?? ServerError.disconnected(error.localizedDescription)
            }
        }
    }

    /// Handles one server frame. Returns an error when the server said Goodbye.
    private func handle(_ frame: Proto_ServerFrame) -> ServerError? {
        switch frame.frame {
        case .response(let resp):
            guard let p = pending.removeValue(forKey: resp.id) else { return nil }
            if let sub = p.subscription, case .subscribe(let result) = resp.result {
                register(sub, serverID: result.subscriptionID)
            }
            p.continuation.resume(returning: resp)
        case .event(let ev):
            bySubID[ev.subscriptionID]?.deliver(ev)
        case .gap(let gap):
            if let sub = bySubID.removeValue(forKey: gap.subscriptionID) {
                sub.unbind()
                Task { await self.resubscribe(sub) }
            }
        case .goodbye(let g):
            return ServerError(code: g.code, message: g.message.isEmpty ? "Server said goodbye" : g.message)
        case .pong, .welcome, nil:
            break
        }
        return nil
    }

    private func heartbeat(generation gen: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pingInterval)
            guard gen == generation, let t = transport, !closed else { return }
            if ContinuousClock.now - lastReceived > Self.deadAfter {
                // Silence: assume the connection is dead. The read loop sees the cancel and reconnects.
                t.cancel()
                return
            }
            nextPingNonce += 1
            var ping = Proto_Ping()
            ping.nonce = nextPingNonce
            var frame = Proto_ClientFrame()
            frame.ping = ping
            if let data = try? frame.serializedData() {
                do { try await t.send(data) } catch {
                    if gen == generation { t.cancel() }
                    return
                }
            }
        }
    }

    /// Fails in-flight requests and forgets server subscription ids; subscriptions stay live.
    private func detach(_ reason: ServerError) {
        transport?.cancel()
        transport = nil
        welcome = nil
        generation += 1
        failPending(ServerError.disconnected("Disconnected: \(reason.message)"))
        for sub in bySubID.values { sub.unbind() }
        bySubID = [:]
        broadcaster.set(.disconnected(reason.message))
    }

    private func reconnect() async -> (WebSocketTransport, Proto_Welcome)? {
        var attempt = 0
        while !closed {
            let cap = Self.maxBackoff / .milliseconds(1)
            let base = min(cap, 200 * pow(2, Double(min(attempt, 16))))
            let delay = base / 2 + Double.random(in: 0...(base / 2))
            attempt += 1
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return nil }
            if closed { return nil }
            broadcaster.set(.connecting)
            do {
                let result = try await handshake()
                if closed {
                    result.0.close()
                    return nil
                }
                return result
            } catch let e as ServerError where e.code == .unauthenticated && !e.isLocal {
                terminate(e)
                return nil
            } catch {
                let e = error as? ServerError ?? ServerError.disconnected(error.localizedDescription)
                broadcaster.set(.disconnected(e.message))
            }
        }
        return nil
    }

    /// Gives up for good (the token was rejected).
    private func terminate(_ error: ServerError) {
        terminalError = error
        closed = true
        failPending(error)
        resumeAllWaiters(.failure(error))
        finishAllSubscriptions()
        broadcaster.set(.disconnected(error.message))
        broadcaster.finish()
    }

    private func failPending(_ error: ServerError) {
        let p = pending
        pending = [:]
        for (_, req) in p { req.continuation.resume(throwing: error) }
        if closed { resumeAllWaiters(.failure(error)) }
    }

    private func finishAllSubscriptions() {
        let subs = subscriptions.values
        subscriptions = [:]
        bySubID = [:]
        for s in subs { s.finish() }
    }

    // MARK: Subscriptions

    /// Repositories, workspaces and sessions. Starts with a `ServerSnapshot`; after a reconnect a new snapshot
    /// arrives, which replaces everything.
    public func subscribeServer() async throws -> ServerSubscription {
        var sub = Proto_Subscribe()
        sub.server = Proto_ServerTarget()
        return try await newSubscription(sub, kind: .server)
    }

    /// One session: items persisted after `fromSeq` (display order), `ReplayDone`, then live events.
    public func subscribeSession(_ sessionID: String, fromSeq: UInt64 = 0, coalesceMs: UInt32 = 0) async throws -> ServerSubscription {
        var target = Proto_SessionTarget()
        target.sessionID = sessionID
        target.fromSeq = fromSeq
        target.coalesceMs = coalesceMs
        var sub = Proto_Subscribe()
        sub.session = target
        return try await newSubscription(sub, kind: .session(fromSeq: fromSeq))
    }

    private func newSubscription(_ target: Proto_Subscribe, kind: ServerSubscription.Kind) async throws -> ServerSubscription {
        if let terminalError { throw terminalError }
        let sub = ServerSubscription(client: self, target: target, kind: kind)
        let key = ObjectIdentifier(sub)
        subscriptions[key] = sub
        subscribing.insert(key)
        defer { subscribing.remove(key) }
        do {
            try await subscribe(sub)
            return sub
        } catch {
            subscriptions.removeValue(forKey: key)
            sub.finish()
            throw error
        }
    }

    private func subscribe(_ sub: ServerSubscription) async throws {
        _ = try await request(.subscribe(sub.currentTarget), idempotencyKey: nil, subscription: sub)
    }

    private func register(_ sub: ServerSubscription, serverID: UInt64) {
        guard subscriptions[ObjectIdentifier(sub)] != nil else {
            // Cancelled while the Subscribe was in flight: drop it on the server too.
            Task { try? await self.unsubscribe(serverID: serverID) }
            return
        }
        bySubID[serverID] = sub
        sub.bind(serverID: serverID)
    }

    private func resubscribeAll() {
        for sub in subscriptions.values {
            Task { await self.resubscribe(sub) }
        }
    }

    private func resubscribe(_ sub: ServerSubscription) async {
        let key = ObjectIdentifier(sub)
        guard !subscribing.contains(key) else { return }
        subscribing.insert(key)
        defer { subscribing.remove(key) }
        var attempt = 0
        while !closed, subscriptions[key] != nil, sub.serverID == nil {
            // Not connected: the reconnect resubscribes everything.
            guard transport != nil else { return }
            let gen = generation
            do {
                try await subscribe(sub)
                return
            } catch let e as ServerError where !e.isLocal {
                // The server refused (e.g. the session was closed): the subscription is over.
                subscriptions.removeValue(forKey: key)
                sub.finish()
                return
            } catch {
                if gen == generation {
                    // Same connection still up (e.g. a send hiccup): back off and retry.
                    attempt += 1
                    try? await Task.sleep(for: .milliseconds(250 * min(attempt, 20)))
                }
            }
        }
    }

    /// Called by `ServerSubscription.cancel()`.
    func remove(_ sub: ServerSubscription) async {
        subscriptions.removeValue(forKey: ObjectIdentifier(sub))
        guard let id = sub.serverID else { return }
        if bySubID[id] === sub { bySubID.removeValue(forKey: id) }
        sub.unbind()
        try? await unsubscribe(serverID: id)
    }

    private func unsubscribe(serverID: UInt64) async throws {
        guard transport != nil else { return }
        var u = Proto_Unsubscribe()
        u.subscriptionID = serverID
        _ = try await send(.unsubscribe(u))
    }

    // MARK: Typed requests

    public func serverInfo() async throws -> Proto_ServerInfo {
        let r = try await send(.getServerInfo(Proto_GetServerInfo()))
        guard case .serverInfo(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func listRepositories() async throws -> [Proto_Repository] {
        let r = try await send(.listRepositories(Proto_ListRepositories()))
        guard case .repositories(let v) = r.result else { throw unexpected(r) }
        return v.repositories
    }

    public func addRepository(_ req: Proto_AddRepository) async throws -> Proto_Repository {
        let r = try await send(.addRepository(req))
        guard case .repository(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func removeRepository(id: String) async throws {
        var req = Proto_RemoveRepository()
        req.repositoryID = id
        _ = try await send(.removeRepository(req))
    }

    public func listWorkspaces(repositoryID: String = "", includeArchived: Bool = false) async throws -> [Proto_Workspace] {
        var req = Proto_ListWorkspaces()
        req.repositoryID = repositoryID
        req.includeArchived = includeArchived
        let r = try await send(.listWorkspaces(req))
        guard case .workspaces(let v) = r.result else { throw unexpected(r) }
        return v.workspaces
    }

    public func createWorkspace(_ req: Proto_CreateWorkspace, idempotencyKey: String? = nil) async throws -> Proto_Workspace {
        let r = try await send(.createWorkspace(req), idempotencyKey: idempotencyKey)
        guard case .workspace(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func archiveWorkspace(_ req: Proto_ArchiveWorkspace) async throws -> Proto_Workspace {
        let r = try await send(.archiveWorkspace(req))
        guard case .workspace(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func deleteWorkspace(_ req: Proto_DeleteWorkspace) async throws {
        _ = try await send(.deleteWorkspace(req))
    }

    public func importWorkspace(_ req: Proto_ImportWorkspace) async throws -> Proto_Workspace {
        let r = try await send(.importWorkspace(req))
        guard case .workspace(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func openSession(_ req: Proto_OpenSession) async throws -> Proto_Session {
        let r = try await send(.openSession(req))
        guard case .session(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func closeSession(id: String) async throws {
        var req = Proto_CloseSession()
        req.sessionID = id
        _ = try await send(.closeSession(req))
    }

    public func sendMessage(sessionID: String, text: String, attachments: [Proto_Attachment] = []) async throws {
        var req = Proto_SendMessage()
        req.sessionID = sessionID
        req.text = text
        req.attachments = attachments
        _ = try await send(.sendMessage(req))
    }

    public func interrupt(sessionID: String) async throws {
        var req = Proto_Interrupt()
        req.sessionID = sessionID
        _ = try await send(.interrupt(req))
    }

    public func respondApproval(sessionID: String, requestID: String, decision: Proto_Decision, message: String = "") async throws {
        var req = Proto_RespondApproval()
        req.sessionID = sessionID
        req.requestID = requestID
        req.decision = decision
        req.message = message
        _ = try await send(.respondApproval(req))
    }

    public func answerQuestion(sessionID: String, requestID: String, answers: [String: String]) async throws {
        var req = Proto_AnswerQuestion()
        req.sessionID = sessionID
        req.requestID = requestID
        req.answers = answers
        _ = try await send(.answerQuestion(req))
    }

    public func updateSession(_ req: Proto_UpdateSession) async throws -> Proto_Session {
        let r = try await send(.updateSession(req))
        guard case .session(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func listModels(_ provider: Proto_Provider) async throws -> [Proto_ModelOption] {
        var req = Proto_ListModels()
        req.provider = provider
        let r = try await send(.listModels(req))
        guard case .models(let v) = r.result else { throw unexpected(r) }
        return v.models
    }

    public func transcript(sessionID: String, afterSeq: UInt64 = 0, limit: UInt32 = 0) async throws -> Proto_TranscriptPage {
        var req = Proto_GetTranscript()
        req.sessionID = sessionID
        req.afterSeq = afterSeq
        req.limit = limit
        let r = try await send(.getTranscript(req))
        guard case .transcript(let v) = r.result else { throw unexpected(r) }
        return v
    }

    // MARK: Tokens (admin scope)

    /// The secret in the result is shown once; only its hash is stored.
    public func createToken(name: String, scope: Proto_TokenScope) async throws -> Proto_CreatedToken {
        var req = Proto_CreateToken()
        req.name = name
        req.scope = scope
        let r = try await send(.createToken(req))
        guard case .createdToken(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func listTokens() async throws -> [Proto_TokenInfo] {
        let r = try await send(.listTokens(Proto_ListTokens()))
        guard case .tokens(let v) = r.result else { throw unexpected(r) }
        return v.tokens
    }

    public func revokeToken(id: String) async throws {
        var req = Proto_RevokeToken()
        req.tokenID = id
        _ = try await send(.revokeToken(req))
    }

    // MARK: Code

    /// The workspace's changes against its merge base. `path` limits it to one file.
    public func diff(workspaceID: String, path: String = "") async throws -> Proto_Diff {
        var req = Proto_GetDiff()
        req.workspaceID = workspaceID
        req.path = path
        let r = try await send(.getDiff(req))
        guard case .diff(let v) = r.result else { throw unexpected(r) }
        return v
    }

    // MARK: Sandboxes

    /// The server's sandbox providers (never their keys). `checkAccount` also reads each account.
    public func sandboxProviders(checkAccount: Bool = false) async throws -> [Proto_SandboxProvider] {
        var req = Proto_ListSandboxProviders()
        req.checkAccount = checkAccount
        let r = try await send(.listSandboxProviders(req))
        guard case .sandboxProviders(let v) = r.result else { throw unexpected(r) }
        return v.providers
    }

    /// Creates or replaces a provider (ADMIN). `apiKey` nil keeps the stored key; "" deletes it.
    public func saveSandboxProvider(_ provider: Proto_SandboxProvider, apiKey: String? = nil) async throws -> Proto_SandboxProvider {
        var req = Proto_SaveSandboxProvider()
        req.provider = provider
        if let apiKey { req.apiKey = apiKey }
        let r = try await send(.saveSandboxProvider(req))
        guard case .sandboxProvider(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func removeSandboxProvider(id: String) async throws {
        var req = Proto_RemoveSandboxProvider()
        req.providerID = id
        _ = try await send(.removeSandboxProvider(req))
    }

    // MARK: MCP servers

    /// The server's MCP servers (the names of their secrets, not the values).
    public func mcpServers() async throws -> [Proto_McpServer] {
        let r = try await send(.listMcpServers(Proto_ListMcpServers()))
        guard case .mcpServers(let v) = r.result else { throw unexpected(r) }
        return v.servers
    }

    /// Creates or replaces a server (ADMIN). Secrets the request doesn't mention keep their values.
    public func saveMcpServer(_ req: Proto_SaveMcpServer) async throws -> Proto_McpServer {
        let r = try await send(.saveMcpServer(req))
        guard case .mcpServer(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func removeMcpServer(id: String) async throws {
        var req = Proto_RemoveMcpServer()
        req.serverID = id
        _ = try await send(.removeMcpServer(req))
    }

    /// Every enabled server, secrets included, as a Claude `--mcp-config` file.
    public func resolveMcpConfig() async throws -> Proto_McpConfig {
        let r = try await send(.resolveMcpConfig(Proto_ResolveMcpConfig()))
        guard case .mcpConfig(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func sandboxes(providerID: String) async throws -> [Proto_Sandbox] {
        var req = Proto_ListSandboxes()
        req.providerID = providerID
        let r = try await send(.listSandboxes(req))
        guard case .sandboxes(let v) = r.result else { throw unexpected(r) }
        return v.sandboxes
    }

    public func sandbox(providerID: String, sandboxID: String) async throws -> Proto_Sandbox {
        var req = Proto_GetSandbox()
        req.providerID = providerID
        req.sandboxID = sandboxID
        let r = try await send(.getSandbox(req))
        guard case .sandbox(let v) = r.result else { throw unexpected(r) }
        return v
    }

    /// Starts a sandbox. The idempotency key also reaches the sandbox service, so a retry never
    /// makes a second machine.
    public func createSandbox(_ req: Proto_CreateSandbox, idempotencyKey: String? = nil) async throws -> Proto_Sandbox {
        let r = try await send(.createSandbox(req), idempotencyKey: idempotencyKey)
        guard case .sandbox(let v) = r.result else { throw unexpected(r) }
        return v
    }

    public func changeSandbox(_ req: Proto_ChangeSandbox) async throws {
        _ = try await send(.changeSandbox(req))
    }

    /// Authorizes an SSH key, or returns a desktop or port URL (OPERATE).
    public func openSandboxAccess(_ req: Proto_OpenSandboxAccess) async throws -> Proto_SandboxAccess {
        let r = try await send(.openSandboxAccess(req))
        guard case .sandboxAccess(let v) = r.result else { throw unexpected(r) }
        return v
    }

    private func unexpected(_ r: Proto_Response) -> ServerError {
        .protocolError("Unexpected response: \(String(describing: r.result))")
    }
}

// MARK: - State fan-out

/// Holds the connection state for `nonisolated` readers and fans it out to every `states` stream.
final class StateBroadcaster: Sendable {
    private struct Inner {
        var state: ServerConnectionState = .disconnected("Not connected")
        var continuations: [UInt64: AsyncStream<ServerConnectionState>.Continuation] = [:]
        var nextID: UInt64 = 0
        var finished = false
    }

    private let inner = Mutex(Inner())

    func stream() -> AsyncStream<ServerConnectionState> {
        let (stream, cont) = AsyncStream<ServerConnectionState>.makeStream(bufferingPolicy: .unbounded)
        let id: UInt64? = inner.withLock { s in
            cont.yield(s.state)
            if s.finished { return nil }
            s.nextID += 1
            s.continuations[s.nextID] = cont
            return s.nextID
        }
        guard let id else {
            cont.finish()
            return stream
        }
        cont.onTermination = { [weak self] _ in
            _ = self?.inner.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    var current: ServerConnectionState { inner.withLock { $0.state } }

    func set(_ state: ServerConnectionState) {
        inner.withLock { s in
            guard !s.finished, s.state != state else { return }
            s.state = state
            for c in s.continuations.values { c.yield(state) }
        }
    }

    func finish() {
        let conts = inner.withLock { s -> [AsyncStream<ServerConnectionState>.Continuation] in
            s.finished = true
            defer { s.continuations = [:] }
            return Array(s.continuations.values)
        }
        for c in conts { c.finish() }
    }
}
