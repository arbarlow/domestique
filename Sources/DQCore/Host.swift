import Foundation

/// A concrete local process to spawn: everything Domestique runs (git, agents, tasks, terminals)
/// is a local process, even when the work happens on a remote machine (then it's `ssh … -- cmd`).
public struct HostCommand: Sendable, Hashable {
    /// Absolute path of the local executable.
    public var executable: String
    public var arguments: [String]
    /// Full environment for the local process.
    public var environment: [String: String]
    /// Local working directory for the spawned process.
    public var cwd: String

    public init(executable: String, arguments: [String], environment: [String: String], cwd: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
    }

    /// argv[0...] as one array.
    public var argv: [String] { [executable] + arguments }
}

/// Where a workspace's code lives and its processes run: this Mac, or a cloud machine.
///
/// Callers always go through `command`/`shell` to get something to spawn, and `prepare()` first
/// (a stopped cloud machine is resumed and reconnected there). Paths and `cwd` are paths *on the host*.
public protocol ExecutionHost: AnyObject, Sendable {
    /// Stable id: "local", or e.g. "boat:bx_abc12345".
    var id: String { get }
    var isLocal: Bool { get }
    /// Short label for UI ("This Mac", "boat.dev").
    var displayName: String { get }

    /// Make the host usable: start/resume the machine and connect. Cheap when already ready.
    func prepare() async throws

    /// A process running `executable arguments` in `cwd` on the host. `env` is added on top of the
    /// host's own login environment. `tty` asks for a terminal (PTY-backed tasks, interactive shells).
    func command(_ executable: String, _ arguments: [String], cwd: String, env: [String: String], tty: Bool) async throws
        -> HostCommand

    /// A process running a shell script (`bash`/`zsh -c script`) in `cwd` on the host.
    func shell(_ script: String, cwd: String, env: [String: String], tty: Bool) async throws -> HostCommand

    /// Reads a file on the host. nil if it doesn't exist; throws `HostFileTooLarge` above `maxBytes`.
    func readFile(_ path: String, maxBytes: Int) async throws -> Data?
    func writeFile(_ path: String, data: Data) async throws
    func fileExists(_ path: String) async -> Bool
}

public struct HostFileTooLarge: Error, LocalizedError, Sendable {
    public var size: Int
    public init(size: Int) { self.size = size }
    public var errorDescription: String? { "File too large (\(size / 1024) KB)" }
}

#if os(macOS)
extension ExecutionHost {
    /// Run a short-lived command to completion.
    @discardableResult
    public func run(
        _ executable: String, _ arguments: [String], cwd: String, env: [String: String] = [:], stdin: Data? = nil,
        check: Bool = true
    ) async throws -> ShellResult {
        try await prepare()
        let cmd = try await command(executable, arguments, cwd: cwd, env: env, tty: false)
        let result = try await Shell.runRaw(cmd.executable, cmd.arguments, cwd: cmd.cwd, env: cmd.environment, stdinData: stdin)
        if check && !result.succeeded {
            throw ShellError(command: ([executable] + arguments).joined(separator: " "), result: result)
        }
        return result
    }

    /// Run a shell script to completion.
    @discardableResult
    public func runScript(
        _ script: String, cwd: String, env: [String: String] = [:], stdin: Data? = nil, check: Bool = true,
        label: String? = nil
    ) async throws -> ShellResult {
        try await prepare()
        let cmd = try await shell(script, cwd: cwd, env: env, tty: false)
        let result = try await Shell.runRaw(cmd.executable, cmd.arguments, cwd: cmd.cwd, env: cmd.environment, stdinData: stdin)
        if check && !result.succeeded {
            throw ShellError(command: label ?? script, result: result)
        }
        return result
    }
}

/// This Mac. Processes run directly with the user's login environment.
public final class LocalHost: ExecutionHost {
    public static let shared = LocalHost()

    public let id = "local"
    public let isLocal = true
    public let displayName = "This Mac"

    public func prepare() async throws {}

    public func command(_ executable: String, _ arguments: [String], cwd: String, env: [String: String], tty: Bool)
        async throws -> HostCommand
    {
        let exe = try await LoginEnvironment.shared.resolve(executable)
        let base = await LoginEnvironment.shared.environment()
        return HostCommand(executable: exe, arguments: arguments, environment: base.merging(env) { $1 }, cwd: cwd)
    }

    public func shell(_ script: String, cwd: String, env: [String: String], tty: Bool) async throws -> HostCommand {
        let base = await LoginEnvironment.shared.environment()
        let merged = base.merging(env) { $1 }
        return HostCommand(executable: Self.shellPath(merged), arguments: ["-c", script], environment: merged, cwd: cwd)
    }

    public func readFile(_ path: String, maxBytes: Int) async throws -> Data? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attrs else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes { throw HostFileTooLarge(size: size) }
        return FileManager.default.contents(atPath: path)
    }

    public func writeFile(_ path: String, data: Data) async throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func fileExists(_ path: String) async -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The user's zsh/bash, else /bin/zsh.
    public static func shellPath(_ env: [String: String]) -> String {
        if let s = env["SHELL"], s.hasSuffix("/zsh") || s.hasSuffix("/bash"), FileManager.default.isExecutableFile(atPath: s) {
            return s
        }
        return "/bin/zsh"
    }
}

#endif

/// POSIX shell quoting.
public enum ShellQuote {
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@,+%".contains($0) }), s.allSatisfy(\.isASCII) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ argv: [String]) -> String { argv.map(quote).joined(separator: " ") }

    /// `export K='v'; …` for env vars with valid names.
    public static func exports(_ env: [String: String]) -> String {
        env.keys.sorted()
            .filter { $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
            .map { "export \($0)=\(quote(env[$0]!))" }
            .joined(separator: "; ")
    }
}
