import DQCore
import Foundation
import Testing
@testable import ServerKit

/// `ServerHost` against a real server over TCP + token: the layer the app's git panel, file viewer,
/// run dock, terminals and ship actions use for workspaces on a remote server (`domestique exec` under the hood).
@Suite(.enabled(if: ServerBuild.goAvailable, "go is not installed; skipping server integration tests"), .timeLimit(.minutes(2)))
struct ServerHostTests {
    let server: ServerServer
    let host: ServerHost

    init() async throws {
        server = try ServerServer()
        try await server.start()
        // ServerHost runs the domestique binary it finds through LocalServer.binary().
        setenv("DOMESTIQUE_SERVER_BIN", server.binary.path, 1)
        let token = try server.createToken(scope: "operate")
        host = ServerHost(serverID: UUID(), name: "test-server", url: "ws://127.0.0.1:\(server.port)", token: token)
    }

    @Test func runsGitInARepository() async throws {
        defer { server.cleanup() }
        let repo = try server.makeGitRepo()
        let head = try ServerBuild.run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: repo).stdout
        let remote = try await host.run("git", ["rev-parse", "HEAD"], cwd: repo.path)
        #expect(remote.stdout == head)
        try "changed\n".write(to: repo.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        let status = try await host.run("git", ["status", "--porcelain"], cwd: repo.path)
        #expect(status.stdout.contains("?? new.txt"))
    }

    @Test func exitCodesStderrAndEnvironment() async throws {
        defer { server.cleanup() }
        let r = try await host.runScript("echo out; echo err >&2; exit 3", cwd: "/", check: false)
        #expect(r.status == 3)
        #expect(r.stdout == "out\n")
        #expect(r.stderr.contains("err"))
        let env = try await host.runScript("printf %s \"$FOO\"", cwd: "/", env: ["FOO": "bar 'baz' $x"])
        #expect(env.stdout == "bar 'baz' $x")
        // A missing directory falls back to $HOME, like ssh.
        let cwd = try await host.runScript("pwd", cwd: "/no/such/dir")
        #expect(cwd.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func filesAndStdin() async throws {
        defer { server.cleanup() }
        let dir = server.root.appending(path: "files").path
        let path = dir + "/sub/blob.bin"
        var bytes = Data((0..<256).map { UInt8($0) })
        bytes.append(Data(repeating: 7, count: 1_000_000))
        try await host.writeFile(path, data: bytes)
        #expect(await host.fileExists(path))
        #expect(!(await host.fileExists(dir + "/nope")))
        #expect(try await host.readFile(path, maxBytes: 2_000_000) == bytes)
        #expect(try await host.readFile(dir + "/nope", maxBytes: 10) == nil)
        await #expect(throws: HostFileTooLarge.self) { _ = try await host.readFile(path, maxBytes: 100) }
        let echoed = try await host.run("cat", [], cwd: "/", stdin: bytes)
        #expect(echoed.stdoutData == bytes)
    }

    @Test func ttyCommands() async throws {
        defer { server.cleanup() }
        let cmd = try await host.command("bash", ["-c", "tty; stty size"], cwd: "/", env: [:], tty: true)
        #expect(cmd.arguments.contains("--tty"))
        #expect(!cmd.arguments.joined().contains("dq_"), "the token must not be in argv")
        let r = try await Shell.runRaw(cmd.executable, cmd.arguments, cwd: cmd.cwd, env: cmd.environment, stdinData: nil)
        #expect(r.succeeded)
        #expect(r.stdout.contains("/dev/"))
        #expect(r.stdout.contains("50 200"))
    }

    @Test func badTokenFailsClearly() async throws {
        defer { server.cleanup() }
        let bad = ServerHost(serverID: UUID(), name: "test-server", url: "ws://127.0.0.1:\(server.port)", token: "dq_nope")
        let r = try await bad.runScript("true", cwd: "/", check: false)
        #expect(r.status == 255)
        #expect(r.stderr.contains("UNAUTHENTICATED"))
    }
}
