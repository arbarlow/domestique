import DQCore
import Foundation
import ServerKit

struct CommandOutput {
    var status: Int32
    var stdout: String
    var stderr: String
    var succeeded: Bool { status == 0 }
}

struct PullRequestInfo: Decodable {
    struct Check: Decodable {
        var status: String?
        var conclusion: String?
        var state: String?

        var isFailing: Bool {
            ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"]
                .contains(conclusion ?? state ?? "")
        }
        var isPending: Bool {
            if let status { return status != "COMPLETED" }
            return state == "PENDING" || state == "EXPECTED"
        }
    }
    struct AutoMerge: Decodable {}

    var number: Int
    var url: String
    var title: String
    var state: String
    var mergeable: String?
    var mergeStateStatus: String?
    var reviewDecision: String?
    var statusCheckRollup: [Check]?
    var autoMergeRequest: AutoMerge?

    var checks: [Check] { statusCheckRollup ?? [] }
    var isOpen: Bool { state == "OPEN" }
    var isMerged: Bool { state == "MERGED" }
}

/// What a workspace's branch has that hasn't shipped.
struct BranchState {
    var uncommitted: Int
    /// Commits not on the remote default branch.
    var ahead: Int
    /// Commits not on the branch's upstream; nil when it has never been pushed.
    var unpushed: Int?

    var hasWork: Bool { uncommitted > 0 || ahead > 0 }
    var hasUnpushed: Bool { uncommitted > 0 || unpushed != 0 }
}

enum MergeMethod: String, CaseIterable, Identifiable {
    case squash, merge, rebase
    var id: String { rawValue }
    var title: String {
        switch self {
        case .squash: "Squash and merge"
        case .merge: "Create a merge commit"
        case .rebase: "Rebase and merge"
        }
    }
}

/// Commands run in a workspace on the server, in a login shell so the server user's PATH applies.
extension ServerConnection {
    func run(in workspaceID: String, _ script: String) async throws -> CommandOutput {
        var target = Proto_ProcessTarget()
        target.workspaceID = workspaceID
        target.argv = ["bash", "-lc", script]
        let sub = try await ready().subscribeProcess(target)
        defer { sub.cancel() }
        var out = Data()
        var err = Data()
        for await event in sub.events {
            switch event.payload {
            case .processOutput(let o):
                if o.stream == .stderr { err.append(o.data) } else { out.append(o.data) }
            case .processExited(let x):
                if !x.error.isEmpty { throw ServerError(code: .unavailable, message: x.error) }
                return CommandOutput(
                    status: x.exitCode, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
            default: break
            }
        }
        throw ServerError(code: .unavailable, message: "Lost the connection to \(name)")
    }

    /// Runs `script`; a non-zero exit throws with what it printed.
    @discardableResult
    func runChecked(in workspaceID: String, _ script: String) async throws -> CommandOutput {
        let r = try await run(in: workspaceID, script)
        guard r.succeeded else {
            let text = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerError(code: .failedPrecondition, message: text.isEmpty ? "The command failed (\(r.status))" : text)
        }
        return r
    }

    /// The workspace's `domestique.toml`, or nil when it has none.
    func repoConfig(of workspaceID: String) async throws -> RepoConfig? {
        let r = try await run(in: workspaceID, "cat \(RepoConfig.fileName)")
        return r.succeeded ? try RepoConfig.parse(toml: r.stdout) : nil
    }

    func defaultBranch(of ws: Proto_Workspace) -> String {
        let branch = repositories[ws.repositoryID]?.defaultBranch ?? ""
        if !branch.isEmpty { return branch }
        return ws.baseBranch.isEmpty ? "main" : ws.baseBranch
    }

    /// The branch's pull request (open, merged or closed), or nil if none was ever opened.
    func pullRequest(of workspaceID: String) async throws -> PullRequestInfo? {
        let fields = "number,url,title,state,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,autoMergeRequest"
        let r = try await run(in: workspaceID, "gh pr view --json \(fields)")
        if !r.succeeded {
            if r.stderr.localizedCaseInsensitiveContains("no pull requests found") { return nil }
            throw ServerError(code: .failedPrecondition, message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try JSONDecoder().decode(PullRequestInfo.self, from: Data(r.stdout.utf8))
    }

    func branchState(of workspaceID: String, base: String) async throws -> BranchState {
        let origin = ShellQuote.quote("origin/\(base)..HEAD")
        let r = try await runChecked(
            in: workspaceID,
            "git status --porcelain | wc -l; git rev-list --count \(origin) 2>/dev/null || echo 0; git rev-list --count '@{u}..HEAD' 2>/dev/null || echo none")
        let lines = r.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3 else { throw ServerError(code: .internal, message: "Couldn't read the branch state") }
        return BranchState(uncommitted: Int(lines[lines.count - 3]) ?? 0, ahead: Int(lines[lines.count - 2]) ?? 0, unpushed: Int(lines[lines.count - 1]))
    }

    /// `gh pr create` reads its default base from this key, so an agent omitting `--base` targets the right branch.
    func recordMergeBase(_ ws: Proto_Workspace) async {
        let key = "branch.\(ws.branch).gh-merge-base"
        _ = try? await run(in: ws.id, ShellQuote.join(["git", "config", key, defaultBranch(of: ws)]))
    }
}
