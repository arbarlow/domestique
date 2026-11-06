import Foundation

// MARK: - Providers & modes

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// How much the agent may do without asking.
/// - bypass: never ask (Claude `bypassPermissions`, Codex `never` + full access). Default.
/// - auto: provider's own reviewer decides (Claude `auto` classifier, Codex `auto_review`).
/// - ask: every risky action comes back to the UI for approval.
public enum AgentPermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case bypass
    case auto
    case ask

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .bypass: "Full access"
        case .auto: "Auto"
        case .ask: "Ask"
        }
    }
}

public enum ShipMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Push branch, open PR, watch checks, merge.
    case pullRequest
    /// Rebase onto origin/<default> and fast-forward push straight to it.
    case trunk

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .pullRequest: "Pull request"
        case .trunk: "Trunk"
        }
    }
}

// MARK: - Repository / Workspace / Tab

public struct Repository: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// The user's original clone. We only use it as an object store + remote config;
    /// new work always branches from a fresh fetch of origin/<defaultBranch>.
    public var path: String
    public var remoteURL: String?
    public var defaultBranch: String
    public var shipMode: ShipMode
    public var createdAt: Date
    /// Shown instead of `name` when set. `name` stays the folder-safe id used for worktree paths.
    public var displayName: String?
    public var icon: RepoIcon?
    /// Where new workspaces run (nil = the default Team Car's default, from Settings → Team Cars).
    public var defaultLocation: WorkspaceLocation?

    public var title: String { (displayName?.isEmpty == false ? displayName : nil) ?? name }

    public init(
        id: UUID = UUID(), name: String, path: String, remoteURL: String?, defaultBranch: String,
        shipMode: ShipMode = .pullRequest, createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.remoteURL = remoteURL
        self.defaultBranch = defaultBranch
        self.shipMode = shipMode
        self.createdAt = createdAt
    }

    /// "owner/repo" if the remote is GitHub.
    public var githubSlug: String? { GitHubRemote.slug(from: remoteURL) }
}

public enum WorkspaceState: Codable, Sendable, Hashable {
    case creating
    case settingUp
    case ready
    case failed(String)
    case archived
}

public struct Workspace: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var repoID: UUID
    /// Short human name, e.g. "galibier". Also the worktree directory name.
    public var name: String
    public var branch: String
    public var path: String
    public var baseBranch: String
    /// Commit of origin/<base> we branched from.
    public var baseCommit: String?
    /// First of 10 consecutive ports reserved for this workspace (DOMESTIQUE_PORT).
    public var portBase: Int
    public var state: WorkspaceState
    public var createdAt: Date
    public var prNumber: Int?
    public var prURL: String?
    /// Overrides the repo's ship mode when set.
    public var shipModeOverride: ShipMode?
    public var tabs: [ChatTab]
    public var selectedTabID: UUID?
    /// Unread marker: agent finished while user was elsewhere.
    public var hasUnread: Bool
    /// The machine this workspace runs on. nil = a local worktree on this Mac.
    public var host: WorkspaceHost?
    /// Last time this workspace's work was pushed straight to its base branch (trunk). Like a merged PR,
    /// the work has landed, but it can still be pushed again. nil = never pushed to trunk.
    public var trunkPushedAt: Date?
    /// Commit that push put on the base branch.
    public var trunkPushedCommit: String?
    /// Chat tabs closed in this workspace, most recent first, so they can be reopened (transcripts kept).
    public var closedTabs: [ClosedChatTab]?

    public init(
        id: UUID = UUID(), repoID: UUID, name: String, branch: String, path: String, baseBranch: String,
        baseCommit: String? = nil, portBase: Int, state: WorkspaceState = .creating, createdAt: Date = .now,
        prNumber: Int? = nil, prURL: String? = nil, shipModeOverride: ShipMode? = nil, tabs: [ChatTab] = [],
        selectedTabID: UUID? = nil, hasUnread: Bool = false
    ) {
        self.id = id
        self.repoID = repoID
        self.name = name
        self.branch = branch
        self.path = path
        self.baseBranch = baseBranch
        self.baseCommit = baseCommit
        self.portBase = portBase
        self.state = state
        self.createdAt = createdAt
        self.prNumber = prNumber
        self.prURL = prURL
        self.shipModeOverride = shipModeOverride
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.hasUnread = hasUnread
    }

    public var isArchived: Bool { if case .archived = state { true } else { false } }
    public var isPushedToTrunk: Bool { trunkPushedAt != nil }
    public var isRemote: Bool { host != nil }
    public var location: WorkspaceLocation {
        guard let host else { return .local }
        if host.provider == .teamcar, let id = UUID(uuidString: host.machineID) { return .teamCar(id) }
        return host.provider.location  // sandbox workspaces: resolve with AppSettings.provider(for:)
    }
    /// On a boat.dev sandbox (machine status, auto-stop, SSH port forwarding apply).
    public var isSandbox: Bool { host?.provider == .boat }
    /// On a remote Team Car.
    public var teamCarID: UUID? { host?.provider == .teamcar ? host.flatMap { UUID(uuidString: $0.machineID) } : nil }
}

