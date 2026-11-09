import DQCore
import Foundation
import Testing
@testable import ServerKit

/// End-to-end against a real `domestique serve` (built from domestique/). No agents run: everything here works
/// without claude/codex.
@Suite(.enabled(if: ServerBuild.goAvailable, "go is not installed; skipping server integration tests"), .timeLimit(.minutes(2)))
struct IntegrationTests {
    let server: ServerServer

    init() async throws {
        server = try ServerServer()
        try await server.start()
    }

    func client(_ endpoint: ServerEndpoint? = nil, token: String? = nil) -> ServerClient {
        ServerClient(endpoint: endpoint ?? server.unix, token: token, clientName: "ServerKit tests", clientID: "rrk-\(UUID().protoID)")
    }

    // MARK: Handshake

    @Test func handshakeOverUnixSocket() async throws {
        defer { server.cleanup() }
        let c = client()
        let w = try await c.connect()
        #expect(w.protocolVersion == .protocolVersion1)
        #expect(w.serverName == "rrk-test")
        #expect(w.scope == .admin)
        #expect(!w.serverID.isEmpty)
        let info = try await c.serverInfo()
        #expect(info.serverID == w.serverID)
        #expect(info.workspacesRoot == server.workspacesRoot.path)
        await c.close()
    }

    // MARK: Sandbox providers

    @Test func sandboxProvidersLiveOnTheServer() async throws {
        defer { server.cleanup() }
        let c = client()
        _ = try await c.connect()
        #expect(try await c.sandboxProviders().isEmpty)

        var p = Proto_SandboxProvider()
        p.id = UUID().uuidString  // upper-case, as the app sends it
        p.kind = .boat
        p.name = "boat · large"
        p.defaults.machineType = "large"
        p.defaults.autoStopMinutes = 120
        p.defaults.fromSnapshot = "stride"
        let saved = try await c.saveSandboxProvider(p, apiKey: "boat_test_key")
        #expect(saved.id == p.id.lowercased())
        #expect(saved.credentialSource == .stored)

        // Listed (in ServerInfo too) with its defaults, never with the key.
        let info = try await c.serverInfo()
        #expect(info.sandboxProviders.map(\.name) == ["boat · large"])
        let listed = try #require(try await c.sandboxProviders().first)
        #expect(listed.defaults.fromSnapshot == "stride" && listed.defaults.autoStopMinutes == 120)
        #expect(!(try listed.serializedData().contains(Data("boat_test_key".utf8))))

        // A call that has to reach boat.dev fails as UNAVAILABLE (the harness points it at a closed
        // port), not as a bad server token.
        let e = await #expect(throws: ServerError.self) { try await c.sandboxes(providerID: p.id) }
        #expect(e?.code == .unavailable)

        try await c.removeSandboxProvider(id: p.id)
        #expect(try await c.sandboxProviders().isEmpty)
        let gone = await #expect(throws: ServerError.self) { try await c.sandbox(providerID: p.id, sandboxID: "bx_1") }
        #expect(gone?.code == .notFound)
        await c.close()
    }

    @Test func savingProvidersNeedsAdmin() async throws {
        defer { server.cleanup() }
        let token = try server.createToken(scope: "operate")
        let c = client(server.tcp, token: token)
        _ = try await c.connect()
        var p = Proto_SandboxProvider()
        p.id = UUID().uuidString
        p.kind = .boat
        p.name = "nope"
        let e = await #expect(throws: ServerError.self) { try await c.saveSandboxProvider(p, apiKey: "k") }
        #expect(e?.code == .permissionDenied)
        await c.close()
    }

    @Test func handshakeOverTCPWithToken() async throws {
        defer { server.cleanup() }
        let token = try server.createToken(scope: "admin")
        #expect(token.hasPrefix("dq_"))
        let c = client(server.tcp, token: token)
        let w = try await c.connect()
        #expect(w.scope == .admin)
        _ = try await c.serverInfo()
        await c.close()

        // An explicit path works too.
        let c2 = client(.url(URL(string: "ws://127.0.0.1:\(server.port)/domestique/v1")!), token: token)
        _ = try await c2.connect()
        await c2.close()
    }

