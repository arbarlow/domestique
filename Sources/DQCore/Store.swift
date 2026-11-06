import Foundation

public enum Paths {
    /// ~/Library/Application Support/Domestique (override with DOMESTIQUE_HOME for tests/dev).
    public static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["DOMESTIQUE_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Domestique", isDirectory: true)
    }

    /// The shared database every app instance uses.
    public static var database: URL { appSupport.appendingPathComponent("domestique.sqlite") }
    public static var logs: URL { appSupport.appendingPathComponent("logs", isDirectory: true) }
    public static var icons: URL { appSupport.appendingPathComponent("icons", isDirectory: true) }

    /// Where worktrees live: ~/Domestique/workspaces/<repo>/<name>.
    public static var workspacesRoot: URL {
        if let override = ProcessInfo.processInfo.environment["DOMESTIQUE_WORKSPACES"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Domestique/workspaces", isDirectory: true)
    }

    /// Default home for repos cloned from GitHub: ~/Domestique/repos/<owner>/<name>.
    public static var defaultCloneRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Domestique/repos", isDirectory: true)
    }

    public static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Everything the sidebar needs. Small, so we keep it as one JSON file and write it atomically.
public struct AppState: Codable, Sendable {
    public var repositories: [Repository] = []
    public var workspaces: [Workspace] = []
    public var selectedWorkspaceID: UUID?
    public var settings: AppSettings = AppSettings()

    public init() {}
}

public struct AppSettings: Codable, Sendable, Hashable {
    public var defaultProvider: ProviderKind = .claude
    public var defaultPermissionMode: AgentPermissionMode = .bypass
    public var defaultClaudeModel: String?
    public var defaultCodexModel: String?
    public var defaultClaudeEffort: String?
    public var defaultCodexEffort: String?
    /// Prefix for new branches, e.g. "alex" -> alex/galibier.
    public var branchPrefix: String = NSUserName()
    public var editorCommand: String = "cursor"
    /// Where "Clone from GitHub" puts repos (nil = Paths.defaultCloneRoot). `~` is expanded.
    public var cloneDirectory: String?
    /// Custom ship instructions keyed by `ShipPromptKind.rawValue`; missing = built-in default.
    public var shipPrompts: [String: String]?

    public var cloneRoot: URL {
        guard let dir = cloneDirectory?.trimmingCharacters(in: .whitespaces), !dir.isEmpty else {
            return Paths.defaultCloneRoot
        }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// boat.dev defaults. Optional so settings saved before cloud support still decode.
    public var boatSettings: BoatSettings?

    public var boat: BoatSettings {
        get { boatSettings ?? BoatSettings() }
        set { boatSettings = newValue }
    }

    /// Sandbox providers (Settings → Sandbox Providers). nil until migrated: the old single boat.dev
    /// setup (`boatSettings` and the `api-key` Keychain item) becomes the first one.
    public var sandboxProviderList: [SandboxProviderConfig]?

    public var sandboxProviders: [SandboxProviderConfig] {
        get { sandboxProviderList ?? [SandboxProviderConfig.legacy(boat)] }
        set { sandboxProviderList = newValue }
    }

    /// The provider a sandbox workspace belongs to.
    public func provider(for host: WorkspaceHost?) -> SandboxProviderConfig? {
        sandboxProviders.first { $0.owns(host) }
    }

    /// Resolves a location to a provider; the old `.cloud(.boat)` means the first boat.dev provider.
    public func provider(for location: WorkspaceLocation?) -> SandboxProviderConfig? {
        switch location {
        case .sandbox(let id): sandboxProviders.first { $0.id == id }
        case .cloud(let kind): sandboxProviders.first { $0.kind == kind }
        default: nil
        }
    }

    /// Remote Team Cars (This Mac's is implicit). Optional so older settings still decode.
    public var teamCarList: [TeamCarConfig]?

    public var teamCars: [TeamCarConfig] {
        get { teamCarList ?? [] }
        set { teamCarList = newValue }
    }

    public init() {}
}

/// Defaults for new boat.dev workspaces.
public struct BoatSettings: Codable, Sendable, Hashable {
    /// small / default / large / xlarge.
    public var machineType: String = "default"
    /// Auto-stop after this many minutes from start/resume; nil = never (paid plans only).
    public var autoStopMinutes: Int? = 120
    /// Named boat environment (repos, secrets, AI credentials). nil = the account default.
    public var environment: String?
    /// When boat's own GitHub access can't clone a repo, give the sandbox your local `gh` token.
    public var shareGitHubToken: Bool = true
    /// Forward every port the stack listens on to the same port on this Mac.
    public var autoForwardPorts: Bool = true
    /// Archiving a workspace stops its sandbox (resumable for 14 days); deleting it deletes the sandbox.
    public var deleteOnArchive: Bool = false
    /// boat saved snapshot new sandboxes start from (`boat new --from`). nil = a fresh machine.
    public var fromSnapshot: String?

    public init() {}

