import DQCore
import Foundation

/// A workspace's boat.dev sandbox as an `ExecutionHost`.
///
/// `prepare()` makes it usable from any state: a stopped sandbox is resumed, a fresh machine gets
/// Domestique's SSH key authorized and its host key pinned (both change on every resume), and the
/// SSH master is (re)connected. Everything else is plain OpenSSH on top of `SSHConnection`.
public final class BoatHost: ExecutionHost, @unchecked Sendable {
    public let machineID: String
    public var id: String { "boat:\(machineID)" }
    public let isLocal = false
    public let displayName = "boat.dev"

    public let ssh: SSHConnection
    /// The sandbox provider's API client (its account).
    public let client: BoatClient
    private let state = State()

    /// Sourced by every remote command: per-sandbox settings Domestique writes (e.g. GH_TOKEN).
    public static let remoteEnvFile = "$HOME/.config/domestique/env.sh"
    public static let home = "/home/user"

    init(machineID: String, account: String?) {
        self.machineID = machineID
        self.ssh = SSHConnection(alias: machineID)
        self.client = BoatClient.client(account: account)
    }

    private actor State {
        var preparing: Task<Void, Error>?
        /// IP + host key the SSH connection was set up for; changes when boat moves the sandbox.
        var machineKey: String?
        var lastReady: Date?
        /// Called with the sandbox whenever prepare() sees it (UI status).
        var observer: (@Sendable (BoatSandbox) -> Void)?

        func setPreparing(_ t: Task<Void, Error>?) { preparing = t }
        func setMachineKey(_ k: String?) { machineKey = k }
        func markReady() { lastReady = .now }
        func invalidate() { lastReady = nil }
        func setObserver(_ o: (@Sendable (BoatSandbox) -> Void)?) { observer = o }
    }

    public func setObserver(_ o: (@Sendable (BoatSandbox) -> Void)?) async { await state.setObserver(o) }

    /// Forget the cached "ready" so the next prepare() re-checks the sandbox (after a stop, an error…).
    public func invalidate() async { await state.invalidate() }

    // MARK: prepare

    public func prepare() async throws {
        // Fast path: recently confirmed and the master is alive.
        if let ready = await state.lastReady, Date().timeIntervalSince(ready) < 20, await ssh.isConnected { return }
        if let t = await state.preparing { return try await t.value }
        let task = Task { try await self.doPrepare() }
        await state.setPreparing(task)
        defer { Task { await self.state.setPreparing(nil) } }
        try await task.value
    }

    private func doPrepare() async throws {
        let client = self.client
        var sandbox = try await client.sandbox(machineID)
        await state.observer?(sandbox)
        switch sandbox.phase {
        case .stopped, .error:
            try await client.resume(machineID)
            sandbox = try await client.waitUntilRunning(machineID) { s in Task { await self.state.observer?(s) } }
        case .stopping:
            // Wait for the stop to land, then resume.
            for _ in 0..<120 {
                try await Task.sleep(for: .seconds(1.5))
                sandbox = try await client.sandbox(machineID)
                if sandbox.phase != .stopping { break }
            }
            if sandbox.phase == .stopped || sandbox.phase == .error {
                try await client.resume(machineID)
            }
            sandbox = try await client.waitUntilRunning(machineID) { s in Task { await self.state.observer?(s) } }
        case .starting:
            sandbox = try await client.waitUntilRunning(machineID) { s in Task { await self.state.observer?(s) } }
        case .gone:
            throw HostError("The boat.dev sandbox \(machineID) was deleted.")
        case .running:
            break
        }
        await state.observer?(sandbox)

        let machineKey = "\(sandbox.ip ?? "")|\(sandbox.sshEndpoint ?? "")"
        let knownKey = await state.machineKey
        let connected = await ssh.isConnected
        if knownKey != machineKey || !connected {
            let pub = try await DomestiqueSSHKey.publicKey()
            let access = try await retrying { try await client.sshAccess(self.machineID, publicKey: pub) }
            let endpoint = try Self.endpoint(access, sandbox: sandbox)
            try await ssh.setEndpoint(endpoint)
            try await ssh.connect()
            await state.setMachineKey(machineKey)
        }
        await state.markReady()
    }

    static func endpoint(_ a: BoatSSHAccess, sandbox: BoatSandbox) throws -> SSHEndpoint {
        let user = a.sshUser ?? "user"
        if let ep = a.sshEndpoint ?? sandbox.sshEndpoint, let colon = ep.lastIndex(of: ":"), let port = Int(ep[ep.index(after: colon)...]) {
            return SSHEndpoint(host: String(ep[..<colon]), port: port, user: user, hostKey: a.hostKey)
        }
        guard let ip = a.machineIp ?? sandbox.ip else { throw HostError("boat.dev didn't report an address for \(sandbox.id)") }
        return SSHEndpoint(host: ip, port: 22, user: user, hostKey: a.hostKey)
    }

