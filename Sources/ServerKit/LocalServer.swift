import Darwin
import DQCore
import Foundation
import Synchronization

// macOS only: spawns the domestique binary.
#if os(macOS)
/// The server on this Mac: where it lives, how to find its binary, and starting it on demand.
public enum LocalServer {
    public struct LaunchError: Error, LocalizedError, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// `sun_path` is 104 bytes on macOS, including the terminating NUL.
    public static let maxSocketPathBytes = 103

    /// $DOMESTIQUE_SERVER_HOME, else ~/Library/Application Support/Domestique/server, or an existing teamcar directory there (matches the server's homeDir on darwin).
    public static var home: URL { home(in: ProcessInfo.processInfo.environment) }

    /// home/server.sock
    public static var socketPath: String { socketPath(in: ProcessInfo.processInfo.environment) }

    /// Finds the domestique binary: $DOMESTIQUE_SERVER_BIN, then the app bundle's Contents/Helpers/domestique, then
    /// server/domestique in the source checkout this file was built from, then `domestique` on PATH.
    public static func binary() -> URL? { binary(in: ProcessInfo.processInfo.environment) }

    /// If nothing answers on `socketPath`, starts `domestique serve` detached (its own session, output appended
    /// to home/server.log; it outlives the app) and waits up to `timeout` for the socket to accept.
    /// It runs with the user's login-shell environment: a GUI app's own PATH is launchd's minimal one, which
    /// would leave git without Homebrew tools like git-lfs (and setup scripts without node, bun, ...).
    ///
    /// `addListen` adds network listeners on top of server.toml's (`tcp://ip:port`). Only applies when this
    /// call starts the server. If they stop it from starting (port taken, older binary), it starts without them:
    /// phone access must never take the Mac's own server down.
    public static func ensureRunning(timeout: Duration = .seconds(10), addListen: [String] = []) async throws -> ServerEndpoint {
        let login = await LoginEnvironment.shared.environment()
        let env = ProcessInfo.processInfo.environment.merging(login) { $1 }
        do {
            return try await launch(timeout: timeout, environment: env, addListen: addListen).endpoint
        } catch where !addListen.isEmpty {
            return try await launch(timeout: timeout, environment: env).endpoint
        }
    }

    /// An address on this Mac that a phone could reach.
    public struct NetworkAddress: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable { case tailscale, lan }
        public var ip: String
        public var interface: String
        public var kind: Kind
        public var id: String { ip }
    }

    /// Port This Mac's server uses for network clients.
    public static let networkPort = 7420

    /// Tailscale addresses (100.64.0.0/10 on a utun) first, then private addresses on en*.
    public static func networkAddresses() -> [NetworkAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var found: [NetworkAddress] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                entry.pointee.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            let name = String(cString: entry.pointee.ifa_name)
            let octets = ip.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { continue }
            if name.hasPrefix("utun"), octets[0] == 100, (64...127).contains(octets[1]) {
                found.append(.init(ip: ip, interface: name, kind: .tailscale))
            } else if name.hasPrefix("en"),
                octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
            {
                found.append(.init(ip: ip, interface: name, kind: .lan))
            }
        }
        return found.sorted { ($0.kind == .tailscale ? 0 : 1, $0.ip) < ($1.kind == .tailscale ? 0 : 1, $1.ip) }
    }

    // MARK: Internals (environment injectable for tests)

    static func home(in env: [String: String]) -> URL {
        if let h = env["DOMESTIQUE_SERVER_HOME"] ?? env["TEAMCAR_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Application Support", "Domestique", directoryHint: .isDirectory)
        let current = base.appending(path: "server", directoryHint: .isDirectory)
        let legacy = base.appending(path: "teamcar", directoryHint: .isDirectory)
        let fm = FileManager.default
        return !fm.fileExists(atPath: current.path) && fm.fileExists(atPath: legacy.path) ? legacy : current
    }

    /// A file in the server's home. A home created before the rename keeps its teamcar.* names.
    public static func dataFile(_ ext: String, in home: URL) -> URL {
        let legacy = FileManager.default.fileExists(atPath: home.appending(path: "teamcar.sqlite").path)
        return home.appending(path: (legacy ? "teamcar." : "server.") + ext)
    }

    static func socketPath(in env: [String: String]) -> String {
        dataFile("sock", in: home(in: env)).path(percentEncoded: false)
    }

    static func binary(in env: [String: String]) -> URL? {
        let fm = FileManager.default
        func executable(_ url: URL) -> URL? {
            fm.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
        }
        if let p = env["DOMESTIQUE_SERVER_BIN"], !p.isEmpty, let url = executable(URL(fileURLWithPath: p)) {
            return url
        }
        if let url = executable(Bundle.main.bundleURL.appending(components: "Contents", "Helpers", "domestique")) {
            return url
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path(percentEncoded: false) != "/" {
            let gomod = dir.appending(components: "server", "go.mod")
            if fm.fileExists(atPath: gomod.path(percentEncoded: false)) {
                if let url = executable(dir.appending(components: "server", "domestique")) { return url }
                break
            }
            dir.deleteLastPathComponent()
        }
        for p in (env["PATH"] ?? "").split(separator: ":") where !p.isEmpty {
            if let url = executable(URL(fileURLWithPath: String(p)).appending(path: "domestique")) { return url }
        }
        return nil
    }

    /// `ensureRunning`, also returning the process it started (nil if one was already running).
    static func launch(
        timeout: Duration, environment env: [String: String] = ProcessInfo.processInfo.environment, addListen: [String] = []
    ) async throws -> (endpoint: ServerEndpoint, started: Child?) {
        let socket = socketPath(in: env)
        let home = home(in: env)
        let logURL = dataFile("log", in: home)
        guard socket.utf8.count <= maxSocketPathBytes else {
            throw LaunchError(
                "Server's socket path is \(socket.utf8.count) bytes, over macOS's \(maxSocketPathBytes)-byte limit for Unix sockets: \(socket). Set DOMESTIQUE_SERVER_HOME to a shorter directory.")
        }
        let endpoint = ServerEndpoint.unix(path: socket)
        if socketAccepts(socket) { return (endpoint, nil) }

        guard let bin = binary(in: env) else {
            throw LaunchError("Can't find the domestique binary (set DOMESTIQUE_SERVER_BIN, or build server/domestique).")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let child = try spawn(bin, arguments: ["serve"] + addListen.flatMap { ["--add-listen", $0] }, environment: env, log: logURL)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if socketAccepts(socket) { return (endpoint, child) }
            if let status = child.exitStatus {
                let how = status & 0x7f == 0 ? "exit code \((status >> 8) & 0xff)" : "signal \(status & 0x7f)"
                throw LaunchError("domestique exited (\(how)) before it was ready.\n\(logTail(logURL))")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LaunchError("domestique (pid \(child.pid)) didn't open \(socket) within \(timeout).\n\(logTail(logURL))")
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
        return "server.log:\n" + String(decoding: data, as: UTF8.self)
    }
}
#endif
