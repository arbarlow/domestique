import Foundation
import Testing

@testable import DQCore

@Suite struct TOMLTests {
    @Test func scalarsAndComments() throws {
        let t = try TOML.parseTable(
            """
            # comment
            title = "hello \\"world\\"\\n"  # trailing
            lit = 'C:\\path'
            n = 1_000
            neg = -42
            hex = 0xff
            f = 3.5
            e = 1e3
            yes = true
            no = false
            "quoted key" = 1
            date = 1979-05-27T07:32:00Z
            """)
        #expect(t["title"]?.string == "hello \"world\"\n")
        #expect(t["lit"]?.string == "C:\\path")
        #expect(t["n"]?.integer == 1000)
        #expect(t["neg"]?.integer == -42)
        #expect(t["hex"]?.integer == 255)
        #expect(t["f"] == .float(3.5))
        #expect(t["e"] == .float(1000))
        #expect(t["yes"]?.bool == true)
        #expect(t["no"]?.bool == false)
        #expect(t["quoted key"]?.integer == 1)
        #expect(t["date"]?.string == "1979-05-27T07:32:00Z")
    }

    @Test func multilineStrings() throws {
        let t = try TOML.parseTable(
            #"""
            a = """
            line1
            line2"""
            b = '''
            raw \n stays'''
            c = """one \
                two"""
            """#)
        #expect(t["a"]?.string == "line1\nline2")
        #expect(t["b"]?.string == "raw \\n stays")
        #expect(t["c"]?.string == "one two")
    }

    @Test func tablesDottedKeysAndOrder() throws {
        let t = try TOML.parseTable(
            """
            [tasks.zeta]
            command = "z"
            [tasks.alpha]
            command = "a"
            env = { PORT = "1", B = 2 }
            [tasks.mid]
            command = "m"
            nested.deep.key = "v"
            """)
        let tasks = try #require(t["tasks"]?.table)
        #expect(tasks.keys == ["zeta", "alpha", "mid"])
        #expect(tasks["alpha"]?.table?["env"]?.table?["PORT"]?.string == "1")
        #expect(tasks["alpha"]?.table?["env"]?.table?["B"]?.integer == 2)
        #expect(tasks["mid"]?.table?["nested"]?.table?["deep"]?.table?["key"]?.string == "v")
    }

    @Test func arraysAndArrayOfTables() throws {
        let t = try TOML.parseTable(
            """
            list = [
              "a", # one
              "b",
            ]
            nums = [1, 2, [3, 4]]
            [[servers]]
            name = "x"
            [[servers]]
            name = "y"
            [servers.meta]
            ok = true
            """)
        #expect(t["list"] == .array([.string("a"), .string("b")]))
        #expect(t["nums"] == .array([.integer(1), .integer(2), .array([.integer(3), .integer(4)])]))
        let servers = try #require(t["servers"]?.array)
        #expect(servers.count == 2)
        #expect(servers[1].table?["name"]?.string == "y")
        #expect(servers[1].table?["meta"]?.table?["ok"]?.bool == true)
    }

    @Test func jsonConversion() throws {
        let j = try TOML.parse("a = 1\n[b]\nc = \"d\"\n")
        #expect(j["a"]?.int == 1)
        #expect(j["b"]?["c"]?.string == "d")
    }

    @Test func errorsHaveLineNumbers() {
        do {
            _ = try TOML.parseTable("a = 1\nb = \nc = 2")
            Issue.record("expected error")
        } catch let e as TOMLError {
            #expect(e.line == 2)
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(throws: TOMLError.self) { try TOML.parseTable("a = \"unterminated") }
        #expect(throws: TOMLError.self) { try TOML.parseTable("a = 1 junk") }
    }
}

@Suite struct RepoConfigParseTests {
    static let sample = """
        [setup]
        script = "bun install"
        copy = [".env", ".env.local"]

        [archive]
        script = "docker compose down"

        [tasks.web]
        name = "Web"
        command = "bun run dev -- --port $DOMESTIQUE_PORT_1"
        ready_pattern = "Local:"
        open = "http://localhost:$DOMESTIQUE_PORT_1"

        [tasks.api]
        command = "bun run dev:api"
        env = { PORT = "$DOMESTIQUE_PORT" }
        ready_port = 4000
        cwd = "server"
        unknown_key = "ignored"

        [tasks.test]
        command = "bun test"
        kind = "oneshot"

        [stacks.dev]
        name = "Dev stack"
        tasks = ["api", "web"]

        [stacks.all]
        tasks = ["web", "api", "test"]

        [trunk]
        gate = ["test"]
        """

    @Test func mapsSchema() throws {
        let c = try RepoConfig.parse(toml: Self.sample)
        #expect(c.setupScript == "bun install")
        #expect(c.copyFiles == [".env", ".env.local"])
        #expect(c.archiveScript == "docker compose down")
        #expect(c.tasks.map(\.id) == ["web", "api", "test"])
        let web = try #require(c.task("web"))
        #expect(web.name == "Web")
        #expect(web.kind == .service)
        #expect(web.readyPattern == "Local:")
        #expect(web.open == "http://localhost:$DOMESTIQUE_PORT_1")
        let api = try #require(c.task("api"))
        #expect(api.name == "api")
        #expect(api.env == ["PORT": "$DOMESTIQUE_PORT"])
        #expect(api.readyPort == "4000")
        #expect(api.cwd == "server")
        #expect(c.task("test")?.kind == .oneshot)
        #expect(c.stacks.map(\.id) == ["dev", "all"])
        #expect(c.stacks[0].name == "Dev stack")
        #expect(c.stacks[0].tasks == ["api", "web"])
        #expect(c.stacks[1].name == "all")
        #expect(c.trunkGate == ["test"])
    }

    @Test func validation() {
        #expect(throws: RepoConfigError.self) { try RepoConfig.parse(toml: "[tasks.a]\nname = \"x\"") }
        #expect(throws: RepoConfigError.self) { try RepoConfig.parse(toml: "[tasks.a]\ncommand = \"x\"\nkind = \"daemon\"") }
        #expect(throws: RepoConfigError.self) {
            try RepoConfig.parse(toml: "[tasks.a]\ncommand = \"x\"\n[stacks.s]\ntasks = [\"nope\"]")
        }
    }

    @Test func emptyAndTemplate() throws {
        let empty = try RepoConfig.parse(toml: "")
        #expect(empty == RepoConfig())
        // The starter template is valid TOML (everything optional is commented out).
        let t = try RepoConfig.parse(toml: RepoConfig.template)
        #expect(t.tasks.isEmpty)
    }

    @Test func loadFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dq-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try RepoConfig.load(directory: dir.path) == nil)
        try Self.sample.write(to: dir.appendingPathComponent(RepoConfig.fileName), atomically: true, encoding: .utf8)
        #expect(try RepoConfig.load(directory: dir.path)?.tasks.count == 3)
    }
}

@Suite struct WorkspaceEnvironmentTests {
    @Test func expand() {
        let vars = ["DOMESTIQUE_PORT": "41000", "DOMESTIQUE_PORT_1": "41001", "X": "y"]
        #expect(WorkspaceEnvironment.expand("http://localhost:$DOMESTIQUE_PORT_1/", vars) == "http://localhost:41001/")
        #expect(WorkspaceEnvironment.expand("${DOMESTIQUE_PORT}x", vars) == "41000x")
        #expect(WorkspaceEnvironment.expand("$X-$UNKNOWN", vars) == "y-$UNKNOWN")
        #expect(WorkspaceEnvironment.expand("cost $5", vars) == "cost $5")
        #expect(WorkspaceEnvironment.expand("trailing $", vars) == "trailing $")
    }

    @Test func variables() {
        let repo = Repository(name: "r", path: "/src/r", remoteURL: nil, defaultBranch: "main")
        let ws = Workspace(repoID: repo.id, name: "ventoux", branch: "a/ventoux", path: "/w/ventoux", baseBranch: "main", portBase: 41010)
        let env = WorkspaceEnvironment.variables(workspace: ws, repo: repo)
        #expect(env["DOMESTIQUE_PORT"] == "41010")
        #expect(env["DOMESTIQUE_PORT_9"] == "41019")
        #expect(env["DOMESTIQUE_ROOT_PATH"] == "/src/r")
    }
}