    @Test func badTokenIsUnauthenticated() async throws {
        defer { server.cleanup() }
        let bad = client(server.tcp, token: "dq_nope")
        let e1 = await #expect(throws: ServerError.self) { try await bad.connect() }
        #expect(e1?.code == .unauthenticated)
        #expect(e1?.isLocal == false)

        let none = client(server.tcp)
        let e2 = await #expect(throws: ServerError.self) { try await none.connect() }
        #expect(e2?.code == .unauthenticated)

        // A failed first connect reports the state and leaves the client usable for another attempt.
        var states = bad.states.makeAsyncIterator()
        guard case .disconnected = await states.next() else { Issue.record("expected disconnected"); return }
    }

    @Test func unreachableServerFailsFast() async throws {
        defer { server.cleanup() }
        let c = client(.unix(path: server.root.appending(path: "nothing.sock").path))
        let e = await #expect(throws: ServerError.self) { try await c.connect() }
        #expect(e?.code == .unavailable)
        // Requests before a connection fail rather than hang.
        await #expect(throws: ServerError.self) { try await c.serverInfo() }
    }

    @Test func errorResponsesThrow() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let e = await #expect(throws: ServerError.self) { try await c.closeSession(id: UUID().protoID) }
        #expect(e?.code == .notFound)
        #expect(e?.isLocal == false)
        // Subscribing to a session that doesn't exist fails too.
        await #expect(throws: ServerError.self) { try await c.subscribeSession(UUID().protoID) }
        await c.close()
    }

    // MARK: Repositories, workspaces, sessions

    @Test func repositoryWorkspaceAndSessionFlow() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let path = try server.makeGitRepo()

        var add = Proto_AddRepository()
        add.path = path.path
        let repo = try await c.addRepository(add)
        #expect(repo.path == path.path)
        #expect(repo.defaultBranch == "main")
        #expect(repo.name == "demo")

        let sub = try await c.subscribeServer()
        let events = EventReader(sub)
        let first = try #require(try await events.next())
        let snap = try #require(first.snapshot, "first server event must be a snapshot")
        #expect(snap.repositories.map(\.id) == [repo.id])
        #expect(snap.workspaces.isEmpty)

        var create = Proto_CreateWorkspace()
        create.repositoryID = repo.id
        create.name = "galibier"
        let ws = try await c.createWorkspace(create, idempotencyKey: "create-1")
        #expect(ws.name == "galibier")
        #expect(ws.repositoryID == repo.id)
        // Same idempotency key: same workspace, not a second one.
        let again = try await c.createWorkspace(create, idempotencyKey: "create-1")
        #expect(again.id == ws.id)

        let ready = try await events.first {
            guard let w = $0.workspace, w.id == ws.id else { return false }
            return w.state == .ready || w.state == .failed
        }
        #expect(ready.workspace?.state == .ready, "workspace failed: \(ready.workspace?.failure ?? "")\n\(server.log)")
        #expect(FileManager.default.fileExists(atPath: ws.path))

        var open = Proto_OpenSession()
        open.workspaceID = ws.id
        open.provider = .codex
        open.permissionMode = .ask
        open.title = "Session one"
        let session = try await c.openSession(open)
        #expect(session.workspaceID == ws.id && session.provider == .codex && session.permissionMode == .ask && session.title == "Session one")
        let upserted = try await events.first { if case .sessionUpserted(let r) = $0.payload { r.id == session.id } else { false } }
        #expect(upserted.seq > first.seq)

        // A fresh server subscription's snapshot has everything.
        let sub2 = try await c.subscribeServer()
        let snap2 = try #require(try await EventReader(sub2).next()?.snapshot)
        #expect(snap2.repositories.map(\.id) == [repo.id])
        #expect(snap2.workspaces.map(\.id) == [ws.id])
        #expect(snap2.workspaces.first?.state == .ready)
        #expect(snap2.sessions.map(\.id) == [session.id])
        sub2.cancel()

        // A session with no transcript replays nothing, then ReplayDone.
        let sessionSub = try await c.subscribeSession(session.id)
        let replay = try #require(try await EventReader(sessionSub).next())
        #expect(replay.isReplayDone)

        var update = Proto_UpdateSession()
        update.sessionID = session.id
        update.title = "Renamed"
        let updated = try await c.updateSession(update)
        #expect(updated.title == "Renamed")

        try await c.closeSession(id: session.id)
        _ = try await events.first { if case .sessionRemoved(let id) = $0.payload { id == session.id } else { false } }

        var archive = Proto_ArchiveWorkspace()
        archive.workspaceID = ws.id
        let archived = try await c.archiveWorkspace(archive)
        #expect(archived.state == .archived)
        var delete = Proto_DeleteWorkspace()
        delete.workspaceID = ws.id
        try await c.deleteWorkspace(delete)
        _ = try await events.first { if case .workspaceRemoved(let id) = $0.payload { id == ws.id } else { false } }

        try await c.removeRepository(id: repo.id)
        _ = try await events.first { if case .repositoryRemoved(let id) = $0.payload { id == repo.id } else { false } }
        sub.cancel()
        sessionSub.cancel()
        await c.close()
    }

    @Test
    func clientChosenIDs() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        var add = Proto_AddRepository()
        add.path = try server.makeGitRepo().path
        let repoID = UUID().protoID
        add.id = repoID
        let repo = try await c.addRepository(add)
        #expect(repo.id == repoID)

        var create = Proto_CreateWorkspace()
        create.repositoryID = repo.id
        let wsID = UUID().protoID
        create.id = wsID
        let ws = try await c.createWorkspace(create)
        #expect(ws.id == wsID)

        var open = Proto_OpenSession()
        open.workspaceID = ws.id
        let sessionID = UUID().protoID
        open.id = sessionID
        let session = try await c.openSession(open)
        #expect(session.id == sessionID)
        await c.close()
    }

    // MARK: Import and replay

    static func importRequest(repoID: String, path: String, sessionID: String, items: [TranscriptItem]) -> Proto_ImportWorkspace {
        var ws = Proto_Workspace()
        ws.id = UUID().protoID
        ws.repositoryID = repoID
        ws.name = "imported"
        ws.branch = "main"
        ws.path = path
        ws.baseBranch = "main"
        ws.portBase = 41000
        ws.state = .ready
        ws.createdAtMs = Date.now.protoMs
        var session = Proto_Session()
        session.id = sessionID
        session.workspaceID = ws.id
        session.title = "Imported chat"
        session.provider = .claude
        session.permissionMode = .bypass
        session.createdAtMs = Date.now.protoMs
        var ir = Proto_ImportSession()
        ir.session = session
        ir.items = items.map(\.proto)
        var req = Proto_ImportWorkspace()
        req.workspace = ws
        req.sessions = [ir]
        return req
    }

    static func sampleItems(_ n: Int, prefix: String = "item") -> [TranscriptItem] {
        let base = Date(protoMs: 1_762_000_000_000)
        return (0..<n).map { i in
            let kind: TranscriptItem.Kind = switch i % 4 {
            case 0: .user(text: "question \(i)")
            case 1: .assistant(text: "answer \(i)")
            case 2: .tool(ToolCall(name: "Bash", summary: "ls", output: "a\nb", status: .completed))
            default: .turnSummary(TurnSummary(durationMs: i, isError: false))
            }
            return TranscriptItem(id: "\(prefix)-\(i)", timestamp: base.addingTimeInterval(Double(i)), kind: kind)
        }
    }

    @Test
    func importThenReplayInOrder() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let path = try server.makeGitRepo()
        var add = Proto_AddRepository()
        add.path = path.path
        let repo = try await c.addRepository(add)

        let sessionID = UUID().protoID
        let items = Self.sampleItems(40)
        let req = Self.importRequest(repoID: repo.id, path: path.path, sessionID: sessionID, items: items)
        let ws = try await c.importWorkspace(req)
        #expect(ws.id == req.workspace.id)
        // Idempotent.
        let again = try await c.importWorkspace(req)
        #expect(again.id == ws.id)

        let sub = try await c.subscribeSession(sessionID)
        let events = EventReader(sub)
        var got: [TranscriptItem] = []
        var seqs: [UInt64] = []
        var maxSeq: UInt64 = 0
        while let ev = try await events.next() {
            maxSeq = max(maxSeq, ev.seq)
            if ev.isReplayDone { break }
            if let item = ev.item, let t = TranscriptItem(proto: item) {
                got.append(t)
                seqs.append(ev.seq)
            }
        }
        #expect(seqs == seqs.sorted())
        #expect(got == items)
        #expect(sub.lastSeq == maxSeq)
        #expect(sub.lastSeq > 0)

        // Resuming from the cursor replays nothing.
        let resumed = try await c.subscribeSession(sessionID, fromSeq: sub.lastSeq)
        #expect(try await EventReader(resumed).next()?.isReplayDone == true)

        // Resuming from the middle replays exactly the rest, in order.
        let mid = seqs[24]
        let partial = try await c.subscribeSession(sessionID, fromSeq: mid)
        let pe = EventReader(partial)
        var rest: [String] = []
        while let ev = try await pe.next(), !ev.isReplayDone { if let i = ev.item { rest.append(i.id) } }
        #expect(rest == items[25...].map(\.id))

        // The pull API agrees.
        let page = try await c.transcript(sessionID: sessionID)
        #expect(page.entries.compactMap { TranscriptItem(proto: $0.item) }.map(\.id).sorted() == items.map(\.id).sorted())
        #expect(page.entries.sorted { $0.position < $1.position }.map(\.item.id) == items.map(\.id))
        await c.close()
    }

    // MARK: Reconnect

    @Test func reconnectResubscribesAfterServerRestart() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let path = try server.makeGitRepo()
        var add = Proto_AddRepository()
        add.path = path.path
        let repo = try await c.addRepository(add)
        var create = Proto_CreateWorkspace()
        create.repositoryID = repo.id
        let ws = try await c.createWorkspace(create)
        var open = Proto_OpenSession()
        open.workspaceID = ws.id
        let session = try await c.openSession(open)

        let serverSub = try await c.subscribeServer()
        let serverEvents = EventReader(serverSub)
        #expect(try await serverEvents.next()?.snapshot != nil)
        let sessionSub = try await c.subscribeSession(session.id)
        let sessionEvents = EventReader(sessionSub)
        #expect(try await sessionEvents.next()?.isReplayDone == true)

        #expect(try await waitForState(c) { if case .connected = $0 { true } else { false } } != nil)

        server.kill()
        #expect(try await waitForState(c) { if case .disconnected = $0 { true } else { false } } != nil)
        // Requests while down fail (bounded wait) rather than hang.
        let down = await #expect(throws: ServerError.self) { try await c.serverInfo() }
        #expect(down?.code == .unavailable && down?.isLocal == true)
        try await server.start()

        // Reconnects on its own.
        let welcome = try await waitForState(c, timeout: .seconds(20)) { if case .connected = $0 { true } else { false } }
        #expect(welcome != nil)

        // Server subscription: a fresh snapshot that still has our state.
        let snapEvent = try await serverEvents.first { $0.snapshot != nil }
        #expect(snapEvent.snapshot?.sessions.map(\.id) == [session.id])
        #expect(snapEvent.snapshot?.workspaces.map(\.id) == [ws.id])
        // Session subscription: resumed (replay from lastSeq, then ReplayDone again).
        #expect(try await sessionEvents.next()?.isReplayDone == true)

        // And the subscriptions are live on the new connection.
        var update = Proto_UpdateSession()
        update.sessionID = session.id
        update.title = "After restart"
        _ = try await c.updateSession(update)
        let up = try await serverEvents.first { if case .sessionUpserted(let r) = $0.payload { r.title == "After restart" } else { false } }
        #expect(up.seq > 0)
        await c.close()
    }

    @Test
    func reconnectResumesSessionWithoutDuplicates() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let path = try server.makeGitRepo()
        var add = Proto_AddRepository()
        add.path = path.path
        let repo = try await c.addRepository(add)
        let sessionID = UUID().protoID
        let items = Self.sampleItems(10)
        _ = try await c.importWorkspace(Self.importRequest(repoID: repo.id, path: path.path, sessionID: sessionID, items: items))

        let sub = try await c.subscribeSession(sessionID)
        let events = EventReader(sub)
        var got: [String] = []
        while let ev = try await events.next(), !ev.isReplayDone { if let i = ev.item { got.append(i.id) } }
        #expect(got == items.map(\.id))
        let seqBefore = sub.lastSeq

        server.kill()
        try await server.start()
        // After the restart nothing new was written: the resumed replay is empty.
        let next = try #require(try await events.next(timeout: .seconds(20)))
        #expect(next.isReplayDone)
        #expect(sub.lastSeq == seqBefore)
        await c.close()
    }

    // MARK: Close

    @Test func closeEndsSubscriptionsAndRequests() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let sub = try await c.subscribeServer()
        let events = EventReader(sub)
        #expect(try await events.next()?.snapshot != nil)
        var states = c.states.makeAsyncIterator()
        _ = await states.next()

        await c.close()
        #expect(try await events.next(timeout: .seconds(5)) == nil)
        let e = await #expect(throws: ServerError.self) { try await c.serverInfo() }
        #expect(e?.code == .unavailable)
        await #expect(throws: ServerError.self) { try await c.subscribeServer() }
        await #expect(throws: ServerError.self) { try await c.connect() }
        // The states stream ends after reporting the close.
        var last: ServerConnectionState?
        while let s = await states.next() { last = s }
        #expect(last == .disconnected("Closed"))
    }

    @Test func cancelEndsOneSubscription() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let a = try await c.subscribeServer()
        let b = try await c.subscribeServer()
        let ea = EventReader(a), eb = EventReader(b)
        _ = try await ea.next()
        _ = try await eb.next()
        a.cancel()
        #expect(try await ea.next(timeout: .seconds(5)) == nil)
        // b keeps working.
        var add = Proto_AddRepository()
        add.path = try server.makeGitRepo().path
        let repo = try await c.addRepository(add)
        let ev = try await eb.first { if case .repositoryUpserted(let r) = $0.payload { r.id == repo.id } else { false } }
        #expect(ev.seq > 0)
        await c.close()
    }

    /// The server pings every 15 s (and drops us after a 30 s ping timeout); we ping every 15 s too. An idle
    /// minute must not disconnect, over the Unix socket (framer stack) and TCP. Slow: RRK_SLOW=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RRK_SLOW"] != nil, "slow; set RRK_SLOW=1"), .timeLimit(.minutes(3)))
    func idleConnectionsStayUp() async throws {
        defer { server.cleanup() }
        let token = try server.createToken()
        let clients = [client(), client(server.tcp, token: token)]
        for c in clients { try await c.connect() }
        let dropped = try await withThrowingTaskGroup(of: ServerConnectionState?.self) { group in
            for c in clients {
                group.addTask { try await waitForState(c, timeout: .seconds(65)) { if case .disconnected = $0 { true } else { false } } }
            }
            var out: [ServerConnectionState] = []
            for try await s in group { if let s { out.append(s) } }
            return out
        }
        #expect(dropped.isEmpty, "a connection dropped while idle: \(dropped)")
        for c in clients {
            _ = try await c.serverInfo()
            await c.close()
        }
    }

    /// A server that stops answering (SIGSTOP: the socket stays open, nothing arrives) is declared dead after
    /// 45 s of silence; the client reconnects when it comes back. Slow: RRK_SLOW=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RRK_SLOW"] != nil, "slow; set RRK_SLOW=1"))
    func silentServerIsDetected() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let sub = try await c.subscribeServer()
        let events = EventReader(sub)
        #expect(try await events.next()?.snapshot != nil)
        let pid = try #require(server.pid)
        kill(pid, SIGSTOP)
        let start = ContinuousClock.now
        let down = try await waitForState(c, timeout: .seconds(70)) { if case .disconnected = $0 { true } else { false } }
        let took = ContinuousClock.now - start
        kill(pid, SIGCONT)
        #expect(down != nil)
        #expect(took >= .seconds(29) && took <= .seconds(62), "detected after \(took)")
        #expect(try await waitForState(c, timeout: .seconds(30)) { if case .connected = $0 { true } else { false } } != nil)
        #expect(try await events.first(timeout: .seconds(20)) { $0.snapshot != nil }.snapshot != nil)
        await c.close()
    }

    @Test func concurrentRequests() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<50 { group.addTask { try await c.serverInfo().serverID } }
            var out: [String] = []
            for try await id in group { out.append(id) }
            return out
        }
        #expect(ids.count == 50 && Set(ids).count == 1)
        await c.close()
    }

    @Test func largeFrames() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let path = try server.makeGitRepo()
        var add = Proto_AddRepository()
        add.path = path.path
        let repo = try await c.addRepository(add)
        var create = Proto_CreateWorkspace()
        create.repositoryID = repo.id
        create.name = "big"
        let sub = try await c.subscribeServer()
        let events = EventReader(sub)
        let ws = try await c.createWorkspace(create)
        _ = try await events.first { $0.workspace?.id == ws.id && $0.workspace?.state == .ready }

        // A ~2 MB response (ReadFile's server-side cap is 2 MB).
        let big = String(repeating: "0123456789abcdef", count: (2 << 20) / 16 - 1)
        try big.write(to: URL(fileURLWithPath: ws.path).appending(path: "big.txt"), atomically: true, encoding: .utf8)
        var read = Proto_ReadFile()
        read.workspaceID = ws.id
        read.path = "big.txt"
        let r = try await c.send(.readFile(read))
        guard case .file(let f) = r.result else { Issue.record("expected file"); return }
        #expect(f.data == Data(big.utf8))

        // A 32 MB request; the server reads it and answers (NOT_FOUND), so it isn't a transport failure.
        let e = await #expect(throws: ServerError.self) {
            try await c.sendMessage(sessionID: UUID().protoID, text: String(repeating: "y", count: 32 << 20))
        }
        #expect(e?.code == .notFound)

        // A response bigger than one TCP window: the error echoes this 4 MB path twice (~8 MB frame).
        var huge = Proto_AddRepository()
        huge.path = "/nonexistent/" + String(repeating: "x", count: 4 << 20)
        let e2 = await #expect(throws: ServerError.self) { try await c.addRepository(huge) }
        #expect(e2?.isLocal == false)
        #expect((e2?.message.utf8.count ?? 0) > 8 << 20)
        // Still connected afterwards.
        _ = try await c.serverInfo()
        sub.cancel()
        await c.close()
    }
}

