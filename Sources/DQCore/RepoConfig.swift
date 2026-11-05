import Foundation

/// Parsed `domestique.toml` from the root of a repo / workspace.
///
/// ```toml
/// [setup]
/// script = "bun install"
/// copy = [".env", ".env.local"]
///
/// [archive]
/// script = "docker compose down"
///
/// [tasks.api]
/// name = "API"
/// command = "bun run dev:api"
/// env = { PORT = "$DOMESTIQUE_PORT" }
/// ready_port = "$DOMESTIQUE_PORT"
///
/// [tasks.web]
/// command = "bun run dev:web -- --port $DOMESTIQUE_PORT_1"
/// open = "http://localhost:$DOMESTIQUE_PORT_1"
///
/// [tasks.test]
/// command = "bun test"
/// kind = "oneshot"
///
/// [stacks.dev]
/// name = "Dev stack"
/// tasks = ["api", "web"]
///
/// [trunk]
/// gate = ["test"]   # tasks that must pass before pushing to main
/// ```
public struct RepoConfig: Sendable, Hashable {
    public var setupScript: String?
    public var copyFiles: [String]
    public var archiveScript: String?
    /// In file order.
    public var tasks: [TaskConfig]
    /// In file order.
    public var stacks: [StackConfig]
    public var trunkGate: [String]

    public init(
        setupScript: String? = nil, copyFiles: [String] = [], archiveScript: String? = nil,
        tasks: [TaskConfig] = [], stacks: [StackConfig] = [], trunkGate: [String] = []
    ) {
        self.setupScript = setupScript
        self.copyFiles = copyFiles
        self.archiveScript = archiveScript
        self.tasks = tasks
        self.stacks = stacks
        self.trunkGate = trunkGate
    }

    public static let fileName = "domestique.toml"

    public func task(_ id: String) -> TaskConfig? { tasks.first { $0.id == id } }
}

public struct TaskConfig: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// Long-running (dev server). Shown with a running/stopped pill.
        case service
        /// Runs to completion (tests, lint). Shown with pass/fail.
        case oneshot
    }

    public var id: String
    public var name: String
    public var command: String
    public var kind: Kind
    public var env: [String: String]
    /// Relative to the workspace root.
    public var cwd: String?
    /// Port (may contain $VARS) that means "ready" once something listens on it.
    public var readyPort: String?
    /// Regex on log output that means "ready".
    public var readyPattern: String?
    /// URL template (may contain $VARS) for the "Open" button.
    public var open: String?

    public init(
        id: String, name: String? = nil, command: String, kind: Kind = .service, env: [String: String] = [:],
        cwd: String? = nil, readyPort: String? = nil, readyPattern: String? = nil, open: String? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.command = command
        self.kind = kind
        self.env = env
        self.cwd = cwd
        self.readyPort = readyPort
        self.readyPattern = readyPattern
        self.open = open
    }
}

public struct StackConfig: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var tasks: [String]

    public init(id: String, name: String? = nil, tasks: [String]) {
        self.id = id
        self.name = name ?? id
        self.tasks = tasks
    }
}

/// Environment every script/task/terminal in a workspace gets.
public enum WorkspaceEnvironment {
    public static let portCount = 10

    public static func variables(workspace: Workspace, repo: Repository) -> [String: String] {
        var env: [String: String] = [
            "DOMESTIQUE": "1",
            "DOMESTIQUE_WORKSPACE": workspace.name,
            "DOMESTIQUE_WORKSPACE_PATH": workspace.path,
            // A cloud workspace has no main checkout on its machine: the clone is the root.
            "DOMESTIQUE_ROOT_PATH": workspace.isRemote ? workspace.path : repo.path,
            "DOMESTIQUE_BRANCH": workspace.branch,
            "DOMESTIQUE_DEFAULT_BRANCH": repo.defaultBranch,
            "DOMESTIQUE_PORT": String(workspace.portBase),
        ]
        for i in 0..<portCount { env["DOMESTIQUE_PORT_\(i)"] = String(workspace.portBase + i) }
        // Compatibility: scripts written for Conductor read these names.
        env["CONDUCTOR_PORT"] = String(workspace.portBase)
        env["CONDUCTOR_ROOT_PATH"] = workspace.isRemote ? workspace.path : repo.path
        env["CONDUCTOR_WORKSPACE_PATH"] = workspace.path
        env["CONDUCTOR_WORKSPACE_NAME"] = workspace.name
        env["CONDUCTOR_DEFAULT_BRANCH"] = repo.defaultBranch
        return env
    }

    /// Expands `$VAR` and `${VAR}` using `vars`. Unknown variables are left as-is.
    public static func expand(_ template: String, _ vars: [String: String]) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            guard c == "$" else {
                out.append(c)
                i = template.index(after: i)
                continue
            }
            var j = template.index(after: i)
            var name = ""
            if j < template.endIndex, template[j] == "{" {
                j = template.index(after: j)
                while j < template.endIndex, template[j] != "}" {
                    name.append(template[j])
                    j = template.index(after: j)
                }
                if j < template.endIndex { j = template.index(after: j) }
            } else {
                while j < template.endIndex, template[j].isLetter || template[j].isNumber || template[j] == "_" {
                    name.append(template[j])
                    j = template.index(after: j)
                }
            }
            if let v = vars[name], !name.isEmpty {
                out += v
            } else {
                out += template[i..<j]
            }
            i = j
        }
        return out
    }
}