// MARK: - Where workspaces run

/// Cloud machine providers. Only boat.dev today; the rest of the app talks to `CloudProviderID`.
public enum CloudProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case boat
    /// A Team Car server the user runs (`WorkspaceHost.machineID` is the car's id).
    case teamcar

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .boat: "boat.dev"
        case .teamcar: "Team Car"
        }
    }
    public var location: WorkspaceLocation { .cloud(self) }
    /// Machines the app creates and manages (status, auto-stop, port forwarding over SSH).
    public static var sandboxes: [CloudProviderID] { [.boat] }
}

/// A choice in "run new workspaces on…".
public enum WorkspaceLocation: Codable, Sendable, Hashable, Identifiable {
    case local
    case cloud(CloudProviderID)
    /// A worktree on a remote Team Car from Settings → Team Cars.
    case teamCar(UUID)
    /// A sandbox from one of a Team Car's sandbox providers (e.g. one boat.dev account).
    case sandbox(UUID)

    public var id: String {
        switch self {
        case .local: "local"
        case .cloud(let p): p.rawValue
        case .teamCar(let id): "teamcar:" + id.uuidString
        case .sandbox(let id): "sandbox:" + id.uuidString
        }
    }
    /// Generic label; the app shows a Team Car's own name instead.
    public var displayName: String {
        switch self {
        case .local: "This Mac"
        case .cloud(let p): p.displayName
        case .teamCar: "Team Car"
        case .sandbox: "Sandbox"
        }
    }
    /// The fixed locations (sandbox providers and Team Cars come from settings).
    public static var all: [WorkspaceLocation] { [.local] }
}

/// A sandbox provider in Settings → Team Cars: one account on a sandbox service (boat.dev
/// today) with its own defaults. Several can exist (accounts, teams, or presets like "boat · large").
///
/// Each provider belongs to a Team Car (`home`), which keeps its API key and makes every call to the
/// service. The app's copy is a cache of what the car reported plus this Mac's own preferences
/// (sharing the GitHub login, forwarding ports). Providers from before Team Car have no `home` and
/// use the Keychain key on this Mac until This Mac's car takes them over.
public struct SandboxProviderConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: CloudProviderID
    public var name: String
    /// Keychain account for this provider's API key (and the key `WorkspaceHost.accountID` uses to
    /// find the provider). The first provider keeps the original `api-key`.
    public var credentialAccount: String
    public var boat: BoatSettings
    /// The Team Car that owns this provider. nil = this Mac's Keychain (not yet moved to a car).
    public var home: SandboxProviderHome?
    /// What the owning car last reported about it.
    public var carStatus: SandboxProviderCarStatus?

    /// Whether a Team Car owns it.
    public var isOnTeamCar: Bool { home != nil }
    /// The remote car that owns it (nil for This Mac's car and for app-only providers).
    public var remoteCarID: UUID? { if case .teamCar(let id) = home { id } else { nil } }

    public init(id: UUID = UUID(), kind: CloudProviderID = .boat, name: String, credentialAccount: String? = nil,
                boat: BoatSettings = BoatSettings()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.credentialAccount = credentialAccount ?? "api-key.\(id.uuidString.lowercased())"
        self.boat = boat
    }

    /// Whether a workspace's sandbox belongs to this provider.
    public func owns(_ host: WorkspaceHost?) -> Bool {
        guard let host, host.provider == kind else { return false }
        return (host.accountID ?? "api-key") == credentialAccount
    }
}

/// A Team Car: This Mac's or a remote one from Settings → Team Cars. Also says which car owns a
/// sandbox provider.
public enum SandboxProviderHome: Codable, Sendable, Hashable {
    case thisMac
    case teamCar(UUID)

    /// Stable key for per-car settings.
    public var key: String {
        switch self {
        case .thisMac: "this-mac"
        case .teamCar(let id): id.uuidString.lowercased()
        }
    }
}

