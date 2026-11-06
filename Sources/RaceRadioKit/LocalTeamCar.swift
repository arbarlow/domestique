import Darwin
import DQCore
import Foundation
import Synchronization

/// The Team Car on this Mac: where it lives, how to find its binary, and starting it on demand.
public enum LocalTeamCar {
    public struct LaunchError: Error, LocalizedError, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// `sun_path` is 104 bytes on macOS, including the terminating NUL.
    public static let maxSocketPathBytes = 103

    /// $TEAMCAR_HOME, else ~/Library/Application Support/Domestique/teamcar (matches teamcar's homeDir on darwin).
    public static var home: URL { home(in: ProcessInfo.processInfo.environment) }

    /// home/teamcar.sock
    public static var socketPath: String { socketPath(in: ProcessInfo.processInfo.environment) }

    /// Finds the teamcar binary: $DOMESTIQUE_TEAMCAR, then the app bundle's Contents/Helpers/teamcar, then
    /// teamcar/teamcar in the source checkout this file was built from, then `teamcar` on PATH.
    public static func binary() -> URL? { binary(in: ProcessInfo.processInfo.environment) }

    /// If nothing answers on `socketPath`, starts `teamcar serve` detached (its own session, output appended
    /// to home/teamcar.log; it outlives the app) and waits up to `timeout` for the socket to accept.
    /// It runs with the user's login-shell environment: a GUI app's own PATH is launchd's minimal one, which
    /// would leave git without Homebrew tools like git-lfs (and setup scripts without node, bun, ...).
    public static func ensureRunning(timeout: Duration = .seconds(10)) async throws -> TeamCarEndpoint {
        let login = await LoginEnvironment.shared.environment()
        let env = ProcessInfo.processInfo.environment.merging(login) { $1 }
        return try await launch(timeout: timeout, environment: env).endpoint
    }

    // MARK: Internals (environment injectable for tests)

    static func home(in env: [String: String]) -> URL {
        if let h = env["TEAMCAR_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Application Support", "Domestique", "teamcar", directoryHint: .isDirectory)
    }

    static func socketPath(in env: [String: String]) -> String {
        home(in: env).appending(path: "teamcar.sock").path(percentEncoded: false)
    }

    static func binary(in env: [String: String]) -> URL? {
        let fm = FileManager.default
        func executable(_ url: URL) -> URL? {
            fm.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
        }
        if let p = env["DOMESTIQUE_TEAMCAR"], !p.isEmpty, let url = executable(URL(fileURLWithPath: p)) {
            return url
        }
        if let url = executable(Bundle.main.bundleURL.appending(components: "Contents", "Helpers", "teamcar")) {
            return url
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path(percentEncoded: false) != "/" {
            let gomod = dir.appending(components: "teamcar", "go.mod")
            if fm.fileExists(atPath: gomod.path(percentEncoded: false)) {
                if let url = executable(dir.appending(components: "teamcar", "teamcar")) { return url }
                break
            }
            dir.deleteLastPathComponent()
        }
        for p in (env["PATH"] ?? "").split(separator: ":") where !p.isEmpty {
            if let url = executable(URL(fileURLWithPath: String(p)).appending(path: "teamcar")) { return url }
        }
        return nil
    }

    /// `ensureRunning`, also returning the process it started (nil if one was already running).
    static func launch(
        timeout: Duration, environment env: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> (endpoint: TeamCarEndpoint, started: Child?) {
        let socket = socketPath(in: env)
        let home = home(in: env)
        let logURL = home.appending(path: "teamcar.log")
        guard socket.utf8.count <= maxSocketPathBytes else {
            throw LaunchError(
                "Team Car's socket path is \(socket.utf8.count) bytes, over macOS's \(maxSocketPathBytes)-byte limit for Unix sockets: \(socket). Set TEAMCAR_HOME to a shorter directory.")
        }
        let endpoint = TeamCarEndpoint.unix(path: socket)
        if socketAccepts(socket) { return (endpoint, nil) }

        guard let bin = binary(in: env) else {
            throw LaunchError("Can't find the teamcar binary (set DOMESTIQUE_TEAMCAR, or build teamcar/teamcar).")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let child = try spawn(bin, arguments: ["serve"], environment: env, log: logURL)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if socketAccepts(socket) { return (endpoint, child) }
            if let status = child.exitStatus {
                let how = status & 0x7f == 0 ? "exit code \((status >> 8) & 0xff)" : "signal \(status & 0x7f)"
                throw LaunchError("teamcar exited (\(how)) before it was ready.\n\(logTail(logURL))")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LaunchError("teamcar (pid \(child.pid)) didn't open \(socket) within \(timeout).\n\(logTail(logURL))")
    }

    // MARK: Internals

    /// True if something accepts connections on the Unix socket at `path`.
    static func socketAccepts(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return rc == 0
    }

    /// A detached child, reaped in the background so it never lingers as a zombie.
    final class Child: Sendable {
        let pid: pid_t
        private let status = Mutex<Int32?>(nil)

        init(pid: pid_t) {
            self.pid = pid
            Thread.detachNewThread { [self] in
                var st: Int32 = 0
                while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
                status.withLock { $0 = st }
            }
        }

        /// The raw wait status once the process has exited.
        var exitStatus: Int32? { status.withLock { $0 } }
    }

    /// posix_spawn with POSIX_SPAWN_SETSID (own session and process group, so it survives the app and
    /// its terminal), stdin from /dev/null, stdout and stderr appended to `log`, no other inherited fds.
    static func spawn(_ executable: URL, arguments: [String], environment: [String: String], log: URL) throws -> Child {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path(percentEncoded: false), O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // Default signal dispositions and an empty mask, whatever the app had.
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)

        let path = executable.path(percentEncoded: false)
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        guard rc == 0 else {
            throw LaunchError("Can't start \(path): \(String(cString: strerror(rc)))")
        }
        return Child(pid: pid)
    }

    static func logTail(_ logURL: URL, maxBytes: Int = 4096) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "(no log at \(logURL.path(percentEncoded: false)))" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return "teamcar.log:\n" + String(decoding: data, as: UTF8.self)
    }
}
