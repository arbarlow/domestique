import DQCore
import Foundation

// macOS only: spawns the domestique binary.
#if os(macOS)
/// A workspace's processes on a remote server. Like `BoatHost`, every command becomes a local
/// process, here `domestique exec --url … -- bash -lc '…'`, which pipes stdin/stdout/stderr (or a PTY)
/// over the Domestique protocol the way `ssh -tt` would. So git, setup scripts, run-dock tasks, terminals, port
/// probes and file reads all work unchanged on a remote server.
public final class ServerHost: ExecutionHost {
    public let serverID: UUID
    public let id: String
    public let isLocal = false
    public let displayName: String
    private let url: String
    private let token: String?

    public init(serverID: UUID, name: String, url: String, token: String?) {
        self.serverID = serverID
        self.id = "teamcar:" + serverID.uuidString
        self.displayName = name
        self.url = url
        self.token = token
    }

    public func prepare() async throws {
        guard LocalServer.binary() != nil else {
            throw ServerError(code: .unavailable, message: "The domestique binary wasn't found, so \(displayName) can't run commands.")
        }
    }

    /// `cd` to the workspace (falling back to $HOME like ssh would), export the environment, run `body`
    /// in a login bash so the server user's PATH (nvm, cargo, …) applies.
    static func script(_ body: String, cwd: String, env: [String: String]) -> String {
        let cd = "cd \(ShellQuote.quote(cwd)) 2>/dev/null || cd \"$HOME\""
        return [cd, ShellQuote.exports(env), body].filter { !$0.isEmpty }.joined(separator: "; ")
    }

    public func command(_ executable: String, _ arguments: [String], cwd: String, env: [String: String], tty: Bool)
        async throws -> HostCommand
    {
        try await exec(Self.script("exec " + ShellQuote.join([executable] + arguments), cwd: cwd, env: env), tty: tty)
    }

    public func shell(_ script: String, cwd: String, env: [String: String], tty: Bool) async throws -> HostCommand {
        try await exec(Self.script(script, cwd: cwd, env: env), tty: tty)
    }

    private func exec(_ script: String, tty: Bool) async throws -> HostCommand {
        guard let binary = LocalServer.binary() else {
            throw ServerError(code: .unavailable, message: "The domestique binary wasn't found.")
        }
        var args = ["exec", "--url", url]
        if tty { args.append("--tty") }
        args += ["--", "bash", "-lc", script]
        var env = await LoginEnvironment.shared.environment()
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        // The token travels in the environment, never argv (visible in `ps`).
        env["DOMESTIQUE_SERVER_TOKEN"] = token ?? ""
        env["DOMESTIQUE_SERVER_URL"] = nil
        return HostCommand(
            executable: binary.path, arguments: args, environment: env,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    public func readFile(_ path: String, maxBytes: Int) async throws -> Data? {
        let q = ShellQuote.quote(path)
        // `wc -c` works on both Linux and macOS servers (stat's flags differ).
        let r = try await runScript(
            "if [ ! -f \(q) ]; then exit 3; fi; s=$(wc -c < \(q) | tr -d ' '); if [ \"$s\" -gt \(maxBytes) ]; then echo \"$s\"; exit 4; fi; cat \(q)",
            cwd: "/", check: false)
        switch r.status {
        case 0: return r.stdoutData
        case 3: return nil
        case 4: throw HostFileTooLarge(size: Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? maxBytes + 1)
        default: throw ShellError(command: "read \(path)", result: r)
        }
    }

    public func writeFile(_ path: String, data: Data) async throws {
        let q = ShellQuote.quote(path)
        try await runScript("mkdir -p \"$(dirname \(q))\" && cat > \(q)", cwd: "/", stdin: data, label: "write \(path)")
    }

    public func fileExists(_ path: String) async -> Bool {
        (try? await runScript("test -e \(ShellQuote.quote(path))", cwd: "/", check: false).succeeded) ?? false
    }
}
#endif
