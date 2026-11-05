import Foundation
import Testing

@testable import DQCore

/// Store reads its location from DOMESTIQUE_HOME at init, so each test gets its own folder.
@Suite(.serialized) struct StoreTests {
    private func freshHome() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dq-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("DOMESTIQUE_HOME", dir.path, 1)
        return dir
    }

    private func repo(_ name: String) -> Repository {
        Repository(name: name, path: "/tmp/\(name)", remoteURL: nil, defaultBranch: "main")
    }

    @Test func roundTripsState() async {
        _ = freshHome()
        let store = Store()
        var state = AppState()
        let r = repo("alpha")
        state.repositories = [r]
        state.workspaces = [Workspace(repoID: r.id, name: "ventoux", branch: "a/ventoux", path: "/tmp/w", baseBranch: "main", portBase: 41000, state: .ready)]
        state.settings.branchPrefix = "zz"
        await store.save(state)

        let loaded = Store().loadStateSync()
        #expect(loaded.repositories.map(\.name) == ["alpha"])
        #expect(loaded.workspaces.first?.name == "ventoux")
        #expect(loaded.settings.branchPrefix == "zz")
    }

    @Test func twoInstancesDontClobberEachOther() async {
        _ = freshHome()
        let a = Store()
        let b = Store()
        // Instance A adds a repo.
        var stateA = AppState()
        stateA.repositories = [repo("from-a")]
        await a.markLoaded(AppState())
        await a.save(stateA)
        // Instance B, which loaded before A saved, adds its own repo.
        var stateB = AppState()
        await b.markLoaded(stateB)
        stateB.repositories = [repo("from-b")]
        await b.save(stateB)
        // B must not have deleted A's repo (it never knew about it).
        let names = Set(Store().loadStateSync().repositories.map(\.name))
        #expect(names == ["from-a", "from-b"])
    }

    @Test func dataVersionSeesOtherConnections() async {
        _ = freshHome()
        let a = Store()
        let b = Store()
        let before = b.dataVersion()
        var s = AppState()
        s.repositories = [repo("x")]
        await a.save(s)
        #expect(b.dataVersion() != before)
    }

    @Test func transcriptsKeepOrderAndUpsert() async {
        _ = freshHome()
        let store = Store()
        let tab = UUID()
        await store.append(
            [TranscriptItem(id: "1", kind: .user(text: "hi")), TranscriptItem(id: "2", kind: .assistant(text: "par"))],
            tabID: tab)
        await store.append([TranscriptItem(id: "2", kind: .assistant(text: "partial done"))], tabID: tab)
        await store.append([TranscriptItem(id: "3", kind: .notice(text: "n"))], tabID: tab)
        let (items, maxRow) = await store.transcriptItems(tabID: tab, afterRowID: 0)
        #expect(items.map(\.id) == ["1", "2", "3"])
        if case .assistant(let text) = items[1].kind { #expect(text == "partial done") }
        let (newer, _) = await store.transcriptItems(tabID: tab, afterRowID: maxRow)
        #expect(newer.isEmpty)
    }
}