    /// boat answers `sandbox_restoring` / `sandbox_securing` for a few seconds after a start.
    private func retrying<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        var last: Error?
        for attempt in 1...6 {
            do { return try await body() } catch {
                last = error
                if let e = error as? BoatAPIError, e.status == 401 || e.status == 404 { throw e }
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
        throw last ?? HostError("boat.dev request failed")
    }

    // MARK: commands

    /// The remote string handed to the login shell: source Domestique's env, cd, export, run.
    static func remoteScript(_ body: String, cwd: String, env: [String: String]) -> String {
        let prelude = "[ -r \"\(remoteEnvFile)\" ] && . \"\(remoteEnvFile)\""
        let cd = "cd \(ShellQuote.quote(cwd)) 2>/dev/null || cd \"$HOME\""
        let exports = ShellQuote.exports(env)
        let inner = [prelude, cd, exports, body].filter { !$0.isEmpty }.joined(separator: "; ")
        // A login shell, so ~/.profile (nvm, cargo, …) sets PATH like an interactive `boat ssh`.
        return "exec bash -lc " + ShellQuote.quote(inner)
    }

    public func command(_ executable: String, _ arguments: [String], cwd: String, env: [String: String], tty: Bool)
        async throws -> HostCommand
    {
        let script = Self.remoteScript("exec " + ShellQuote.join([executable] + arguments), cwd: cwd, env: env)
        return try await local(script, tty: tty)
    }

    public func shell(_ script: String, cwd: String, env: [String: String], tty: Bool) async throws -> HostCommand {
        try await local(Self.remoteScript(script, cwd: cwd, env: env), tty: tty)
    }

    private func local(_ remote: String, tty: Bool) async throws -> HostCommand {
        let argv = try await ssh.clientArgv(remoteCommand: remote, tty: tty)
        var env = await LoginEnvironment.shared.environment()
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        return HostCommand(
            executable: argv[0], arguments: Array(argv.dropFirst()), environment: env,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: files

    public func readFile(_ path: String, maxBytes: Int) async throws -> Data? {
        let q = ShellQuote.quote(path)
        let r = try await runScript(
            "if [ ! -f \(q) ]; then exit 3; fi; s=$(stat -c %s \(q)); if [ \"$s\" -gt \(maxBytes) ]; then echo \"$s\"; exit 4; fi; cat \(q)",
            cwd: Self.home, check: false)
        switch r.status {
        case 0: return r.stdoutData
        case 3: return nil
        case 4: throw HostFileTooLarge(size: Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? maxBytes + 1)
        default: throw ShellError(command: "read \(path)", result: r)
        }
    }

    public func writeFile(_ path: String, data: Data) async throws {
        let q = ShellQuote.quote(path)
        try await runScript("mkdir -p \"$(dirname \(q))\" && cat > \(q)", cwd: Self.home, stdin: data, label: "write \(path)")
    }

    public func fileExists(_ path: String) async -> Bool {
        let r = try? await runScript("test -e \(ShellQuote.quote(path))", cwd: Self.home, check: false)
        return r?.succeeded == true
    }

    /// Drop SSH state (archive / delete).
    public func disconnect() async {
        await ssh.cancelAllForwards()
        await ssh.closeMaster()
        await state.invalidate()
        await state.setMachineKey(nil)
    }
}

/// One `ExecutionHost` per machine, shared by everything in the app.
public enum Hosts {
    nonisolated(unsafe) private static var boat: [String: BoatHost] = [:]
    private static let lock = NSLock()

    /// Builds hosts for remote Team Cars (set by the app, which knows their URLs and tokens).
    nonisolated(unsafe) public static var teamCarResolver: (@Sendable (WorkspaceHost) -> (any ExecutionHost)?)?

    public static func host(for h: WorkspaceHost?) -> any ExecutionHost {
        guard let h else { return LocalHost.shared }
        switch h.provider {
        case .boat: return boatHost(h.machineID, account: h.accountID)
        case .teamcar: return teamCarResolver?(h) ?? UnavailableHost(name: h.machineName ?? "Team Car")
        }
    }

    /// - Parameter account: the sandbox provider's Keychain account (nil = the original one).
    public static func boatHost(_ id: String, account: String? = nil) -> BoatHost {
        lock.withLock {
            if let b = boat[id] { return b }
            let b = BoatHost(machineID: id, account: account)
            boat[id] = b
            return b
        }
    }

    /// Every boat host created so far (app shutdown).
    public static var allBoatHosts: [BoatHost] { lock.withLock { Array(boat.values) } }
}

/// Stands in for a remote Team Car that's no longer in Settings: every command fails with a clear message.
final class UnavailableHost: ExecutionHost {
    let id = "unavailable"
    let isLocal = false
    let displayName: String
    init(name: String) { displayName = name }
    private var error: HostError { HostError("\(displayName) isn't in Settings → Team Cars any more.") }
    func prepare() async throws { throw error }
    func command(_ executable: String, _ arguments: [String], cwd: String, env: [String: String], tty: Bool) async throws -> HostCommand { throw error }
    func shell(_ script: String, cwd: String, env: [String: String], tty: Bool) async throws -> HostCommand { throw error }
    func readFile(_ path: String, maxBytes: Int) async throws -> Data? { throw error }
    func writeFile(_ path: String, data: Data) async throws { throw error }
    func fileExists(_ path: String) async -> Bool { false }
}
