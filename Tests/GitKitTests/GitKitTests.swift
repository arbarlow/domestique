import DQCore
import Foundation
import Testing

@testable import GitKit

// MARK: - Parser

@Suite struct UnifiedDiffParserTests {
    @Test func modifiedFileWithLineNumbers() {
        let text = """
            diff --git a/src/app.swift b/src/app.swift
            index 1111111..2222222 100644
            --- a/src/app.swift
            +++ b/src/app.swift
            @@ -1,4 +1,5 @@ struct App {
             let a = 1
            -let b = 2
            +let b = 3
            +let c = 4
             let d = 5
             let e = 6

            """
        let files = UnifiedDiffParser.parse(text)
        #expect(files.count == 1)
        let f = files[0]
        #expect(f.path == "src/app.swift")
        #expect(f.status == .modified)
        #expect(f.additions == 2)
        #expect(f.deletions == 1)
        #expect(f.hunks.count == 1)
        let h = f.hunks[0]
        #expect(h.oldStart == 1 && h.oldCount == 4 && h.newStart == 1 && h.newCount == 5)
        #expect(h.lines.map(\.kind) == [.context, .removed, .added, .added, .context, .context])
        #expect(h.lines[1].oldLine == 2 && h.lines[1].newLine == nil)
        #expect(h.lines[3].newLine == 3)
        #expect(h.lines[5].oldLine == 4 && h.lines[5].newLine == 5)
    }

    @Test func newDeletedRenamedBinaryAndNoNewline() {
        let text = """
            diff --git a/new.txt b/new.txt
            new file mode 100644
            index 0000000..e69de29
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1,2 @@
            +hello
            +world
            \\ No newline at end of file
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            index e69de29..0000000
            --- a/gone.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            diff --git a/old name.txt b/new name.txt
            similarity index 90%
            rename from old name.txt
            rename to new name.txt
            index 1111111..2222222 100644
            --- a/old name.txt
            +++ b/new name.txt
            @@ -1 +1 @@
            -a
            +b
            diff --git a/img.png b/img.png
            index 1111111..2222222 100644
            Binary files a/img.png and b/img.png differ
            diff --git a/moved.txt b/moved2.txt
            similarity index 100%
            rename from moved.txt
            rename to moved2.txt

            """
        let files = UnifiedDiffParser.parse(text)
        #expect(files.map(\.path) == ["new.txt", "gone.txt", "new name.txt", "img.png", "moved2.txt"])
        #expect(files[0].status == .added)
        #expect(files[0].additions == 2)
        #expect(files[0].hunks[0].lines.last?.kind == .noNewline)
        #expect(files[1].status == .deleted)
        #expect(files[1].deletions == 1)
        #expect(files[2].status == .renamed)
        #expect(files[2].oldPath == "old name.txt")
        #expect(files[3].isBinary)
        #expect(files[4].status == .renamed)
        #expect(files[4].oldPath == "moved.txt")
        #expect(files[4].hunks.isEmpty)
    }

    @Test func quotedPaths() {
        let text = """
            diff --git "a/sp\\303\\251cial \\"q\\".txt" "b/sp\\303\\251cial \\"q\\".txt"
            index 1111111..2222222 100644
            --- "a/sp\\303\\251cial \\"q\\".txt"
            +++ "b/sp\\303\\251cial \\"q\\".txt"
            @@ -1 +1 @@
            -x
            +y

            """
        let files = UnifiedDiffParser.parse(text)
        #expect(files.count == 1)
        #expect(files[0].path == "spécial \"q\".txt")
    }

    @Test func removedLineThatLooksLikeHeader() {
        let text = """
            diff --git a/a.md b/a.md
            index 1111111..2222222 100644
            --- a/a.md
            +++ b/a.md
            @@ -1,2 +1,1 @@
            --- not a header
             keep

            """
        let files = UnifiedDiffParser.parse(text)
        #expect(files[0].deletions == 1)
        #expect(files[0].hunks[0].lines[0].text == "-- not a header")
    }

    @Test func gitHeaderSplitWithSpaces() {
        let r = UnifiedDiffParser.parseGitHeader("a/dir with space/f b.txt b/dir with space/f b.txt")
        #expect(r.a == "dir with space/f b.txt")
        #expect(r.b == "dir with space/f b.txt")
    }