    // Tolerant decoding: fields added later fall back to their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BoatSettings()
        machineType = try c.decodeIfPresent(String.self, forKey: .machineType) ?? d.machineType
        autoStopMinutes = try c.decodeIfPresent(Int.self, forKey: .autoStopMinutes)
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        shareGitHubToken = try c.decodeIfPresent(Bool.self, forKey: .shareGitHubToken) ?? d.shareGitHubToken
        autoForwardPorts = try c.decodeIfPresent(Bool.self, forKey: .autoForwardPorts) ?? d.autoForwardPorts
        deleteOnArchive = try c.decodeIfPresent(Bool.self, forKey: .deleteOnArchive) ?? d.deleteOnArchive
        fromSnapshot = try c.decodeIfPresent(String.self, forKey: .fromSnapshot)
    }
}

/// Persistence: one SQLite database (`domestique.sqlite` in the app-support folder) shared by every
/// running instance. Entities are stored as JSON blobs keyed by id, so Codable models evolve freely.
///
/// - `meta(key, value)`: settings, selection, schema/import markers
/// - `repositories(id, json, updated_at)`, `workspaces(id, repo_id, json, updated_at)`
/// - `transcript_items(tab_id, item_id, json)` — upserted; insertion order (rowid) is display order
///
/// Writes are diffed against what this instance last saved, so two instances editing different things
/// don't clobber each other. `dataVersion` changes when another instance commits.
public actor Store {
    public static let shared = Store()

    public nonisolated let db: SQLiteDB?
    public nonisolated var databasePath: String { Paths.database.path }

    private var lastSaved: [String: Data] = [:]  // "r:<id>" / "w:<id>" / "settings" -> json

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init() {
        Paths.ensure(Paths.appSupport)
        Paths.ensure(Paths.logs)
        Paths.ensure(Paths.icons)
        db = try? SQLiteDB(path: Paths.database.path)
        if let db { try? Self.migrate(db) }
    }

    private static func migrate(_ db: SQLiteDB) throws {
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB);
            CREATE TABLE IF NOT EXISTS repositories (id TEXT PRIMARY KEY, json BLOB NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS workspaces (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, json BLOB NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS transcript_items (
                tab_id TEXT NOT NULL, item_id TEXT NOT NULL, json BLOB NOT NULL,
                PRIMARY KEY (tab_id, item_id)
            );
            CREATE INDEX IF NOT EXISTS transcript_items_tab ON transcript_items(tab_id);
            INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '1');
            """)
    }

    // MARK: state

    /// Reads repositories, workspaces and settings (sync: used at launch).
    public nonisolated func loadStateSync() -> AppState {
        var state = AppState()
        guard let db else { return state }
        if let rows = try? db.query("SELECT json FROM repositories ORDER BY updated_at") {
            state.repositories = rows.compactMap { $0.first?.data }.compactMap { try? Self.decoder.decode(Repository.self, from: $0) }
                .sorted { $0.createdAt < $1.createdAt }
        }
        if let rows = try? db.query("SELECT json FROM workspaces") {
            state.workspaces = rows.compactMap { $0.first?.data }.compactMap { try? Self.decoder.decode(Workspace.self, from: $0) }
                .sorted { $0.createdAt < $1.createdAt }
        }
        if let data = try? db.query("SELECT value FROM meta WHERE key='settings'").first?.first?.data,
            let settings = try? Self.decoder.decode(AppSettings.self, from: data)
        {
            state.settings = settings
        }
        if let sel = try? db.query("SELECT value FROM meta WHERE key='selected_workspace'").first?.first?.string {
            state.selectedWorkspaceID = UUID(uuidString: sel)
        }
        return state
    }

    /// Call after loading so the next `save` only writes what this instance changes.
    public func markLoaded(_ state: AppState) {
        lastSaved = Self.snapshot(state)
    }

    public func save(_ state: AppState) {
        guard let db else { return }
        let now = Self.snapshot(state)
        let ts = Date().timeIntervalSince1970
        try? db.transaction {
            for (key, json) in now where lastSaved[key] != json {
                if key.hasPrefix("r:") {
                    try db.run(
                        "INSERT INTO repositories(id, json, updated_at) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json, updated_at=excluded.updated_at",
                        [.text(String(key.dropFirst(2))), .blob(json), .double(ts)])
                } else if key.hasPrefix("w:") {
                    let ws = try? Self.decoder.decode(Workspace.self, from: json)
                    try db.run(
                        "INSERT INTO workspaces(id, repo_id, json, updated_at) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json, repo_id=excluded.repo_id, updated_at=excluded.updated_at",
                        [.text(String(key.dropFirst(2))), .text(ws?.repoID.uuidString ?? ""), .blob(json), .double(ts)])
                } else if key == "settings" {
                    try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('settings', ?)", [.blob(json)])
                }
            }
            // Only delete what this instance itself removed (it saw them before).
            for key in lastSaved.keys where now[key] == nil {
                if key.hasPrefix("r:") {
                    try db.run("DELETE FROM repositories WHERE id=?", [.text(String(key.dropFirst(2)))])
                } else if key.hasPrefix("w:") {
                    try db.run("DELETE FROM workspaces WHERE id=?", [.text(String(key.dropFirst(2)))])
                }
            }
            try db.run(
                "INSERT OR REPLACE INTO meta(key, value) VALUES('selected_workspace', ?)",
                [state.selectedWorkspaceID.map { .text($0.uuidString) } ?? .null])
        }
        lastSaved = now
    }

    private static func snapshot(_ state: AppState) -> [String: Data] {
        var out: [String: Data] = [:]
        for r in state.repositories { if let d = try? encoder.encode(r) { out["r:\(r.id.uuidString)"] = d } }
        for w in state.workspaces { if let d = try? encoder.encode(w) { out["w:\(w.id.uuidString)"] = d } }
        if let d = try? encoder.encode(state.settings) { out["settings"] = d }
        return out
    }

    /// Changes whenever another instance commits.
    public nonisolated func dataVersion() -> Int64 { db?.dataVersion ?? 0 }

    // MARK: transcripts

    public func loadTranscript(tabID: UUID) -> [TranscriptItem] {
        transcriptItems(tabID: tabID, afterRowID: 0).items
    }

    /// Items in display order, plus the highest rowid seen (to fetch only newer ones later).
    public func transcriptItems(tabID: UUID, afterRowID: Int64) -> (items: [TranscriptItem], maxRowID: Int64) {
        guard let db,
            let rows = try? db.query(
                "SELECT rowid, json FROM transcript_items WHERE tab_id=? AND rowid>? ORDER BY rowid",
                [.text(tabID.uuidString), .int(afterRowID)])
        else { return ([], afterRowID) }
        var maxRow = afterRowID
        var items: [TranscriptItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            if let id = row[0].int { maxRow = max(maxRow, id) }
            if let data = row[1].data, let item = try? Self.decoder.decode(TranscriptItem.self, from: data) {
                items.append(item)
            }
        }
        return (items, maxRow)
    }

    /// Insert or update items. An updated item keeps its original position.
    public func append(_ items: [TranscriptItem], tabID: UUID) {
        guard let db, !items.isEmpty else { return }
        try? db.transaction {
            for item in items {
                guard let json = try? Self.encoder.encode(item) else { continue }
                try db.run(
                    "INSERT INTO transcript_items(tab_id, item_id, json) VALUES(?,?,?) ON CONFLICT(tab_id, item_id) DO UPDATE SET json=excluded.json",
                    [.text(tabID.uuidString), .text(item.id), .blob(json)])
            }
        }
    }

    public func deleteTranscript(tabID: UUID) {
        _ = try? db?.run("DELETE FROM transcript_items WHERE tab_id=?", [.text(tabID.uuidString)])
    }

}

/// Workspace names: famous climbs. Short, memorable, unique per repo.
public enum WorkspaceNames {
    static let climbs = [
        "ventoux", "galibier", "tourmalet", "stelvio", "zoncolan", "mortirolo", "angliru", "alpe", "izoard",
        "madeleine", "aubisque", "gavia", "finestre", "croix-de-fer", "glandon", "telegraphe", "peyresourde",
        "aspin", "joux-plane", "colombiere", "ballon", "planche", "superbagneres", "hautacam", "luz-ardiden",
        "portet", "envalira", "lagos", "bola-del-mundo", "mont-cenis", "iseran", "bonette", "vars", "agnel",
        "sestriere", "pordoi", "giau", "fedaia", "sella", "falzarego", "tre-cime", "grossglockner", "kitzbuhel",
        "mur-de-huy", "koppenberg", "paterberg", "oude-kwaremont", "muur", "kemmelberg", "poggio", "cipressa",
        "turchino", "ghisallo", "sormano", "colle-delle-finestre", "stelvio-north", "cormet", "saisies", "aravis",
        "semnoz", "salève", "granier", "chartreuse", "vercors", "lautaret", "allos", "cayolle", "turini",
        "madone", "eze", "teide", "puig-major", "sa-calobra", "ventoux-bedoin", "jaizkibel", "arrate",
    ]

    public static func next(excluding used: Set<String>) -> String {
        if let free = climbs.shuffled().first(where: { !used.contains($0) }) { return free }
        var n = 2
        while true {
            for c in climbs.shuffled() where !used.contains("\(c)-\(n)") { return "\(c)-\(n)" }
            n += 1
        }
    }
}

extension SandboxProviderConfig {
    /// Stable id for the provider made from pre-provider settings, so it's the same until saved.
    public static let legacyID = UUID(uuidString: "B0A7DE70-0000-4000-8000-000000000001")!

    /// The original single boat.dev setup as a provider.
    public static func legacy(_ boat: BoatSettings) -> SandboxProviderConfig {
        SandboxProviderConfig(id: legacyID, kind: .boat, name: "boat.dev", credentialAccount: "api-key", boat: boat)
    }
}
