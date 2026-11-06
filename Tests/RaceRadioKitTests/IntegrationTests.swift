import DQCore
import Foundation
import Testing
@testable import RaceRadioKit

/// End-to-end against a real `teamcar serve` (built from teamcar/). No agents run: everything here works
/// without claude/codex.
@Suite(.enabled(if: TeamCarBuild.goAvailable, "go is not installed; skipping Team Car integration tests"), .timeLimit(.minutes(2)))
struct IntegrationTests {
    let server: TeamCarServer

    init() async throws {
        server = try TeamCarServer()
        try await server.start()
    }

    func client(_ endpoint: TeamCarEndpoint? = nil, token: String? = nil) -> TeamCarClient {
        TeamCarClient(endpoint: endpoint ?? server.unix, token: token, clientName: "RaceRadioKit tests", clientID: "rrk-\(UUID().radioID)")
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

    @Test func handshakeOverTCPWithToken() async throws {
        defer { server.cleanup() }
        let token = try server.createToken(scope: "admin")
        #expect(token.hasPrefix("tc_"))
        let c = client(server.tcp, token: token)
        let w = try await c.connect()
        #expect(w.scope == .admin)
        _ = try await c.serverInfo()
        await c.close()

        // An explicit path works too.
        let c2 = client(.url(URL(string: "ws://127.0.0.1:\(server.port)/radio/v1")!), token: token)
        _ = try await c2.connect()
        await c2.close()
    }

    @Test func badTokenIsUnauthenticated() async throws {
        defer { server.cleanup() }
        let bad = client(server.tcp, token: "tc_nope")
        let e1 = await #expect(throws: TeamCarError.self) { try await bad.connect() }
        #expect(e1?.code == .unauthenticated)
        #expect(e1?.isLocal == false)

        let none = client(server.tcp)
        let e2 = await #expect(throws: TeamCarError.self) { try await none.connect() }
        #expect(e2?.code == .unauthenticated)

        // A failed first connect reports the state and leaves the client usable for another attempt.
        var states = bad.states.makeAsyncIterator()
        guard case .disconnected = await states.next() else { Issue.record("expected disconnected"); return }
    }

    @Test func unreachableServerFailsFast() async throws {
        defer { server.cleanup() }
        let c = client(.unix(path: server.root.appending(path: "nothing.sock").path))
        let e = await #expect(throws: TeamCarError.self) { try await c.connect() }
        #expect(e?.code == .unavailable)
        // Requests before a connection fail rather than hang.
        await #expect(throws: TeamCarError.self) { try await c.serverInfo() }
    }

    @Test func errorResponsesThrow() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let e = await #expect(throws: TeamCarError.self) { try await c.closeRider(id: UUID().radioID) }
        #expect(e?.code == .notFound)
        #expect(e?.isLocal == false)
        // Subscribing to a rider that doesn't exist fails too.
        await #expect(throws: TeamCarError.self) { try await c.subscribeRider(UUID().radioID) }
        await c.close()
    }

    // MARK: Repositories, workspaces, riders

    @Test func repositoryWorkspaceAndRiderFlow() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let path = try server.makeGitRepo()

        var add = Radio_AddRepository()
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

        var create = Radio_CreateWorkspace()
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

        var open = Radio_OpenRider()
        open.workspaceID = ws.id
        open.provider = .codex
        open.permissionMode = .ask
        open.title = "Rider one"
        let rider = try await c.openRider(open)
        #expect(rider.workspaceID == ws.id && rider.provider == .codex && rider.permissionMode == .ask && rider.title == "Rider one")
        let upserted = try await events.first { if case .riderUpserted(let r) = $0.payload { r.id == rider.id } else { false } }
        #expect(upserted.seq > first.seq)

        // A fresh server subscription's snapshot has everything.
        let sub2 = try await c.subscribeServer()
        let snap2 = try #require(try await EventReader(sub2).next()?.snapshot)
        #expect(snap2.repositories.map(\.id) == [repo.id])
        #expect(snap2.workspaces.map(\.id) == [ws.id])
        #expect(snap2.workspaces.first?.state == .ready)
        #expect(snap2.riders.map(\.id) == [rider.id])
        sub2.cancel()

        // A rider with no transcript replays nothing, then ReplayDone.
        let riderSub = try await c.subscribeRider(rider.id)
        let replay = try #require(try await EventReader(riderSub).next())
        #expect(replay.isReplayDone)

        var update = Radio_UpdateRider()
        update.riderID = rider.id
        update.title = "Renamed"
        let updated = try await c.updateRider(update)
        #expect(updated.title == "Renamed")

        try await c.closeRider(id: rider.id)
        _ = try await events.first { if case .riderRemoved(let id) = $0.payload { id == rider.id } else { false } }

