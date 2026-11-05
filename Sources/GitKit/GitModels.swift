import DQCore
import Foundation

public struct RepoInfo: Sendable, Hashable {
    public var root: String
    public var remoteURL: String?
    public var defaultBranch: String

    public init(root: String, remoteURL: String?, defaultBranch: String) {
        self.root = root
        self.remoteURL = remoteURL
        self.defaultBranch = defaultBranch
    }
}

public struct FileStatus: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case added, modified, deleted, renamed, untracked, conflicted
    }

    public var id: String { path }
    public var path: String
    public var origPath: String?
    public var kind: Kind
    /// True when the change is (at least partly) in the index.
    public var staged: Bool

    public init(path: String, origPath: String? = nil, kind: Kind, staged: Bool) {
        self.path = path
        self.origPath = origPath
        self.kind = kind
        self.staged = staged
    }
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case context, added, removed, noNewline }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    public init(kind: Kind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

public struct DiffHunk: Sendable, Hashable {
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, oldCount: Int = 0, newStart: Int, newCount: Int = 0, lines: [DiffLine] = []) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct FileDiff: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var oldPath: String?
    public var status: FileStatus.Kind
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    /// File was skipped because it is larger than the diff size limit.
    public var isTooLarge: Bool
    public var hunks: [DiffHunk]

    public init(
        path: String, oldPath: String? = nil, status: FileStatus.Kind, additions: Int = 0, deletions: Int = 0,
        isBinary: Bool = false, isTooLarge: Bool = false, hunks: [DiffHunk] = []
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isTooLarge = isTooLarge
        self.hunks = hunks
    }
}

public struct DiffStat: Sendable, Hashable {
    public var files: Int
    public var additions: Int
    public var deletions: Int

    public init(files: Int = 0, additions: Int = 0, deletions: Int = 0) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }
}

public struct AheadBehind: Sendable, Hashable {
    public var ahead: Int
    public var behind: Int
    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

public struct Commit: Sendable, Hashable, Identifiable {
    public var id: String { sha }
    public var sha: String
    public var subject: String
    public var body: String
    public var author: String
    public var date: Date

    public init(sha: String, subject: String, body: String, author: String, date: Date) {
        self.sha = sha
        self.subject = subject
        self.body = body
        self.author = author
        self.date = date
    }
}

public enum TrunkShipResult: Sendable, Hashable {
    /// Pushed to origin/<default>; sha is the new tip.
    case pushed(sha: String)
    /// Rebase hit conflicts (rebase was aborted, worktree is back where it started).
    case conflict(files: [String])
    /// HEAD already equals origin/<default>.
    case nothingToShip
}

public struct GitError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public init(command: String, result: ShellResult) {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = "`\(command)` failed (\(result.status)): \(err.isEmpty ? out : err)"
    }
    public var errorDescription: String? { message }
}
