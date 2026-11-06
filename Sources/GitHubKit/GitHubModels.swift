import Foundation

public enum PRState: String, Codable, Sendable, Hashable {
    case open, closed, merged
}

public struct PullRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var url: String
    public var title: String
    public var state: PRState
    public var isDraft: Bool
    public var headRefName: String
    public var baseRefName: String
    /// GraphQL node id (needed for auto-merge mutations).
    public var nodeID: String

    public init(
        number: Int, url: String, title: String, state: PRState, isDraft: Bool, headRefName: String,
        baseRefName: String, nodeID: String
    ) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.nodeID = nodeID
    }
}

public enum Mergeable: String, Codable, Sendable, Hashable {
    case mergeable, conflicting, unknown
}

public enum ChecksOverall: String, Codable, Sendable, Hashable {
    /// No checks reported.
    case none
    case pending
    case passing
    case failing
}

public struct CheckRun: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case queued, inProgress, completed, pending
    }

    /// name + source, stable across polls.
    public var id: String
    public var name: String
    public var status: Status
    /// Lowercased GitHub conclusion/state: success, failure, neutral, cancelled, skipped, timed_out,
    /// action_required, startup_failure, stale, error (status contexts).
    public var conclusion: String?
    public var detailsURL: URL?
    /// GitHub Actions job id (CheckRun.databaseId) when the check is an Actions job.
    public var jobID: Int?
    /// Workflow run id when the check comes from GitHub Actions.
    public var workflowRunID: Int?

    public init(
        id: String, name: String, status: Status, conclusion: String?, detailsURL: URL?, jobID: Int?,
        workflowRunID: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.detailsURL = detailsURL
        self.jobID = jobID
        self.workflowRunID = workflowRunID
    }

    static let failingConclusions: Set<String> = [
        "failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale", "error",
    ]

    public var isFailing: Bool {
        guard status == .completed, let conclusion else { return false }
        return Self.failingConclusions.contains(conclusion)
    }

    public var isPending: Bool { status != .completed }

    public var isPassing: Bool { status == .completed && !isFailing }
}

public struct PullRequestStatus: Codable, Sendable, Hashable {
    public var pr: PullRequest
    public var mergeable: Mergeable
    /// GitHub mergeStateStatus: CLEAN, BLOCKED, BEHIND, DIRTY, UNSTABLE, HAS_HOOKS, DRAFT, UNKNOWN.
    public var mergeStateStatus: String
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil.
    public var reviewDecision: String?
    public var autoMergeEnabled: Bool
    public var autoMergeMethod: String?
    public var checks: [CheckRun]
    public var headSHA: String?

    public init(
        pr: PullRequest, mergeable: Mergeable, mergeStateStatus: String, reviewDecision: String?,
        autoMergeEnabled: Bool, autoMergeMethod: String? = nil, checks: [CheckRun], headSHA: String?
    ) {
        self.pr = pr
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.reviewDecision = reviewDecision
        self.autoMergeEnabled = autoMergeEnabled
        self.autoMergeMethod = autoMergeMethod
        self.checks = checks
        self.headSHA = headSHA
    }

    public var overall: ChecksOverall {
        if checks.isEmpty { return .none }
        if checks.contains(where: \.isFailing) { return .failing }
        if checks.contains(where: \.isPending) { return .pending }
        return .passing
    }

    public var failingChecks: [CheckRun] { checks.filter(\.isFailing) }
}

public enum MergeMethod: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case squash, merge, rebase

    public var id: String { rawValue }

    /// PullRequestMergeMethod enum value for GraphQL.
    public var graphQLValue: String {
        switch self {
        case .squash: "SQUASH"
        case .merge: "MERGE"
        case .rebase: "REBASE"
        }
    }

    public var displayName: String {
        switch self {
        case .squash: "Squash and merge"
        case .merge: "Merge commit"
        case .rebase: "Rebase and merge"
        }
    }
}

public struct GitHubError: Error, LocalizedError, Sendable {
    public var statusCode: Int?
    public var message: String

    public init(statusCode: Int? = nil, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? {
        if let statusCode { return "GitHub (\(statusCode)): \(message)" }
        return "GitHub: \(message)"
    }
}

/// A repository the signed-in user can access (for "Clone from GitHub").
public struct GitHubRepo: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// "owner/name"
    public var fullName: String
    public var name: String
    public var owner: String
    public var description: String?
    public var isPrivate: Bool
    public var isFork: Bool
    public var isArchived: Bool
    public var defaultBranch: String
    public var cloneURL: String
    public var sshURL: String
    public var htmlURL: String
    public var pushedAt: Date?

    public init(
        id: Int, fullName: String, name: String, owner: String, description: String?, isPrivate: Bool,
        isFork: Bool, isArchived: Bool, defaultBranch: String, cloneURL: String, sshURL: String, htmlURL: String,
        pushedAt: Date?
    ) {
        self.id = id
        self.fullName = fullName
        self.name = name
        self.owner = owner
        self.description = description
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.isArchived = isArchived
        self.defaultBranch = defaultBranch
        self.cloneURL = cloneURL
        self.sshURL = sshURL
        self.htmlURL = htmlURL
        self.pushedAt = pushedAt
    }
}

/// An open pull request as listed on a project's home page.
public struct PullRequestSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var title: String
    public var url: String
    public var isDraft: Bool
    public var headRefName: String
    /// The branch it merges into.
    public var baseRefName: String
    /// The head branch lives in a fork, so pushing to origin can't update it.
    public var isCrossRepository: Bool
    public var authorLogin: String?
    public var authorAvatarURL: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var additions: Int
    public var deletions: Int
    public var comments: Int
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil.
    public var reviewDecision: String?
    public var checks: ChecksOverall

    public init(
        number: Int, title: String, url: String, isDraft: Bool, headRefName: String, baseRefName: String = "",
        isCrossRepository: Bool = false, authorLogin: String?, authorAvatarURL: String?, createdAt: Date?,
        updatedAt: Date?, additions: Int, deletions: Int, comments: Int, reviewDecision: String?,
        checks: ChecksOverall
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.isCrossRepository = isCrossRepository
        self.authorLogin = authorLogin
        self.authorAvatarURL = authorAvatarURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.additions = additions
        self.deletions = deletions
        self.comments = comments
        self.reviewDecision = reviewDecision
        self.checks = checks
    }
}