/// This Mac's choices for new workspaces on one Team Car.
public struct CarPreferences: Codable, Sendable, Hashable {
    /// Offer git worktrees on the car itself. Off for a car that should only start sandboxes (or a
    /// laptop you don't want workspaces on).
    public var worktrees: Bool
    /// What "New workspace on <car>" makes: nil = a worktree, else one of the car's sandbox providers.
    public var defaultSandbox: UUID?

    public init(worktrees: Bool = true, defaultSandbox: UUID? = nil) {
        self.worktrees = worktrees
        self.defaultSandbox = defaultSandbox
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        worktrees = try c.decodeIfPresent(Bool.self, forKey: .worktrees) ?? true
        defaultSandbox = try c.decodeIfPresent(UUID.self, forKey: .defaultSandbox)
    }
}

/// A provider's state as its Team Car reports it (never the key itself).
public struct SandboxProviderCarStatus: Codable, Sendable, Hashable {
    /// "stored", "config" (teamcar.toml's api_key_env / api_key_file), "environment" (BOAT_API_KEY),
    /// "cli" (`boat login`) or "none".
    public var credentialSource: String
    /// Declared in the car's teamcar.toml, so it can't be edited from here.
    public var fromConfig: Bool

    public init(credentialSource: String, fromConfig: Bool) {
        self.credentialSource = credentialSource
        self.fromConfig = fromConfig
    }

    public var hasKey: Bool { credentialSource != "none" }
}

/// A Team Car server in Settings → Team Cars. Its token lives in the Keychain, keyed by `id`.
/// App-wide: every repository can create workspaces on every car.
public struct TeamCarConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// ws:// or wss:// (path /radio/v1 is added when missing).
    public var url: String

    public init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }

    /// The server's host name, used for links to ports opened there.
    public var hostName: String? { URL(string: url)?.host }
}

/// A cloud machine a workspace lives on. One machine per workspace.
public struct WorkspaceHost: Codable, Sendable, Hashable {
    public var provider: CloudProviderID
    /// Provider's machine id (boat: `bx_…`).
    public var machineID: String
    public var machineName: String?
    /// Machine size it was created with (boat: small/default/large/xlarge).
    public var machineType: String?
    /// boat.dev: the sandbox provider's Keychain account (`SandboxProviderConfig.credentialAccount`).
    /// nil = the original provider.
    public var accountID: String?

    public init(provider: CloudProviderID, machineID: String, machineName: String? = nil, machineType: String? = nil) {
        self.provider = provider
        self.machineID = machineID
        self.machineName = machineName
        self.machineType = machineType
    }

    /// Matches `ExecutionHost.id`.
    public var hostID: String { "\(provider.rawValue):\(machineID)" }
}

public struct ChatTab: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var provider: ProviderKind
    /// nil = provider default.
    public var model: String?
    /// Thinking level; nil = the model's default.
    public var effort: String?
    public var permissionMode: AgentPermissionMode
    /// Claude session id / Codex thread id, used to resume after relaunch.
    public var providerSessionID: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), title: String = "New chat", provider: ProviderKind, model: String? = nil,
        permissionMode: AgentPermissionMode = .bypass, providerSessionID: String? = nil, createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.provider = provider
        self.model = model
        self.permissionMode = permissionMode
        self.providerSessionID = providerSessionID
        self.createdAt = createdAt
    }
}

/// A chat tab that was closed and can be reopened.
public struct ClosedChatTab: Codable, Sendable, Identifiable, Hashable {
    public var tab: ChatTab
    public var closedAt: Date
    public var id: UUID { tab.id }

    public init(tab: ChatTab, closedAt: Date = .now) {
        self.tab = tab
        self.closedAt = closedAt
    }

    /// How many closed tabs a workspace remembers; older ones are forgotten (and their transcripts deleted).
    public static let limit = 20
}

// MARK: - Transcript

public struct TranscriptItem: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var timestamp: Date
    public var kind: Kind

    public init(id: String, timestamp: Date = .now, kind: Kind) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
    }

    public enum Kind: Codable, Sendable, Hashable {
        case user(text: String)
        /// Markdown text from the agent.
        case assistant(text: String)
        case reasoning(text: String)
        case tool(ToolCall)
        case approval(ApprovalRequest)
        case notice(text: String)
        case error(text: String)
        case turnSummary(TurnSummary)
        /// A turn the agent started on its own (e.g. a background subagent finished).
        case trigger(text: String)
    }
}

