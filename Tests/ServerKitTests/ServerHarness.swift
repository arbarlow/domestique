import Foundation
import Testing
@testable import ServerKit

/// Builds the Go server once per test run and runs throwaway instances of it.
enum ServerBuild {
    static let repoRoot: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(components: "server", "go.mod").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return dir
    }()

    static let go: String? = {
        for dir in ["/opt/homebrew/bin", "/usr/local/go/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            let p = dir + "/go"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    static var goAvailable: Bool { go != nil }

    /// The built binary (built on first use).
    static let binary: Result<URL, any Error> = {
        guard let go else { return .failure(HarnessError("go is not installed")) }
        do {
            // A fixed place, rebuilt (incrementally) on every run, so runs don't pile up 20 MB binaries.
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "rrk-domestique-\(getuid())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appending(path: "domestique")
            let r = try run(go, ["-C", repoRoot.appending(path: "server").path, "build", "-o", out.path, "./cmd/domestique"])
            guard r.status == 0 else { return .failure(HarnessError("go build failed:\n\(r.output)")) }
            return .success(out)
        } catch {
            return .failure(error)
        }
    }()

    static func makeTempDir(_ prefix: String) throws -> URL {
        // Short /tmp paths: Unix socket paths are limited to 103 bytes.
        var template = Array("/tmp/\(prefix)-XXXXXX".utf8CString)
        guard let p = mkdtemp(&template) else { throw HarnessError("mkdtemp failed") }
        // Resolve /tmp -> /private/tmp so paths match what the server (git) reports.
        guard let real = realpath(p, nil) else { throw HarnessError("realpath failed") }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }

    struct RunResult { var status: Int32; var output: String; var stdout: String }

    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil) throws -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let so = String(decoding: o, as: UTF8.self)
        return RunResult(status: p.terminationStatus, output: so + String(decoding: e, as: UTF8.self), stdout: so)
    }
}

struct HarnessError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// One running `domestique serve` with its own home, on a Unix socket and a loopback TCP port.
final class ServerServer: @unchecked Sendable {
    // @unchecked: only touched from one test at a time (each test owns its server).
    let root: URL
    let home: URL
    let workspacesRoot: URL
    let reposRoot: URL
    let socketPath: String
    let port: Int
    let binary: URL
    private var process: Process?

    init() throws {
        binary = try ServerBuild.binary.get()
        root = try ServerBuild.makeTempDir("rrk")
        home = root.appending(path: "home")
        workspacesRoot = root.appending(path: "ws")
        reposRoot = root.appending(path: "repos")
        for d in [home, workspacesRoot, reposRoot] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        socketPath = home.appending(path: "server.sock").path
        port = try Self.freePort()
    }

    var unix: ServerEndpoint { .unix(path: socketPath) }
    var tcp: ServerEndpoint { .url(URL(string: "ws://127.0.0.1:\(port)")!) }

    var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["DOMESTIQUE_SERVER_HOME"] = home.path
        e["DOMESTIQUE_SERVER_WORKSPACES_ROOT"] = workspacesRoot.path
        e["DOMESTIQUE_SERVER_REPOS_ROOT"] = reposRoot.path
        // Sandbox providers never reach the real boat.dev from tests (port 9 is discard: refused).
        e["DOMESTIQUE_SERVER_BOAT_URL"] = "http://127.0.0.1:9/api/v1"
        e["BOAT_API_KEY"] = nil
        return e
    }

    func start() async throws {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["serve", "--listen", "unix://\(socketPath)", "--listen", "tcp://127.0.0.1:\(port)", "--name", "rrk-test"]
        p.environment = env
        let log = FileHandle(forWritingAtPath: logPath) ?? {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return FileHandle(forWritingAtPath: logPath)!
        }()
        log.seekToEndOfFile()
        p.standardOutput = log
        p.standardError = log
        try p.run()
        process = p
        for _ in 0..<100 {
            if LocalServer.socketAccepts(socketPath), Self.tcpAccepts(port) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HarnessError("domestique didn't start:\n\(self.log)")
    }

    /// Kills the server (SIGKILL: no graceful goodbye, like a crash).
    func kill() {
        guard let p = process else { return }
        Darwin.kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
        process = nil
    }

    func stop() {
        guard let p = process else { return }
        p.terminate()
        p.waitUntilExit()
        process = nil
    }

    var pid: pid_t? { process?.processIdentifier }

    var logPath: String { root.appending(path: "server.log").path }
    var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

    func createToken(scope: String = "admin") throws -> String {
        let r = try ServerBuild.run(binary.path, ["token", "create", "--name", "t", "--scope", scope], env: env)
        guard r.status == 0 else { throw HarnessError("token create failed: \(r.output)") }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A git repo with one commit on `main` (no origin).
    func makeGitRepo(_ name: String = "demo") throws -> URL {
        let dir = root.appending(path: "src").appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello\n".write(to: dir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let git = "/usr/bin/git"
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@example.com"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@example.com"
        // Hermetic: no commit signing or hooks from the developer's config.
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        for args in [["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "init"]] {
            let r = try ServerBuild.run(git, args, cwd: dir, env: env)
            guard r.status == 0 else { throw HarnessError("git \(args) failed: \(r.output)") }
        }
        return dir
    }

    func cleanup() {
        stop()
        try? FileManager.default.removeItem(at: root)
    }

    deinit { if let p = process { Darwin.kill(p.processIdentifier, SIGKILL) } }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw HarnessError("no free port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func tcpAccepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

/// Pulls events from a subscription with a timeout.
final class EventReader: @unchecked Sendable {
    // @unchecked: the iterator is used by one test task at a time.
    private var iterator: AsyncStream<Proto_Event>.AsyncIterator

    init(_ sub: ServerSubscription) { iterator = sub.events.makeAsyncIterator() }

    /// The next event, or nil if the stream ended. Throws on timeout.
    func next(timeout: Duration = .seconds(10)) async throws -> Proto_Event? {
        let box = IteratorBox(iterator)
        let result = try await withThrowingTaskGroup(of: Proto_Event?.self) { group in
            group.addTask { await box.next() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HarnessError("timed out waiting for an event")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        iterator = box.iterator
        return result
    }

    /// Skips events until one matches.
    func first(timeout: Duration = .seconds(15), where match: (Proto_Event) -> Bool) async throws -> Proto_Event {
        let deadline = ContinuousClock.now + timeout
        while true {
            let left = deadline - .now
            guard left > .zero, let ev = try await next(timeout: left) else {
                throw HarnessError("stream ended or timed out before a matching event")
            }
            if match(ev) { return ev }
        }
    }
}

private final class IteratorBox: @unchecked Sendable {
    // @unchecked: handed to exactly one child task, read back after it finishes.
    var iterator: AsyncStream<Proto_Event>.AsyncIterator
    init(_ i: AsyncStream<Proto_Event>.AsyncIterator) { iterator = i }
    func next() async -> Proto_Event? { await iterator.next() }
}

extension Proto_Event {
    var isReplayDone: Bool { if case .replayDone = payload { true } else { false } }
    var snapshot: Proto_ServerSnapshot? { if case .serverSnapshot(let s) = payload { s } else { nil } }
    var item: Proto_TranscriptItem? { if case .itemUpserted(let i) = payload { i } else { nil } }
    var workspace: Proto_Workspace? { if case .workspaceUpserted(let w) = payload { w } else { nil } }
}
