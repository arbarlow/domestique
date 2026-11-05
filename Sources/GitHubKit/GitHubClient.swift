import DQCore
import Foundation

/// GitHub REST + GraphQL over URLSession. Auth comes from `gh auth token` (or GITHUB_TOKEN / GH_TOKEN).
public actor GitHubClient {
    public static let shared = GitHubClient()

    private let restBase = URL(string: "https://api.github.com")!
    private let graphQLURL = URL(string: "https://api.github.com/graphql")!
    let session: URLSession
    private var cachedToken: String?

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Domestique",
        ]
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    // MARK: - Auth

    func token() async throws -> String {
        if let cachedToken { return cachedToken }
        if let r = try? await Shell.run("gh", ["auth", "token"], check: false), r.succeeded {
            let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                cachedToken = t
                return t
            }
        }
        let env = await LoginEnvironment.shared.environment().merging(ProcessInfo.processInfo.environment) { a, _ in a }
        for key in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let t = env[key], !t.isEmpty {
                cachedToken = t
                return t
            }
        }
        throw GitHubError(message: "Not signed in. Run `gh auth login` or set GITHUB_TOKEN.")
    }

    /// Forget the cached token (e.g. after `gh auth login`).
    public func resetToken() { cachedToken = nil }

    // MARK: - Transport

    private func send(_ makeRequest: (String) -> URLRequest, retryOn401: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let tok = try await token()
        let (data, response) = try await session.data(for: makeRequest(tok))
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError(message: "Unexpected response")
        }
        if http.statusCode == 401, retryOn401 {
            cachedToken = nil
            return try await send(makeRequest, retryOn401: false)
        }
        return (data, http)
    }

    private func rest(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil,
        okStatuses: Set<Int> = Set(200..<300)
    ) async throws -> JSONValue {
        var comps = URLComponents(url: restBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        let url = comps.url!
        let (data, http) = try await send { tok in
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = body.encoded()
            }
            return req
        }
        guard okStatuses.contains(http.statusCode) else {
            throw Self.error(from: data, status: http.statusCode)
        }
        if data.isEmpty { return .null }
        return (try? JSONValue.parse(data)) ?? .null
    }

    private func graphQL(_ query: String, variables: JSONValue) async throws -> JSONValue {
        let body: JSONValue = ["query": .string(query), "variables": variables]
        let url = graphQLURL
        let (data, http) = try await send { tok in
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.encoded()
            return req
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(from: data, status: http.statusCode)
        }
        let json = try JSONValue.parse(data)
        try Self.throwIfGraphQLErrors(json)
        return json
    }

    static func error(from data: Data, status: Int) -> GitHubError {
        if let json = try? JSONValue.parse(data) {
            var msg = json["message"]?.string ?? "Request failed"
            if let errors = json["errors"]?.array {
                let details = errors.compactMap { $0["message"]?.string ?? $0["code"]?.string }
                if !details.isEmpty { msg += ": " + details.joined(separator: "; ") }
            }
            return GitHubError(statusCode: status, message: msg)
        }
        return GitHubError(statusCode: status, message: String(decoding: data.prefix(500), as: UTF8.self))
    }

    static func throwIfGraphQLErrors(_ json: JSONValue) throws {
        if let errors = json["errors"]?.array, !errors.isEmpty {
            let msg = errors.compactMap { $0["message"]?.string }.joined(separator: "; ")
            throw GitHubError(message: msg.isEmpty ? "GraphQL error" : msg)
        }
    }

    // MARK: - Pull requests

    public func createPullRequest(slug: String, head: String, base: String, title: String, body: String, draft: Bool)
        async throws -> PullRequest
    {
        let json = try await rest(
            "POST", "repos/\(slug)/pulls",
            body: ["title": .string(title), "head": .string(head), "base": .string(base), "body": .string(body),
                   "draft": .bool(draft)])
        guard let pr = Self.pullRequest(fromREST: json) else {
            throw GitHubError(message: "Couldn't read the created pull request.")
        }
        return pr
    }

    /// Most recent PR (any state) whose head is `branch` in the same repo.
    public func findOpenPullRequest(slug: String, branch: String) async throws -> PullRequest? {
        let owner = slug.split(separator: "/").first.map(String.init) ?? slug
        let json = try await rest(
            "GET", "repos/\(slug)/pulls",
            query: [
                URLQueryItem(name: "head", value: "\(owner):\(branch)"),
                URLQueryItem(name: "state", value: "all"),
                URLQueryItem(name: "sort", value: "created"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "per_page", value: "10"),
            ])
        let prs = (json.array ?? []).compactMap(Self.pullRequest(fromREST:))
        return prs.max { $0.number < $1.number }
    }

    static func pullRequest(fromREST json: JSONValue) -> PullRequest? {
        guard let number = json["number"]?.int, let url = json["html_url"]?.string else { return nil }
        let merged = json["merged_at"].map { !$0.isNull } ?? false
        let state: PRState = merged ? .merged : (json["state"]?.string == "open" ? .open : .closed)
        return PullRequest(
            number: number, url: url, title: json["title"]?.string ?? "", state: state,
            isDraft: json["draft"]?.bool ?? false, headRefName: json["head"]?["ref"]?.string ?? "",
            baseRefName: json["base"]?["ref"]?.string ?? "", nodeID: json["node_id"]?.string ?? "")
    }

    static let openPullRequestsQuery = """
        query($owner: String!, $name: String!, $first: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: OPEN, first: $first, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title url isDraft headRefName createdAt updatedAt additions deletions reviewDecision
                author { login avatarUrl }
                comments { totalCount }
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              }
            }
          }
        }
        """

    /// Open PRs, most recently updated first.
    public func openPullRequests(slug: String, first: Int = 30) async throws -> [PullRequestSummary] {
        let parts = slug.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw GitHubError(message: "Bad repo slug \(slug)") }
        let json = try await graphQL(
            Self.openPullRequestsQuery,
            variables: ["owner": .string(parts[0]), "name": .string(parts[1]), "first": .number(Double(first))])
        let nodes = json["data"]?["repository"]?["pullRequests"]?["nodes"]?.array ?? []
        return nodes.compactMap(Self.pullRequestSummary(from:))
    }

    static func pullRequestSummary(from n: JSONValue) -> PullRequestSummary? {
        guard let number = n["number"]?.int, let url = n["url"]?.string else { return nil }
        let iso = ISO8601DateFormatter()
        let rollup = n["commits"]?["nodes"]?.array?.first?["commit"]?["statusCheckRollup"]?["state"]?.string
        let checks: ChecksOverall =
            switch rollup {
            case "SUCCESS": .passing
            case "FAILURE", "ERROR": .failing
            case "PENDING", "EXPECTED": .pending
            default: .none
            }
        return PullRequestSummary(
            number: number, title: n["title"]?.string ?? "", url: url, isDraft: n["isDraft"]?.bool ?? false,
            headRefName: n["headRefName"]?.string ?? "", authorLogin: n["author"]?["login"]?.string,
            authorAvatarURL: n["author"]?["avatarUrl"]?.string,
            createdAt: n["createdAt"]?.string.flatMap { iso.date(from: $0) },
            updatedAt: n["updatedAt"]?.string.flatMap { iso.date(from: $0) },
            additions: n["additions"]?.int ?? 0, deletions: n["deletions"]?.int ?? 0,
            comments: n["comments"]?["totalCount"]?.int ?? 0, reviewDecision: n["reviewDecision"]?.string,
            checks: checks)
    }

    // MARK: - Status

    static let statusQuery = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              id number url title state isDraft headRefName baseRefName
              mergeable mergeStateStatus reviewDecision
              autoMergeRequest { enabledAt mergeMethod }
              commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 100) { nodes {
                __typename
                ... on CheckRun { name status conclusion detailsUrl databaseId
                  checkSuite { app { slug } workflowRun { databaseId workflow { name } } } }
                ... on StatusContext { context state targetUrl }
              } } } } } }
            }
          }
        }
        """

    public func status(slug: String, number: Int) async throws -> PullRequestStatus {
        let parts = slug.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw GitHubError(message: "Bad repo slug \(slug)") }
        let json = try await graphQL(
            Self.statusQuery,
            variables: ["owner": .string(parts[0]), "name": .string(parts[1]), "number": .number(Double(number))])
        return try Self.decodeStatus(json)
    }

    /// Decodes the raw GraphQL response body of `statusQuery`.
    public static func decodeStatus(from data: Data) throws -> PullRequestStatus {
        let json = try JSONValue.parse(data)
        try throwIfGraphQLErrors(json)
        return try decodeStatus(json)
    }

    static func decodeStatus(_ json: JSONValue) throws -> PullRequestStatus {
        guard let pr = json["data"]?["repository"]?["pullRequest"], pr.object != nil else {
            throw GitHubError(message: "Pull request not found")
        }
        let state: PRState =
            switch pr["state"]?.string {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: .open
            }
        let pull = PullRequest(
            number: pr["number"]?.int ?? 0, url: pr["url"]?.string ?? "", title: pr["title"]?.string ?? "",
            state: state, isDraft: pr["isDraft"]?.bool ?? false, headRefName: pr["headRefName"]?.string ?? "",
            baseRefName: pr["baseRefName"]?.string ?? "", nodeID: pr["id"]?.string ?? "")
        let mergeable: Mergeable =
            switch pr["mergeable"]?.string {
            case "MERGEABLE": .mergeable
            case "CONFLICTING": .conflicting
            default: .unknown
            }
        let autoMerge = pr["autoMergeRequest"]
        let commit = pr["commits"]?["nodes"]?[0]?["commit"]
        let contexts = commit?["statusCheckRollup"]?["contexts"]?["nodes"]?.array ?? []

        var checks: [CheckRun] = []
        var seen = Set<String>()
        for node in contexts {
            guard let check = checkRun(from: node), !seen.contains(check.id) else { continue }
            seen.insert(check.id)
            checks.append(check)
        }

        return PullRequestStatus(
            pr: pull, mergeable: mergeable, mergeStateStatus: pr["mergeStateStatus"]?.string ?? "UNKNOWN",
            reviewDecision: pr["reviewDecision"]?.string,
            autoMergeEnabled: autoMerge.map { $0.object != nil } ?? false,
            autoMergeMethod: autoMerge?["mergeMethod"]?.string, checks: checks, headSHA: commit?["oid"]?.string)
    }

    static func checkRun(from node: JSONValue) -> CheckRun? {
        switch node["__typename"]?.string {
        case "CheckRun":
            guard let name = node["name"]?.string else { return nil }
            let status: CheckRun.Status =
                switch node["status"]?.string {
                case "COMPLETED": .completed
                case "IN_PROGRESS": .inProgress
                case "QUEUED": .queued
                default: .pending  // WAITING, PENDING, REQUESTED
                }
            let suite = node["checkSuite"]
            let app = suite?["app"]?["slug"]?.string ?? "check"
            let workflow = suite?["workflowRun"]?["workflow"]?["name"]?.string
            let runID = suite?["workflowRun"]?["databaseId"]?.int
            let isActions = app == "github-actions" || runID != nil
            let displayName = workflow.map { "\($0) / \(name)" } ?? name
            return CheckRun(
                id: "check:\(app):\(workflow ?? ""):\(name)", name: displayName, status: status,
                conclusion: node["conclusion"]?.string?.lowercased(),
                detailsURL: node["detailsUrl"]?.string.flatMap(URL.init(string:)),
                jobID: isActions ? node["databaseId"]?.int : nil, workflowRunID: runID)
        case "StatusContext":
            guard let context = node["context"]?.string else { return nil }
            let state = node["state"]?.string ?? "PENDING"
            let done = state != "PENDING" && state != "EXPECTED"
            return CheckRun(
                id: "status:\(context)", name: context, status: done ? .completed : .pending,
                conclusion: done ? state.lowercased() : nil,
                detailsURL: node["targetUrl"]?.string.flatMap(URL.init(string:)), jobID: nil)
        default:
            return nil
        }
    }

    // MARK: - Merge

    public func merge(slug: String, number: Int, method: MergeMethod) async throws {
        _ = try await rest("PUT", "repos/\(slug)/pulls/\(number)/merge", body: ["merge_method": .string(method.rawValue)])
    }

    /// GitHub's "Update branch": merges the base into the PR branch on GitHub's side.
    public func updateBranch(slug: String, number: Int) async throws {
        _ = try await rest("PUT", "repos/\(slug)/pulls/\(number)/update-branch", body: [:])
    }

    public func enableAutoMerge(prNodeID: String, method: MergeMethod) async throws {
        _ = try await graphQL(
            """
            mutation($id: ID!, $method: PullRequestMergeMethod!) {
              enablePullRequestAutoMerge(input: { pullRequestId: $id, mergeMethod: $method }) { clientMutationId }
            }
            """, variables: ["id": .string(prNodeID), "method": .string(method.graphQLValue)])
    }

    public func disableAutoMerge(prNodeID: String) async throws {
        _ = try await graphQL(
            """
            mutation($id: ID!) {
              disablePullRequestAutoMerge(input: { pullRequestId: $id }) { clientMutationId }
            }
            """, variables: ["id": .string(prNodeID)])
    }

    // MARK: - Logs

    /// Tail of the logs for each failing check, ready to hand to an agent.
    public func failedCheckLogs(slug: String, status: PullRequestStatus, maxBytesPerJob: Int = 20_000) async throws
        -> String
    {
        var sections: [String] = []
        for check in status.failingChecks {
            var section = "## \(check.name) — \(check.conclusion ?? "failed")\n"
            if let url = check.detailsURL { section += "\(url.absoluteString)\n" }
            if let jobID = check.jobID {
                do {
                    let log = try await jobLog(slug: slug, jobID: jobID)
                    let cleaned = Self.cleanLog(log)
                    let tail = Self.tail(cleaned, maxBytes: maxBytesPerJob)
                    section += "\n```\n\(tail)\n```\n"
                } catch {
                    section += "\n(Couldn't fetch logs: \(error.localizedDescription))\n"
                }
            } else {
                section += "\n(Not a GitHub Actions check; see the link above.)\n"
            }
            sections.append(section)
        }
        if sections.isEmpty { return "No failing checks." }
        return sections.joined(separator: "\n")
    }

    func jobLog(slug: String, jobID: Int) async throws -> String {
        let url = restBase.appendingPathComponent("repos/\(slug)/actions/jobs/\(jobID)/logs")
        let (data, http) = try await send { tok in
            var req = URLRequest(url: url)
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            return req
        }
        if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
            let target = URL(string: location)
        {
            // Pre-signed blob URL: must NOT carry our Authorization header.
            var req = URLRequest(url: target)
            req.setValue(nil, forHTTPHeaderField: "Authorization")
            let (blob, resp) = try await URLSession.shared.data(for: req)
            if let r = resp as? HTTPURLResponse, !(200..<300).contains(r.statusCode) {
                throw GitHubError(statusCode: r.statusCode, message: "Log download failed")
            }
            return String(decoding: blob, as: UTF8.self)
        }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Strips Actions timestamps and ANSI escapes.
    static func cleanLog(_ log: String) -> String {
        var out: [Substring] = []
        for var line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasSuffix("\r") { line = line.dropLast() }
            // 2024-01-01T00:00:00.0000000Z <text>
            if line.count > 29, line.dropFirst(4).first == "-", line.dropFirst(10).first == "T",
                let space = line.firstIndex(of: " "), line[..<space].hasSuffix("Z")
            {
                line = line[line.index(after: space)...]
            }
            out.append(line)
        }
        let joined = out.joined(separator: "\n")
        return joined.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    static func tail(_ s: String, maxBytes: Int) -> String {
        let bytes = Array(s.utf8)
        guard bytes.count > maxBytes else { return s }
        var start = bytes.count - maxBytes
        // Don't start mid-UTF8 sequence.
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        var text = String(decoding: bytes[start...], as: UTF8.self)
        if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return "…(truncated)\n" + text
    }

    // MARK: - Repositories

    /// Repos the user owns, collaborates on, or can see through an org, most recently pushed first.
    public func listRepositories(maxPages: Int = 5) async throws -> [GitHubRepo] {
        var all: [GitHubRepo] = []
        for page in 1...maxPages {
            let json = try await rest(
                "GET", "user/repos",
                query: [
                    URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
                    URLQueryItem(name: "sort", value: "pushed"),
                    URLQueryItem(name: "direction", value: "desc"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: "\(page)"),
                ])
            let items = json.array ?? []
            all += items.compactMap(Self.repo(fromREST:))
            if items.count < 100 { break }
        }
        return all
    }

    static func repo(fromREST json: JSONValue) -> GitHubRepo? {
        guard let id = json["id"]?.int, let fullName = json["full_name"]?.string, let name = json["name"]?.string,
            let cloneURL = json["clone_url"]?.string
        else { return nil }
        let pushed = json["pushed_at"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) }
        return GitHubRepo(
            id: id, fullName: fullName, name: name, owner: json["owner"]?["login"]?.string ?? "",
            description: json["description"]?.string, isPrivate: json["private"]?.bool ?? false,
            isFork: json["fork"]?.bool ?? false, isArchived: json["archived"]?.bool ?? false,
            defaultBranch: json["default_branch"]?.string ?? "main", cloneURL: cloneURL,
            sshURL: json["ssh_url"]?.string ?? cloneURL, htmlURL: json["html_url"]?.string ?? "", pushedAt: pushed)
    }

    // MARK: - User

    public func currentUserLogin() async throws -> String {
        let json = try await rest("GET", "user")
        guard let login = json["login"]?.string else { throw GitHubError(message: "No login in /user response") }
        return login
    }
}

/// Lets us handle redirects ourselves (so auth headers never leak to pre-signed blob URLs).
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
