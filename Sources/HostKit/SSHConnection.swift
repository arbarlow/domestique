import DQCore
import Darwin
import Foundation

/// Where and how to reach a machine over SSH.
public struct SSHEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var user: String
    /// Pinned host key ("ssh-ed25519 AAAA…"), from the provider's API, never trust-on-first-use.
    public var hostKey: String

    public init(host: String, port: Int, user: String, hostKey: String) {
        self.host = host
        self.port = port
        self.user = user
        self.hostKey = hostKey
    }

    /// "user@host" (IPv6 needs no brackets for ssh's destination argument).
    var destination: String { "\(user)@\(host)" }
}

/// Domestique's own SSH key pair (~/Library/Application Support/Domestique/ssh/id_ed25519).
/// Separate from the user's keys; authorized on each cloud machine through the provider's API.
public enum DomestiqueSSHKey {
    public static var directory: URL { Paths.appSupport.appendingPathComponent("ssh", isDirectory: true) }
    public static var privateKey: URL { directory.appendingPathComponent("id_ed25519") }
    public static var publicKeyURL: URL { directory.appendingPathComponent("id_ed25519.pub") }

    /// Public key text, generating the pair on first use.
    public static func publicKey() async throws -> String {
        if let s = try? String(contentsOf: publicKeyURL, encoding: .utf8), !s.isEmpty,
            FileManager.default.fileExists(atPath: privateKey.path)
        {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: privateKey)
        try? FileManager.default.removeItem(at: publicKeyURL)
        let r = try await Shell.runRaw(
            "/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "domestique@\(Host.current().localizedName ?? "mac")", "-f", privateKey.path],
            cwd: nil, env: ProcessInfo.processInfo.environment)
        guard r.succeeded else { throw HostError("Couldn't create an SSH key: \(r.stderr)") }
        return try String(contentsOf: publicKeyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct HostError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One multiplexed OpenSSH connection to a machine.
///
/// A long-lived `ssh -N -o ControlMaster=yes` process owns the TCP connection; every command,
/// agent and task is a cheap `ssh -o ControlPath=…` client riding on it (~50ms instead of a full
/// handshake). Clients use `ControlMaster=no`, so they still connect directly if the master is gone.
/// Local port forwards are added and removed on the live master (`ssh -O forward -L …`).
public actor SSHConnection {
    public nonisolated let alias: String
    private var endpoint: SSHEndpoint?
    private var master: Process?
    private var connecting: Task<Void, Error>?
    /// local port -> remote port, re-applied after a reconnect.
    private var forwards: [Int: Int] = [:]

    public init(alias: String) {
        self.alias = alias
    }

    nonisolated var controlPath: String {
        let dir = "/tmp/domestique-\(getuid())"
        return "\(dir)/\(alias).sock"
    }

    nonisolated var knownHostsPath: String { DomestiqueSSHKey.directory.appendingPathComponent("known_hosts_\(alias)").path }
    nonisolated var logPath: String { Paths.logs.appendingPathComponent("ssh-\(alias).log").path }

    public var currentEndpoint: SSHEndpoint? { endpoint }

    /// Point at a (possibly new) machine. A changed endpoint drops the old master.
    public func setEndpoint(_ e: SSHEndpoint) throws {
        if e != endpoint {
            closeMaster()
            endpoint = e
        }
        try FileManager.default.createDirectory(
            atPath: DomestiqueSSHKey.directory.path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "\(alias) \(e.hostKey)\n".write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
    }

    /// Options every ssh invocation for this machine shares.
    nonisolated func baseOptions(_ e: SSHEndpoint) -> [String] {
        [
            "-p", String(e.port),
            "-i", DomestiqueSSHKey.privateKey.path,
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"\(knownHostsPath)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=\(alias)",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "LogLevel=ERROR",
            "-o", "ControlPath=\(controlPath)",
        ]
    }

    /// argv for a client running `remoteCommand` (a string the remote login shell executes).
    public func clientArgv(remoteCommand: String, tty: Bool) throws -> [String] {
        guard let e = endpoint else { throw HostError("Not connected to \(alias)") }
        return ["/usr/bin/ssh"] + baseOptions(e) + ["-o", "ControlMaster=no", tty ? "-tt" : "-T", e.destination, remoteCommand]
    }

    // MARK: master

    public var isConnected: Bool { master?.isRunning == true }

    /// Starts the master if it isn't running and waits until it accepts clients.
    public func connect() async throws {
        if master?.isRunning == true, await check() { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.startMaster() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func startMaster() async throws {
        guard let e = endpoint else { throw HostError("No SSH endpoint for \(alias)") }
        _ = try await DomestiqueSSHKey.publicKey()
        let dir = (controlPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Another Domestique window may already own a master on this socket.
        if await check() { return }
        try? FileManager.default.removeItem(atPath: controlPath)

        var lastError = ""
        for attempt in 1...6 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = baseOptions(e) + ["-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "ExitOnForwardFailure=no", "-E", logPath, "-N", e.destination]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? Data().write(to: URL(fileURLWithPath: logPath))
            try p.run()
            master = p
            // Wait for the control socket (or an early exit).
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(250))
                if !p.isRunning { break }
                if await check() {
                    for (local, remote) in forwards { try? await addForward(local: local, remote: remote) }
                    return
                }
            }
            if p.isRunning { p.terminate() }
            lastError = ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Fresh machines answer "sandbox_restoring" / refuse for a few seconds.
            try await Task.sleep(for: .seconds(Double(attempt) * 1.5))
        }
        master = nil
        throw HostError("Couldn't connect to \(alias) over SSH\(lastError.isEmpty ? "" : ": \(lastError.suffix(400))")")
    }

    /// True if a master is alive on the control socket.
    public func check() async -> Bool {
        guard let e = endpoint, FileManager.default.fileExists(atPath: controlPath) else { return false }
        let r = try? await Shell.runRaw(
            "/usr/bin/ssh", baseOptions(e) + ["-O", "check", e.destination], cwd: nil, env: ProcessInfo.processInfo.environment)
        return r?.succeeded == true
    }

    public func closeMaster() {
        if let e = endpoint {
            // Best effort: ask the master to exit (works for one started by another window too).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = baseOptions(e) + ["-O", "exit", e.destination]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
        if let master, master.isRunning { master.terminate() }
        master = nil
    }

    // MARK: port forwarding

    public var activeForwards: [Int: Int] { forwards }

    /// Forward 127.0.0.1:`local` on this Mac to 127.0.0.1:`remote` on the machine.
    public func forward(local: Int, remote: Int) async throws {
        try await connect()
        try await addForward(local: local, remote: remote)
        forwards[local] = remote
    }

    public func cancelForward(local: Int) async {
        guard let remote = forwards.removeValue(forKey: local), let e = endpoint else { return }
        _ = try? await Shell.runRaw(
            "/usr/bin/ssh", baseOptions(e) + ["-O", "cancel", "-L", "127.0.0.1:\(local):127.0.0.1:\(remote)", e.destination],
            cwd: nil, env: ProcessInfo.processInfo.environment)
    }

    public func cancelAllForwards() async {
        for local in Array(forwards.keys) { await cancelForward(local: local) }
    }

    private func addForward(local: Int, remote: Int) async throws {
        guard let e = endpoint else { throw HostError("Not connected") }
        let r = try await Shell.runRaw(
            "/usr/bin/ssh", baseOptions(e) + ["-O", "forward", "-L", "127.0.0.1:\(local):127.0.0.1:\(remote)", e.destination],
            cwd: nil, env: ProcessInfo.processInfo.environment)
        if !r.succeeded {
            let msg = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostError("Couldn't forward port \(local)\(msg.isEmpty ? "" : ": \(msg)")")
        }
    }

    /// True if nothing on this Mac is bound to `port` on loopback.
    public nonisolated static func isLocalPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }
}