        var archive = Radio_ArchiveWorkspace()
        archive.workspaceID = ws.id
        let archived = try await c.archiveWorkspace(archive)
        #expect(archived.state == .archived)
        var delete = Radio_DeleteWorkspace()
        delete.workspaceID = ws.id
        try await c.deleteWorkspace(delete)
        _ = try await events.first { if case .workspaceRemoved(let id) = $0.payload { id == ws.id } else { false } }

        try await c.removeRepository(id: repo.id)
        _ = try await events.first { if case .repositoryRemoved(let id) = $0.payload { id == repo.id } else { false } }
        sub.cancel()
        riderSub.cancel()
        await c.close()
    }

    @Test
    func clientChosenIDs() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        var add = Radio_AddRepository()
        add.path = try server.makeGitRepo().path
        let repoID = UUID().radioID
        add.id = repoID
        let repo = try await c.addRepository(add)
        #expect(repo.id == repoID)

        var create = Radio_CreateWorkspace()
        create.repositoryID = repo.id
        let wsID = UUID().radioID
        create.id = wsID
        let ws = try await c.createWorkspace(create)
        #expect(ws.id == wsID)

        var open = Radio_OpenRider()
        open.workspaceID = ws.id
        let riderID = UUID().radioID
        open.id = riderID
        let rider = try await c.openRider(open)
        #expect(rider.id == riderID)
        await c.close()
    }

    // MARK: Import and replay

    static func importRequest(repoID: String, path: String, riderID: String, items: [TranscriptItem]) -> Radio_ImportWorkspace {
        var ws = Radio_Workspace()
        ws.id = UUID().radioID
        ws.repositoryID = repoID
        ws.name = "imported"
        ws.branch = "main"
        ws.path = path
        ws.baseBranch = "main"
        ws.portBase = 41000
        ws.state = .ready
        ws.createdAtMs = Date.now.radioMs
        var rider = Radio_Rider()
        rider.id = riderID
        rider.workspaceID = ws.id
        rider.title = "Imported chat"
        rider.provider = .claude
        rider.permissionMode = .bypass
        rider.createdAtMs = Date.now.radioMs
        var ir = Radio_ImportRider()
        ir.rider = rider
        ir.items = items.map(\.radio)
        var req = Radio_ImportWorkspace()
        req.workspace = ws
        req.riders = [ir]
        return req
    }

    static func sampleItems(_ n: Int, prefix: String = "item") -> [TranscriptItem] {
        let base = Date(radioMs: 1_762_000_000_000)
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
        var add = Radio_AddRepository()
        add.path = path.path
        let repo = try await c.addRepository(add)

        let riderID = UUID().radioID
        let items = Self.sampleItems(40)
        let req = Self.importRequest(repoID: repo.id, path: path.path, riderID: riderID, items: items)
        let ws = try await c.importWorkspace(req)
        #expect(ws.id == req.workspace.id)
        // Idempotent.
        let again = try await c.importWorkspace(req)
        #expect(again.id == ws.id)

        let sub = try await c.subscribeRider(riderID)
        let events = EventReader(sub)
        var got: [TranscriptItem] = []
        var seqs: [UInt64] = []
        var maxSeq: UInt64 = 0
        while let ev = try await events.next() {
            maxSeq = max(maxSeq, ev.seq)
            if ev.isReplayDone { break }
            if let item = ev.item, let t = TranscriptItem(radio: item) {
                got.append(t)
                seqs.append(ev.seq)
            }
        }
        #expect(seqs == seqs.sorted())
        #expect(got == items)
        #expect(sub.lastSeq == maxSeq)
        #expect(sub.lastSeq > 0)

        // Resuming from the cursor replays nothing.
        let resumed = try await c.subscribeRider(riderID, fromSeq: sub.lastSeq)
        #expect(try await EventReader(resumed).next()?.isReplayDone == true)

        // Resuming from the middle replays exactly the rest, in order.
        let mid = seqs[24]
        let partial = try await c.subscribeRider(riderID, fromSeq: mid)
        let pe = EventReader(partial)
        var rest: [String] = []
        while let ev = try await pe.next(), !ev.isReplayDone { if let i = ev.item { rest.append(i.id) } }
        #expect(rest == items[25...].map(\.id))

        // The pull API agrees.
        let page = try await c.transcript(riderID: riderID)
        #expect(page.entries.compactMap { TranscriptItem(radio: $0.item) }.map(\.id).sorted() == items.map(\.id).sorted())
        #expect(page.entries.sorted { $0.position < $1.position }.map(\.item.id) == items.map(\.id))
        await c.close()
    }

    // MARK: Reconnect

    @Test func reconnectResubscribesAfterServerRestart() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let path = try server.makeGitRepo()
        var add = Radio_AddRepository()
        add.path = path.path
        let repo = try await c.addRepository(add)
        var create = Radio_CreateWorkspace()
        create.repositoryID = repo.id
        let ws = try await c.createWorkspace(create)
        var open = Radio_OpenRider()
        open.workspaceID = ws.id
        let rider = try await c.openRider(open)

        let serverSub = try await c.subscribeServer()
        let serverEvents = EventReader(serverSub)
        #expect(try await serverEvents.next()?.snapshot != nil)
        let riderSub = try await c.subscribeRider(rider.id)
        let riderEvents = EventReader(riderSub)
        #expect(try await riderEvents.next()?.isReplayDone == true)

        #expect(try await waitForState(c) { if case .connected = $0 { true } else { false } } != nil)

        server.kill()
        #expect(try await waitForState(c) { if case .disconnected = $0 { true } else { false } } != nil)
        // Requests while down fail (bounded wait) rather than hang.
        let down = await #expect(throws: TeamCarError.self) { try await c.serverInfo() }
        #expect(down?.code == .unavailable && down?.isLocal == true)
        try await server.start()

        // Reconnects on its own.
        let welcome = try await waitForState(c, timeout: .seconds(20)) { if case .connected = $0 { true } else { false } }
        #expect(welcome != nil)

        // Server subscription: a fresh snapshot that still has our state.
        let snapEvent = try await serverEvents.first { $0.snapshot != nil }
        #expect(snapEvent.snapshot?.riders.map(\.id) == [rider.id])
        #expect(snapEvent.snapshot?.workspaces.map(\.id) == [ws.id])
        // Rider subscription: resumed (replay from lastSeq, then ReplayDone again).
        #expect(try await riderEvents.next()?.isReplayDone == true)

        // And the subscriptions are live on the new connection.
        var update = Radio_UpdateRider()
        update.riderID = rider.id
        update.title = "After restart"
        _ = try await c.updateRider(update)
        let up = try await serverEvents.first { if case .riderUpserted(let r) = $0.payload { r.title == "After restart" } else { false } }
        #expect(up.seq > 0)
        await c.close()
    }

    @Test
    func reconnectResumesRiderWithoutDuplicates() async throws {
        defer { server.cleanup() }
        let c = client()
        try await c.connect()
        let path = try server.makeGitRepo()
        var add = Radio_AddRepository()
        add.path = path.path
        let repo = try await c.addRepository(add)
        let riderID = UUID().radioID
        let items = Self.sampleItems(10)
        _ = try await c.importWorkspace(Self.importRequest(repoID: repo.id, path: path.path, riderID: riderID, items: items))

        let sub = try await c.subscribeRider(riderID)
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
        let e = await #expect(throws: TeamCarError.self) { try await c.serverInfo() }
        #expect(e?.code == .unavailable)
        await #expect(throws: TeamCarError.self) { try await c.subscribeServer() }
        await #expect(throws: TeamCarError.self) { try await c.connect() }
        // The states stream ends after reporting the close.
        var last: TeamCarConnectionState?
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
        var add = Radio_AddRepository()
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
        let dropped = try await withThrowingTaskGroup(of: TeamCarConnectionState?.self) { group in
            for c in clients {
                group.addTask { try await waitForState(c, timeout: .seconds(65)) { if case .disconnected = $0 { true } else { false } } }
            }
            var out: [TeamCarConnectionState] = []
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
        var add = Radio_AddRepository()
        add.path = path.path
        let repo = try await c.addRepository(add)
        var create = Radio_CreateWorkspace()
        create.repositoryID = repo.id
        create.name = "big"
        let sub = try await c.subscribeServer()
        let events = EventReader(sub)
        let ws = try await c.createWorkspace(create)
        _ = try await events.first { $0.workspace?.id == ws.id && $0.workspace?.state == .ready }

        // A ~2 MB response (ReadFile's server-side cap is 2 MB).
        let big = String(repeating: "0123456789abcdef", count: (2 << 20) / 16 - 1)
        try big.write(to: URL(fileURLWithPath: ws.path).appending(path: "big.txt"), atomically: true, encoding: .utf8)
        var read = Radio_ReadFile()
        read.workspaceID = ws.id
        read.path = "big.txt"
        let r = try await c.send(.readFile(read))
        guard case .file(let f) = r.result else { Issue.record("expected file"); return }
        #expect(f.data == Data(big.utf8))

        // A 32 MB request; the server reads it and answers (NOT_FOUND), so it isn't a transport failure.
        let e = await #expect(throws: TeamCarError.self) {
            try await c.sendMessage(riderID: UUID().radioID, text: String(repeating: "y", count: 32 << 20))
        }
        #expect(e?.code == .notFound)

        // A response bigger than one TCP window: the error echoes this 4 MB path twice (~8 MB frame).
        var huge = Radio_AddRepository()
        huge.path = "/nonexistent/" + String(repeating: "x", count: 4 << 20)
        let e2 = await #expect(throws: TeamCarError.self) { try await c.addRepository(huge) }
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
    _ c: TeamCarClient, timeout: Duration = .seconds(10), _ match: @escaping @Sendable (TeamCarConnectionState) -> Bool
) async throws -> TeamCarConnectionState? {
    let states = c.states
    return try await withThrowingTaskGroup(of: TeamCarConnectionState?.self) { group in
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

// MARK: - LocalTeamCar

@Suite(.enabled(if: TeamCarBuild.goAvailable, "go is not installed"))
struct LocalTeamCarTests {
    @Test func homeAndSocketFromEnvironment() {
        #expect(LocalTeamCar.home(in: ["TEAMCAR_HOME": "/tmp/rrk-home-test"]).path == "/tmp/rrk-home-test")
        #expect(LocalTeamCar.socketPath(in: ["TEAMCAR_HOME": "/tmp/rrk-home-test"]) == "/tmp/rrk-home-test/teamcar.sock")
        #expect(LocalTeamCar.home(in: [:]).path.hasSuffix("/Library/Application Support/Domestique/teamcar"))
        if ProcessInfo.processInfo.environment["TEAMCAR_HOME"] == nil {
            #expect(LocalTeamCar.socketPath == LocalTeamCar.home(in: [:]).appending(path: "teamcar.sock").path)
        }
    }

    @Test func binaryLookup() throws {
        let bin = try TeamCarBuild.binary.get()
        #expect(LocalTeamCar.binary(in: ["DOMESTIQUE_TEAMCAR": bin.path])?.path == bin.path)
        // Falls back to the checkout's teamcar/teamcar, or PATH.
        let checkout = TeamCarBuild.repoRoot.appending(components: "teamcar", "teamcar")
        if FileManager.default.isExecutableFile(atPath: checkout.path) {
            #expect(LocalTeamCar.binary(in: [:])?.path == checkout.path)
        }
        #expect(LocalTeamCar.binary(in: ["DOMESTIQUE_TEAMCAR": "/nonexistent", "PATH": bin.deletingLastPathComponent().path]) != nil)
    }

    @Test func ensureRunningStartsAndReusesTeamCar() async throws {
        let bin = try TeamCarBuild.binary.get()
        let root = try TeamCarBuild.makeTempDir("rrk-l")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "h")
        var env = ProcessInfo.processInfo.environment
        env["TEAMCAR_HOME"] = home.path
        env["DOMESTIQUE_TEAMCAR"] = bin.path
        env["TEAMCAR_WORKSPACES_ROOT"] = root.appending(path: "ws").path
        env["TEAMCAR_REPOS_ROOT"] = root.appending(path: "repos").path

        let (endpoint, child) = try await LocalTeamCar.launch(timeout: .seconds(10), environment: env)
        let started = try #require(child)
        defer { kill(started.pid, SIGKILL) }  // reaped by Child's background thread
        #expect(endpoint == .unix(path: home.appending(path: "teamcar.sock").path))
        // Its own session and process group.
        #expect(getsid(started.pid) == started.pid)
        #expect(getpgid(started.pid) == started.pid)

        let c = TeamCarClient(endpoint: endpoint, clientName: "t", clientID: "t")
        let w = try await c.connect()
        #expect(w.scope == .admin)
        await c.close()

        // Already running: reused, nothing new started.
        let (again, second) = try await LocalTeamCar.launch(timeout: .seconds(5), environment: env)
        #expect(again == endpoint)
        #expect(second == nil)
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "teamcar.log").path))
    }

    @Test func ensureRunningRejectsLongSocketPaths() async throws {
        let long = "/tmp/" + String(repeating: "x", count: 120)
        let e = await #expect(throws: LocalTeamCar.LaunchError.self) {
            try await LocalTeamCar.launch(timeout: .seconds(1), environment: ["TEAMCAR_HOME": long])
        }
        #expect(e?.message.contains("103") == true)
    }

    @Test func ensureRunningReportsLogTailWhenItCantStart() async throws {
        let root = try TeamCarBuild.makeTempDir("rrk-f")
        defer { try? FileManager.default.removeItem(at: root) }
        // A "teamcar" that complains and exits.
        let fake = root.appending(path: "teamcar")
        try "#!/bin/sh\necho 'fake teamcar: cannot serve' >&2\nexit 3\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let env = ["TEAMCAR_HOME": root.appending(path: "h").path, "DOMESTIQUE_TEAMCAR": fake.path]
        let e = await #expect(throws: LocalTeamCar.LaunchError.self) {
            try await LocalTeamCar.launch(timeout: .seconds(5), environment: env)
        }
        #expect(e?.message.contains("fake teamcar: cannot serve") == true)
        #expect(e?.message.contains("exit code 3") == true)
    }
}
