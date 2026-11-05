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
