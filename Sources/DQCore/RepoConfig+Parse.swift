import Foundation

public struct RepoConfigError: Error, LocalizedError, Sendable, Hashable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { "\(RepoConfig.fileName): \(message)" }
}

extension RepoConfig {
    /// Parses the contents of a `domestique.toml`. Unknown keys are ignored.
    public static func parse(toml: String) throws -> RepoConfig {
        let root = try TOML.parseTable(toml)
        var config = RepoConfig()

        // [setup]
        if let setup = root["setup"] {
            if let s = setup.string {
                config.setupScript = s
            } else if let t = setup.table {
                config.setupScript = try optionalString(t["script"], "setup.script")
                config.copyFiles = try stringArray(t["copy"], "setup.copy")
            }
        }

        // [archive]
        if let archive = root["archive"] {
            if let s = archive.string {
                config.archiveScript = s
            } else if let t = archive.table {
                config.archiveScript = try optionalString(t["script"], "archive.script")
            }
        }

        // [tasks.<id>]
        if let tasks = root["tasks"] {
            guard let table = tasks.table else { throw RepoConfigError("`tasks` must be a table of [tasks.<id>]") }
            for (id, value) in table.entries {
                guard let t = value.table else { throw RepoConfigError("tasks.\(id) must be a table") }
                guard let command = try optionalString(t["command"], "tasks.\(id).command"),
                    !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RepoConfigError("tasks.\(id) is missing `command`") }
                var kind = TaskConfig.Kind.service
                if let k = try optionalString(t["kind"], "tasks.\(id).kind") {
                    guard let parsed = TaskConfig.Kind(rawValue: k) else {
                        throw RepoConfigError("tasks.\(id).kind must be \"service\" or \"oneshot\"")
                    }
                    kind = parsed
                }
                var env: [String: String] = [:]
                if let e = t["env"] {
                    guard let et = e.table else { throw RepoConfigError("tasks.\(id).env must be a table") }
                    for (k, v) in et.entries { env[k] = try scalarString(v, "tasks.\(id).env.\(k)") }
                }
                let readyPort = try t["ready_port"].map { try scalarString($0, "tasks.\(id).ready_port") }
                config.tasks.append(
                    TaskConfig(
                        id: id,
                        name: try optionalString(t["name"], "tasks.\(id).name"),
                        command: command,
                        kind: kind,
                        env: env,
                        cwd: try optionalString(t["cwd"], "tasks.\(id).cwd"),
                        readyPort: readyPort,
                        readyPattern: try optionalString(t["ready_pattern"], "tasks.\(id).ready_pattern"),
                        open: try optionalString(t["open"], "tasks.\(id).open")
                    ))
            }
        }

        // [stacks.<id>]
        if let stacks = root["stacks"] {
            guard let table = stacks.table else { throw RepoConfigError("`stacks` must be a table of [stacks.<id>]") }
            for (id, value) in table.entries {
                let stack: StackConfig
                if let list = value.array {
                    // Shorthand: dev = ["api", "web"]
                    stack = StackConfig(id: id, tasks: try stringArray(.array(list), "stacks.\(id)"))
                } else if let t = value.table {
                    stack = StackConfig(
                        id: id, name: try optionalString(t["name"], "stacks.\(id).name"),
                        tasks: try stringArray(t["tasks"], "stacks.\(id).tasks"))
                } else {
                    throw RepoConfigError("stacks.\(id) must be a table")
                }
                for taskID in stack.tasks where !config.tasks.contains(where: { $0.id == taskID }) {
                    throw RepoConfigError("stacks.\(id) references unknown task \"\(taskID)\"")
                }
                config.stacks.append(stack)
            }
        }

        // [trunk]
        if let trunk = root["trunk"]?.table {
            config.trunkGate = try stringArray(trunk["gate"], "trunk.gate")
        }

        return config
    }

    /// Loads `<directory>/domestique.toml`. Returns nil when the file doesn't exist.
    public static func load(directory: String) throws -> RepoConfig? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(toml: text)
    }

    /// Commented starter file the app writes when the user asks to create one.
    public static let template: String = """
        # domestique.toml — workspace scripts for Domestique.
        #
        # Every script, task and terminal gets these environment variables:
        #   DOMESTIQUE_PORT, DOMESTIQUE_PORT_0 … DOMESTIQUE_PORT_9   ports reserved for this workspace
        #   DOMESTIQUE_WORKSPACE        workspace name (e.g. "galibier")
        #   DOMESTIQUE_WORKSPACE_PATH   this worktree
        #   DOMESTIQUE_ROOT_PATH        your original clone (handy for copying secrets)
        #   DOMESTIQUE_BRANCH, DOMESTIQUE_DEFAULT_BRANCH

        [setup]
        # Runs once when a workspace is created.
        # script = "bun install"
        # Files copied from your original clone (skipped if missing, never overwritten).
        # copy = [".env", ".env.local"]

        # [archive]
        # Runs before a workspace's worktree is removed.
        # script = "docker compose down"

        # Long-running services show a status pill, live logs and detected ports.
        # [tasks.api]
        # name = "API"
        # command = "bun run dev:api"
        # env = { PORT = "$DOMESTIQUE_PORT" }
        # ready_port = "$DOMESTIQUE_PORT"         # ready once something listens here
        #
        # [tasks.web]
        # name = "Web"
        # command = "bun run dev -- --port $DOMESTIQUE_PORT_1"
        # ready_pattern = "Local:.*http"           # or match a log line
        # open = "http://localhost:$DOMESTIQUE_PORT_1"

        # One-shot tasks run to completion and show pass/fail.
        # [tasks.test]
        # name = "Tests"
        # command = "bun test"
        # kind = "oneshot"

        # Stacks start several tasks with one click.
        # [stacks.dev]
        # name = "Dev stack"
        # tasks = ["api", "web"]

        # Trunk mode: tasks that must pass before pushing to the default branch.
        # [trunk]
        # gate = ["test"]

        """

    // MARK: helpers

    private static func optionalString(_ v: TOMLValue?, _ key: String) throws -> String? {
        guard let v else { return nil }
        guard let s = v.string else { throw RepoConfigError("`\(key)` must be a string") }
        return s
    }

    private static func scalarString(_ v: TOMLValue, _ key: String) throws -> String {
        switch v {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .float(let d): return String(d)
        case .bool(let b): return String(b)
        default: throw RepoConfigError("`\(key)` must be a string or number")
        }
    }

    private static func stringArray(_ v: TOMLValue?, _ key: String) throws -> [String] {
        guard let v else { return [] }
        if let s = v.string { return [s] }
        guard let a = v.array else { throw RepoConfigError("`\(key)` must be an array of strings") }
        return try a.map {
            guard let s = $0.string else { throw RepoConfigError("`\(key)` must be an array of strings") }
            return s
        }
    }
}