/// Waits for a connection state matching `match` (the stream starts with the current state).
func waitForState(
    _ c: ServerClient, timeout: Duration = .seconds(10), _ match: @escaping @Sendable (ServerConnectionState) -> Bool
) async throws -> ServerConnectionState? {
    let states = c.states
    return try await withThrowingTaskGroup(of: ServerConnectionState?.self) { group in
        group.addTask {
            for await s in states where match(s) { return s }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

// MARK: - LocalServer

@Suite(.enabled(if: ServerBuild.goAvailable, "go is not installed"))
struct LocalServerTests {
    @Test func homeFromBeforeTheRenameKeepsItsFileNames() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(LocalServer.dataFile("sock", in: home).lastPathComponent == "server.sock")
        try Data().write(to: home.appending(path: "teamcar.sqlite"))
        #expect(LocalServer.dataFile("sock", in: home).lastPathComponent == "teamcar.sock")
    }

    @Test func homeAndSocketFromEnvironment() {
        #expect(LocalServer.home(in: ["DOMESTIQUE_SERVER_HOME": "/tmp/rrk-home-test"]).path == "/tmp/rrk-home-test")
        #expect(LocalServer.socketPath(in: ["DOMESTIQUE_SERVER_HOME": "/tmp/rrk-home-test"]) == "/tmp/rrk-home-test/server.sock")
        let defaultHome = LocalServer.home(in: [:]).path
        #expect(defaultHome.hasSuffix("/Domestique/server") || defaultHome.hasSuffix("/Domestique/teamcar"))
        if ProcessInfo.processInfo.environment["DOMESTIQUE_SERVER_HOME"] == nil {
            #expect(LocalServer.socketPath == LocalServer.dataFile("sock", in: LocalServer.home(in: [:])).path)
        }
    }

    @Test func binaryLookup() throws {
        let bin = try ServerBuild.binary.get()
        #expect(LocalServer.binary(in: ["DOMESTIQUE_SERVER_BIN": bin.path])?.path == bin.path)
        // Falls back to the checkout's server/domestique, or PATH.
        let checkout = ServerBuild.repoRoot.appending(components: "server", "domestique")
        if FileManager.default.isExecutableFile(atPath: checkout.path) {
            #expect(LocalServer.binary(in: [:])?.path == checkout.path)
        }
        #expect(LocalServer.binary(in: ["DOMESTIQUE_SERVER_BIN": "/nonexistent", "PATH": bin.deletingLastPathComponent().path]) != nil)
    }

    @Test func ensureRunningStartsAndReusesServer() async throws {
        let bin = try ServerBuild.binary.get()
        let root = try ServerBuild.makeTempDir("rrk-l")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "h")
        var env = ProcessInfo.processInfo.environment
        env["DOMESTIQUE_SERVER_HOME"] = home.path
        env["DOMESTIQUE_SERVER_BIN"] = bin.path
        env["DOMESTIQUE_SERVER_WORKSPACES_ROOT"] = root.appending(path: "ws").path
        env["DOMESTIQUE_SERVER_REPOS_ROOT"] = root.appending(path: "repos").path

        let (endpoint, child) = try await LocalServer.launch(timeout: .seconds(10), environment: env)
        let started = try #require(child)
        defer { kill(started.pid, SIGKILL) }  // reaped by Child's background thread
        #expect(endpoint == .unix(path: home.appending(path: "server.sock").path))
        // Its own session and process group.
        #expect(getsid(started.pid) == started.pid)
        #expect(getpgid(started.pid) == started.pid)

        let c = ServerClient(endpoint: endpoint, clientName: "t", clientID: "t")
        let w = try await c.connect()
        #expect(w.scope == .admin)
        await c.close()

        // Already running: reused, nothing new started.
        let (again, second) = try await LocalServer.launch(timeout: .seconds(5), environment: env)
        #expect(again == endpoint)
        #expect(second == nil)
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "server.log").path))
    }

    @Test func simultaneousLaunchesShareOneServer() async throws {
        let bin = try ServerBuild.binary.get()
        let root = try ServerBuild.makeTempDir("rrk-r")
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment
        env["DOMESTIQUE_SERVER_HOME"] = root.appending(path: "h").path
        env["DOMESTIQUE_SERVER_BIN"] = bin.path
        env["DOMESTIQUE_SERVER_WORKSPACES_ROOT"] = root.appending(path: "ws").path
        env["DOMESTIQUE_SERVER_REPOS_ROOT"] = root.appending(path: "repos").path

        let environment = env
        let launches = try await withThrowingTaskGroup(of: (ServerEndpoint, LocalServer.Child?).self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let launch = try await LocalServer.launch(timeout: .seconds(10), environment: environment)
                    return (launch.endpoint, launch.started)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let children = launches.compactMap(\.1)
        defer { for child in children where child.exitStatus == nil { kill(child.pid, SIGKILL) } }

        // Losers exit by themselves, possibly just after their launch saw the winner's socket.
        var alive = children.filter { $0.exitStatus == nil }
        for _ in 0..<50 where alive.count > 1 {
            try await Task.sleep(for: .milliseconds(100))
            alive = children.filter { $0.exitStatus == nil }
        }
        #expect(alive.count == 1)
        for child in children where child.exitStatus != nil {
            #expect(child.exitStatus == LocalServer.alreadyRunningExitCode << 8)
        }

        let c = ServerClient(endpoint: launches[0].0, clientName: "t", clientID: "t")
        _ = try await c.connect()
        await c.close()
    }

    @Test func ensureRunningRejectsLongSocketPaths() async throws {
        let long = "/tmp/" + String(repeating: "x", count: 120)
        let e = await #expect(throws: LocalServer.LaunchError.self) {
            try await LocalServer.launch(timeout: .seconds(1), environment: ["DOMESTIQUE_SERVER_HOME": long])
        }
        #expect(e?.message.contains("103") == true)
    }

    @Test func ensureRunningReportsLogTailWhenItCantStart() async throws {
        let root = try ServerBuild.makeTempDir("rrk-f")
        defer { try? FileManager.default.removeItem(at: root) }
        // A "domestique" that complains and exits.
        let fake = root.appending(path: "domestique")
        try "#!/bin/sh\necho 'fake domestique: cannot serve' >&2\nexit 3\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let env = ["DOMESTIQUE_SERVER_HOME": root.appending(path: "h").path, "DOMESTIQUE_SERVER_BIN": fake.path]
        let e = await #expect(throws: LocalServer.LaunchError.self) {
            try await LocalServer.launch(timeout: .seconds(5), environment: env)
        }
        #expect(e?.message.contains("fake domestique: cannot serve") == true)
        #expect(e?.message.contains("exit code 3") == true)
    }
}
