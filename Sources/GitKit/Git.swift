import DQCore
import Foundation

/// Thin async wrapper over the system `git`. Everything shells out so worktrees, credentials,
/// hooks and config behave exactly like the user's terminal.
public enum Git {
    /// Diffs larger than this many changed lines are collapsed (isTooLarge).
    public static let maxDiffLinesPerFile = 10_000
    /// Untracked files larger than this are not read.
    public static let maxUntrackedFileBytes = 1_000_000

    private static let quietEnv: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_EDITOR": "true",
        "GIT_SEQUENCE_EDITOR": "true",
        "GIT_MERGE_AUTOEDIT": "no",
        "LC_ALL": "C",
    ]

    @discardableResult
    static func git(_ args: [String], cwd: String, check: Bool = true, env: [String: String] = [:]) async throws
        -> ShellResult
    {
        try await Shell.run(
            "git", ["-c", "core.quotePath=false", "-c", "color.ui=false"] + args, cwd: cwd,
            env: quietEnv.merging(env) { $1 }, check: check)
    }

    static func output(_ args: [String], cwd: String) async throws -> String {
        try await git(args, cwd: cwd).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Repo info

    public static func repoInfo(path: String) async throws -> RepoInfo {
        let root = try await output(["rev-parse", "--show-toplevel"], cwd: path)
        let remoteResult = try await git(["remote", "get-url", "origin"], cwd: root, check: false)
        let remote = remoteResult.succeeded ? remoteResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let branch = try await defaultBranch(root: root, hasRemote: remote != nil)
        return RepoInfo(root: root, remoteURL: remote, defaultBranch: branch)
    }

    static func defaultBranch(root: String, hasRemote: Bool) async throws -> String {
        let sym = try await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: root, check: false)
        if sym.succeeded {
            let name = sym.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("origin/") { return String(name.dropFirst("origin/".count)) }
            if !name.isEmpty { return name }
        }
        if hasRemote {
            let ls = try await git(["ls-remote", "--symref", "origin", "HEAD"], cwd: root, check: false)
            if ls.succeeded {
                for line in ls.stdout.split(separator: "\n") where line.hasPrefix("ref: refs/heads/") {
                    let rest = line.dropFirst("ref: refs/heads/".count)
                    if let tab = rest.firstIndex(where: { $0 == "\t" || $0 == " " }) {
                        return String(rest[..<tab])
                    }
                }
            }
        }
        for candidate in ["main", "master"] {
            let r = try await git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"], cwd: root, check: false)
            if r.succeeded { return candidate }
        }
        for candidate in ["main", "master"] {
            let r = try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], cwd: root, check: false)
            if r.succeeded { return candidate }
        }
        return "main"
    }

    public static func currentHead(path: String) async throws -> String {
        try await output(["rev-parse", "HEAD"], cwd: path)
    }

    public static func currentBranch(path: String) async throws -> String {
        try await output(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path)
    }

    // MARK: - Clone

    /// Clones `url` into `path` (which must not exist yet). Prefers `gh repo clone` when `gh` is installed,
    /// so the user's preferred protocol and credentials apply; falls back to plain `git clone`.
    public static func clone(slug: String?, url: String, to path: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if let slug, (try? await LoginEnvironment.shared.resolve("gh")) != nil {
            try await Shell.run("gh", ["repo", "clone", slug, path], cwd: parent, env: quietEnv)
        } else {
            try await git(["clone", url, path], cwd: parent)
        }
    }

    // MARK: - Fetch / worktrees

    public static func fetch(repoPath: String, branch: String) async throws {
        try await git(["fetch", "origin", branch, "--prune"], cwd: repoPath)
    }

    /// Creates `path` as a new worktree on a new `branch` starting at `base` (e.g. "origin/main").
    /// Returns the base commit sha.
    @discardableResult
    public static func createWorktree(repoPath: String, path: String, branch: String, base: String) async throws
        -> String
    {
        let exists = try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], cwd: repoPath, check: false)
        if exists.succeeded {
            throw GitError("A branch named \(branch) already exists in \(repoPath).")
        }
        if FileManager.default.fileExists(atPath: path) {
            throw GitError("\(path) already exists.")
        }
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let sha = try await output(["rev-parse", "\(base)^{commit}"], cwd: repoPath)
        try await git(["worktree", "add", "--no-track", "-b", branch, path, sha], cwd: repoPath)
        return sha
    }

    public static func removeWorktree(repoPath: String, path: String, force: Bool) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)
        let r = try await git(args, cwd: repoPath, check: false)
        if !r.succeeded && FileManager.default.fileExists(atPath: path) {
            throw GitError(command: "git " + args.joined(separator: " "), result: r)
        }
        try await git(["worktree", "prune"], cwd: repoPath, check: false)
    }

    public static func deleteBranch(repoPath: String, branch: String) async throws {
        try await git(["branch", "-D", branch], cwd: repoPath)
    }

    // MARK: - Status

    public static func status(path: String) async throws -> [FileStatus] {
        let out = try await git(["status", "--porcelain=v2", "-z", "--untracked-files=all"], cwd: path).stdout
        return parsePorcelainV2(out)
    }

    static func parsePorcelainV2(_ out: String) -> [FileStatus] {
        var result: [FileStatus] = []
        let fields = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        func kind(_ c: Character) -> FileStatus.Kind? {
            switch c {
            case "A", "C": .added
            case "M", "T": .modified
            case "D": .deleted
            case "R": .renamed
            case "U": .conflicted
            default: nil
            }
        }
        while i < fields.count {
            let entry = fields[i]
            i += 1
            guard let type = entry.first else { continue }
            switch type {
            case "1", "2":
                let parts = entry.split(separator: " ", maxSplits: type == "1" ? 8 : 9, omittingEmptySubsequences: false)
                guard parts.count >= (type == "1" ? 9 : 10) else { continue }
                let xy = Array(parts[1])
                let x = xy.count > 0 ? xy[0] : "."
                let y = xy.count > 1 ? xy[1] : "."
                let path = String(parts[type == "1" ? 8 : 9])
                var orig: String?
                if type == "2", i < fields.count {
                    orig = fields[i]
                    i += 1
                }
                let k = (x != "." ? kind(x) : nil) ?? kind(y) ?? .modified
                result.append(FileStatus(path: path, origPath: orig, kind: k, staged: x != "."))
            case "u":
                let parts = entry.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count >= 11 else { continue }
                result.append(FileStatus(path: String(parts[10]), kind: .conflicted, staged: false))
            case "?":
                result.append(FileStatus(path: String(entry.dropFirst(2)), kind: .untracked, staged: false))
            default:
                continue
            }
        }
        return result
    }

    public static func hasUncommittedChanges(path: String) async throws -> Bool {
        let out = try await git(["status", "--porcelain", "-z", "--untracked-files=normal"], cwd: path).stdout
        return !out.isEmpty
    }

    // MARK: - Diff

    /// Working tree (committed + staged + unstaged + untracked) vs merge-base(HEAD, base).
    public static func diff(path: String, base: String) async throws -> [FileDiff] {
        let mb = try await git(["merge-base", "HEAD", base], cwd: path, check: false)
        let from = mb.succeeded ? mb.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : base
        let out = try await git(
            ["diff", "--no-color", "--no-ext-diff", "-M", "--src-prefix=a/", "--dst-prefix=b/", from], cwd: path
        ).stdout
        var files = UnifiedDiffParser.parse(out).map(collapseIfHuge)

        let untrackedOut = try await git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: path).stdout
        let untracked = untrackedOut.split(separator: "\0").map(String.init)
        let tracked = Set(files.map(\.path))
        for rel in untracked where !tracked.contains(rel) {
            files.append(untrackedDiff(root: path, relativePath: rel))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func collapseIfHuge(_ f: FileDiff) -> FileDiff {
        guard f.additions + f.deletions > maxDiffLinesPerFile else { return f }
        var copy = f
        copy.hunks = []
        copy.isTooLarge = true
        return copy
    }

    static func untrackedDiff(root: String, relativePath: String) -> FileDiff {
        let full = (root as NSString).appendingPathComponent(relativePath)
        let attrs = try? FileManager.default.attributesOfItem(atPath: full)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxUntrackedFileBytes {
            return FileDiff(path: relativePath, status: .added, isTooLarge: true)
        }
        guard let data = FileManager.default.contents(atPath: full) else {
            return FileDiff(path: relativePath, status: .added)
        }
        if data.prefix(8000).contains(0) {
            return FileDiff(path: relativePath, status: .added, isBinary: true)
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.isEmpty { return FileDiff(path: relativePath, status: .added) }
        var lines = text.components(separatedBy: "\n")
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        var diffLines: [DiffLine] = lines.enumerated().map { idx, l in
            DiffLine(kind: .added, text: l.hasSuffix("\r") ? String(l.dropLast()) : l, oldLine: nil, newLine: idx + 1)
        }
        if !endsWithNewline { diffLines.append(DiffLine(kind: .noNewline, text: "No newline at end of file")) }
        let hunk = DiffHunk(
            header: "@@ -0,0 +1,\(lines.count) @@", oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count,
            lines: diffLines)
        return collapseIfHuge(FileDiff(path: relativePath, status: .added, additions: lines.count, hunks: [hunk]))
    }

    public static func diffStat(_ files: [FileDiff]) -> DiffStat {
        DiffStat(
            files: files.count, additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions })
    }

    public static func aheadBehind(path: String, base: String) async throws -> AheadBehind {
        let out = try await output(["rev-list", "--left-right", "--count", "\(base)...HEAD"], cwd: path)
        let parts = out.split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            return AheadBehind(ahead: 0, behind: 0)
        }
        return AheadBehind(ahead: ahead, behind: behind)
    }

    // MARK: - Commit / push

    /// Stages everything and commits. Returns false when there was nothing to commit.
    @discardableResult
    public static func commitAll(path: String, message: String) async throws -> Bool {
        try await git(["add", "-A"], cwd: path)
        let staged = try await git(["diff", "--cached", "--quiet"], cwd: path, check: false)
        if staged.status == 0 { return false }
        try await git(["commit", "-q", "-F", "-"], cwd: path, stdin: message)
        return true
    }

    public static func push(path: String, branch: String, setUpstream: Bool, force: Bool = false) async throws {
        var args = ["push"]
        if setUpstream { args.append("-u") }
        if force { args.append("--force-with-lease") }
        args += ["origin", "HEAD:refs/heads/\(branch)"]
        try await git(args, cwd: path)
    }

    // MARK: - Log

    public static func log(path: String, range: String, limit: Int = 100) async throws -> [Commit] {
        let fmt = "%H%x1f%an%x1f%aI%x1f%s%x1f%b%x1e"
        let r = try await git(["log", "--format=\(fmt)", "-n", String(limit), range], cwd: path, check: false)
        guard r.succeeded else { return [] }
        let iso = ISO8601DateFormatter()
        return r.stdout.split(separator: "\u{1e}").compactMap { rec in
            let fields = rec.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 5 else { return nil }
            return Commit(
                sha: String(fields[0]), subject: String(fields[3]),
                body: String(fields[4]).trimmingCharacters(in: .whitespacesAndNewlines), author: String(fields[1]),
                date: iso.date(from: String(fields[2])) ?? .distantPast)
        }
    }

    // MARK: - Trunk

    /// Rebases the current branch onto origin/<defaultBranch> and fast-forward pushes HEAD to it.
    /// Retries when someone else pushed in between. Uncommitted changes must be committed first.
    public static func trunkShip(path: String, defaultBranch: String, maxAttempts: Int = 3) async throws
        -> TrunkShipResult
    {
        if try await hasUncommittedChanges(path: path) {
            throw GitError("Commit your changes before shipping to \(defaultBranch).")
        }
        let remoteRef = "origin/\(defaultBranch)"
        for _ in 0..<max(1, maxAttempts) {
            try await fetch(repoPath: path, branch: defaultBranch)
            let head = try await currentHead(path: path)
            let remote = try await output(["rev-parse", remoteRef], cwd: path)
            if head == remote { return .nothingToShip }
            let isAncestor = try await git(["merge-base", "--is-ancestor", "HEAD", remoteRef], cwd: path, check: false)
            if isAncestor.succeeded { return .nothingToShip }

            let rebase = try await git(["rebase", remoteRef], cwd: path, check: false)
            if !rebase.succeeded {
                let conflicted = try await git(["diff", "--name-only", "--diff-filter=U"], cwd: path, check: false)
                let files = conflicted.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                try await git(["rebase", "--abort"], cwd: path, check: false)
                if files.isEmpty {
                    throw GitError(command: "git rebase \(remoteRef)", result: rebase)
                }
                return .conflict(files: files)
            }

            let push = try await git(["push", "origin", "HEAD:refs/heads/\(defaultBranch)"], cwd: path, check: false)
            if push.succeeded {
                return .pushed(sha: try await currentHead(path: path))
            }
            let err = push.stderr.lowercased()
            if err.contains("non-fast-forward") || err.contains("fetch first") || err.contains("rejected") {
                continue
            }
            throw GitError(command: "git push origin HEAD:\(defaultBranch)", result: push)
        }
        throw GitError("\(remoteRef) kept moving; gave up after \(maxAttempts) attempts.")
    }

    // MARK: - Files

    public static func listFiles(path: String) async throws -> [String] {
        let out = try await git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd: path).stdout
        let files = Set(out.split(separator: "\0").map(String.init))
        // Files deleted in the working tree still show as cached; drop them.
        return files.filter { FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension Git {
    @discardableResult
    static func git(_ args: [String], cwd: String, stdin: String) async throws -> ShellResult {
        try await Shell.run(
            "git", ["-c", "core.quotePath=false", "-c", "color.ui=false"] + args, cwd: cwd, env: quietEnv,
            stdin: stdin, check: true)
    }
}