    @Test func porcelainV2() {
        let out = [
            "1 .M N... 100644 100644 100644 aaaa bbbb src/a.swift",
            "1 A. N... 000000 100644 100644 0000 cccc new.swift",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 renamed.swift", "orig.swift",
            "u UU N... 100644 100644 100644 100644 a b c conflict.swift",
            "? untracked file.txt",
        ].joined(separator: "\0") + "\0"
        let s = Git.parsePorcelainV2(out)
        #expect(s.count == 5)
        #expect(s[0] == FileStatus(path: "src/a.swift", kind: .modified, staged: false))
        #expect(s[1] == FileStatus(path: "new.swift", kind: .added, staged: true))
        #expect(s[2] == FileStatus(path: "renamed.swift", origPath: "orig.swift", kind: .renamed, staged: true))
        #expect(s[3].kind == .conflicted)
        #expect(s[4] == FileStatus(path: "untracked file.txt", kind: .untracked, staged: false))
    }
}

// MARK: - Integration against real git

/// Temp sandbox: bare origin + a clone that plays "the user's repo".
struct Sandbox {
    let root: URL
    let origin: String
    let clone: String

    static func make() async throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitkit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin.git").path
        let seed = root.appendingPathComponent("seed").path
        let clone = root.appendingPathComponent("clone").path
        try await sh(["init", "-q", "--bare", "-b", "main", origin], cwd: root.path)
        try await sh(["init", "-q", "-b", "main", seed], cwd: root.path)
        try await configure(seed)
        try "line1\nline2\nline3\n".write(toFile: seed + "/README.md", atomically: true, encoding: .utf8)
        try await sh(["add", "-A"], cwd: seed)
        try await sh(["commit", "-q", "-m", "initial"], cwd: seed)
        try await sh(["remote", "add", "origin", origin], cwd: seed)
        try await sh(["push", "-q", "origin", "main"], cwd: seed)
        try await sh(["clone", "-q", origin, clone], cwd: root.path)
        try await configure(clone)
        return Sandbox(root: root, origin: origin, clone: clone)
    }

    static func configure(_ path: String) async throws {
        try await sh(["config", "user.email", "test@example.com"], cwd: path)
        try await sh(["config", "user.name", "Test"], cwd: path)
        try await sh(["config", "commit.gpgsign", "false"], cwd: path)
    }

    @discardableResult
    static func sh(_ args: [String], cwd: String) async throws -> String {
        try await Shell.run("git", args, cwd: cwd).stdout
    }

    /// Pushes a commit to origin/main from a separate clone (simulates a teammate).
    func pushFromElsewhere(file: String, contents: String, message: String) async throws {
        let other = root.appendingPathComponent("other-\(UUID().uuidString.prefix(4))").path
        try await Sandbox.sh(["clone", "-q", origin, other], cwd: root.path)
        try await Sandbox.configure(other)
        try contents.write(toFile: other + "/" + file, atomically: true, encoding: .utf8)
        try await Sandbox.sh(["add", "-A"], cwd: other)
        try await Sandbox.sh(["commit", "-q", "-m", message], cwd: other)
        try await Sandbox.sh(["push", "-q", "origin", "main"], cwd: other)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct GitIntegrationTests {
    @Test func worktreeDiffCommitAndTrunkShip() async throws {
        let sb = try await Sandbox.make()
        defer { sb.cleanup() }

        let info = try await Git.repoInfo(path: sb.clone)
        #expect(info.defaultBranch == "main")
        #expect(info.remoteURL == sb.origin)

        // A teammate pushes; we must branch from the fresh origin, not the stale local main.
        try await sb.pushFromElsewhere(file: "teammate.txt", contents: "hi\n", message: "teammate")
        try await Git.fetch(repoPath: sb.clone, branch: "main")
        let wt = sb.root.appendingPathComponent("workspaces/repo/galibier").path
        let baseSHA = try await Git.createWorktree(repoPath: sb.clone, path: wt, branch: "test/galibier", base: "origin/main")
        #expect(FileManager.default.fileExists(atPath: wt + "/teammate.txt"))
        #expect(try await Git.currentHead(path: wt) == baseSHA)
        #expect(try await Git.currentBranch(path: wt) == "test/galibier")

        // Creating the same branch again fails clearly.
        await #expect(throws: GitError.self) {
            try await Git.createWorktree(repoPath: sb.clone, path: wt + "-2", branch: "test/galibier", base: "origin/main")
        }

        // Modify tracked + add untracked.
        try "line1\nchanged\nline3\n".write(toFile: wt + "/README.md", atomically: true, encoding: .utf8)
        try "brand new\nfile\n".write(toFile: wt + "/new.txt", atomically: true, encoding: .utf8)
        #expect(try await Git.hasUncommittedChanges(path: wt))
        let status = try await Git.status(path: wt)
        #expect(Set(status.map(\.path)) == ["README.md", "new.txt"])
        #expect(status.first { $0.path == "new.txt" }?.kind == .untracked)

        let diff = try await Git.diff(path: wt, base: "origin/main")
        #expect(diff.map(\.path) == ["new.txt", "README.md"])
        let readme = try #require(diff.first { $0.path == "README.md" })
        #expect(readme.additions == 1 && readme.deletions == 1)
        let newFile = try #require(diff.first { $0.path == "new.txt" })
        #expect(newFile.status == .added && newFile.additions == 2)
        #expect(Git.diffStat(diff) == DiffStat(files: 2, additions: 3, deletions: 1))

        let files = try await Git.listFiles(path: wt)
        #expect(files.contains("new.txt") && files.contains("README.md") && files.contains("teammate.txt"))

        #expect(try await Git.commitAll(path: wt, message: "My change\n\nBody text"))
        #expect(try await Git.commitAll(path: wt, message: "nothing") == false)
        #expect(try await Git.hasUncommittedChanges(path: wt) == false)
        let log = try await Git.log(path: wt, range: "origin/main..HEAD", limit: 10)
        #expect(log.count == 1)
        #expect(log[0].subject == "My change")
        #expect(log[0].body == "Body text")

        // Diff still shows committed work vs merge-base.
        #expect(try await Git.diff(path: wt, base: "origin/main").count == 2)
        #expect(try await Git.aheadBehind(path: wt, base: "origin/main") == AheadBehind(ahead: 1, behind: 0))

        // Teammate pushes again (non-conflicting) → trunkShip must rebase and push.
        try await sb.pushFromElsewhere(file: "other.txt", contents: "x\n", message: "teammate 2")
        let result = try await Git.trunkShip(path: wt, defaultBranch: "main")
        guard case .pushed(let sha) = result else {
            Issue.record("expected pushed, got \(result)")
            return
        }
        let remoteMain = try await Sandbox.sh(["rev-parse", "main"], cwd: sb.origin)
        #expect(remoteMain.trimmingCharacters(in: .whitespacesAndNewlines) == sha)
        #expect(try await Git.trunkShip(path: wt, defaultBranch: "main") == .nothingToShip)

        // Branch push with upstream.
        try await Git.push(path: wt, branch: "test/galibier", setUpstream: true)
        let remoteBranch = try await Sandbox.sh(["rev-parse", "test/galibier"], cwd: sb.origin)
        #expect(remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines) == sha)

        try await Git.removeWorktree(repoPath: sb.clone, path: wt, force: true)
        #expect(!FileManager.default.fileExists(atPath: wt))
        try await Git.deleteBranch(repoPath: sb.clone, branch: "test/galibier")
    }

    @Test func trunkShipConflict() async throws {
        let sb = try await Sandbox.make()
        defer { sb.cleanup() }
        try await Git.fetch(repoPath: sb.clone, branch: "main")
        let wt = sb.root.appendingPathComponent("wt").path
        try await Git.createWorktree(repoPath: sb.clone, path: wt, branch: "c/1", base: "origin/main")
        try "mine\n".write(toFile: wt + "/README.md", atomically: true, encoding: .utf8)
        try await Git.commitAll(path: wt, message: "mine")
        let before = try await Git.currentHead(path: wt)

        try await sb.pushFromElsewhere(file: "README.md", contents: "theirs\n", message: "theirs")
        let result = try await Git.trunkShip(path: wt, defaultBranch: "main")
        #expect(result == .conflict(files: ["README.md"]))
        // Rebase aborted: back where we started, clean tree.
        #expect(try await Git.currentHead(path: wt) == before)
        #expect(try await Git.hasUncommittedChanges(path: wt) == false)

        // Dirty tree is refused.
        try "dirty\n".write(toFile: wt + "/x.txt", atomically: true, encoding: .utf8)
        await #expect(throws: GitError.self) { try await Git.trunkShip(path: wt, defaultBranch: "main") }
    }
}