public struct ToolCall: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case running, completed, failed, declined }

    /// Normalised: "Bash", "Read", "Edit", "Write", "Grep", "WebSearch", "MCP", "Task", ...
    public var name: String
    /// One-line description, e.g. the command or the file path.
    public var summary: String
    /// Full input rendered as text (JSON or command).
    public var input: String
    public var output: String
    public var status: Status
    /// Unified diff per file for edits, when the provider gives it to us.
    public var fileChanges: [FileChange]
    /// The agent's own short description of the call ("Find table end and row markup"), when it gives one.
    /// Claude sends this for Bash; Codex has no equivalent.
    public var description: String?

    public init(
        name: String, summary: String, input: String = "", output: String = "", status: Status = .running,
        fileChanges: [FileChange] = [], description: String? = nil
    ) {
        self.name = name
        self.summary = summary
        self.input = input
        self.output = output
        self.status = status
        self.fileChanges = fileChanges
        self.description = description
    }
}

public struct FileChange: Codable, Sendable, Hashable {
    public var path: String
    public var diff: String
    public init(path: String, diff: String) {
        self.path = path
        self.diff = diff
    }
}

public struct ApprovalRequest: Codable, Sendable, Hashable {
    public enum Resolution: String, Codable, Sendable { case pending, approved, approvedForSession, denied, answered, cancelled }
    /// Provider request id we must answer.
    public var requestID: String
    public var title: String
    public var detail: String
    public var resolution: Resolution
    /// When non-empty this is a question for the user (Claude AskUserQuestion / Codex requestUserInput)
    /// rather than a yes/no approval. Answer with `AgentSession.answer`.
    public var questions: [AgentQuestion]
    /// Answers given, keyed by question id.
    public var answers: [String: String]

    public init(
        requestID: String, title: String, detail: String, resolution: Resolution = .pending,
        questions: [AgentQuestion] = [], answers: [String: String] = [:]
    ) {
        self.requestID = requestID
        self.title = title
        self.detail = detail
        self.resolution = resolution
        self.questions = questions
        self.answers = answers
    }

    public var isQuestion: Bool { !questions.isEmpty }
}

public struct AgentQuestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [Option]
    public var multiSelect: Bool

    public struct Option: Codable, Sendable, Hashable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public init(id: String, header: String, question: String, options: [Option], multiSelect: Bool = false) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }
}

public enum ApprovalDecision: Sendable {
    case approve
    case approveForSession
    case deny(message: String?)
}

public struct TurnSummary: Codable, Sendable, Hashable {
    public var durationMs: Int?
    public var costUSD: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var isError: Bool
    public var message: String?

    public init(
        durationMs: Int? = nil, costUSD: Double? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
        isError: Bool = false, message: String? = nil
    ) {
        self.durationMs = durationMs
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.isError = isError
        self.message = message
    }
}

public struct ModelOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var description: String?
    /// Thinking / reasoning effort levels this model accepts ("low", "medium", "high", …). Empty = not supported.
    public var efforts: [String]
    public var defaultEffort: String?
    /// The provider's default model (what "Default" resolves to).
    public var isDefault: Bool

    public init(
        id: String, displayName: String, description: String? = nil, efforts: [String] = [],
        defaultEffort: String? = nil, isDefault: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.isDefault = isDefault
    }
}

/// How a repository is drawn in the sidebar and headers.
public struct RepoIcon: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case monogram, symbol, emoji, image }

    public var kind: Kind
    public var symbol: String?
    public var emoji: String?
    /// "#RRGGBB" background for monogram/symbol.
    public var colorHex: String?
    /// File name inside Paths.icons for `.image`.
    public var imageFile: String?

    public init(kind: Kind, symbol: String? = nil, emoji: String? = nil, colorHex: String? = nil, imageFile: String? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.emoji = emoji
        self.colorHex = colorHex
        self.imageFile = imageFile
    }
}

// MARK: - GitHub remote parsing

public enum GitHubRemote {
    /// Extracts "owner/repo" from https or ssh GitHub remotes.
    public static func slug(from remote: String?) -> String? {
        guard var s = remote?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let prefixes = ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/"]
        for p in prefixes where s.hasPrefix(p) {
            let rest = String(s.dropFirst(p.count))
            let parts = rest.split(separator: "/")
            guard parts.count >= 2 else { return nil }
            return "\(parts[0])/\(parts[1])"
        }
        return nil
    }
}
