import DQCore
import Foundation

/// Receives notifications / server requests for one Codex thread.
protocol CodexThreadHandler: AnyObject, Sendable {
    func handleNotification(method: String, params: JSONValue) async
    /// Return the JSON-RPC `result` for a server-initiated request (approvals etc).
    func handleServerRequest(method: String, params: JSONValue) async -> JSONValue?
    func serverExited(message: String?) async
}

/// One `codex app-server` process (JSON-RPC over stdio) per host, shared by every Codex tab on it.
/// Locally it uses the user's existing ChatGPT login from ~/.codex; on a cloud machine, the provider's.
public actor CodexAppServer {
    public static let shared = CodexAppServer(host: LocalHost.shared)

    nonisolated(unsafe) private static var byHost: [String: CodexAppServer] = [:]
    private static let registryLock = NSLock()

    /// The app-server for `host` (started lazily).
    public static func server(for host: any ExecutionHost) -> CodexAppServer {
        if host.isLocal { return shared }
        return registryLock.withLock {
            if let s = byHost[host.id] { return s }
            let s = CodexAppServer(host: host)
            byHost[host.id] = s
            return s
        }
    }

    /// Every remote app-server started so far (shutdown).
    public static var remoteServers: [CodexAppServer] { registryLock.withLock { Array(byHost.values) } }

    private let host: any ExecutionHost

    private var process: LineProcess?
    private var readerTask: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var handlers: [String: WeakHandler] = [:]
    private var starting: Task<Void, Error>?
    private var cachedModels: [ModelOption]?
    /// Account-level usage updates (not tied to a thread).
    public nonisolated let rateLimits: AsyncStream<RateLimitInfo>
    private let rateLimitContinuation: AsyncStream<RateLimitInfo>.Continuation

    init(host: any ExecutionHost) {
        self.host = host
        (rateLimits, rateLimitContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    private struct WeakHandler {
        weak var value: (any CodexThreadHandler)?
    }

    // MARK: lifecycle

    func ensureRunning() async throws {
        if let process, process.isRunning { return }
        if let starting { return try await starting.value }
        let task = Task { try await self.start() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func start() async throws {
        try await host.prepare()
        let home = host.isLocal ? FileManager.default.homeDirectoryForCurrentUser.path : "/tmp"
        let cmd = try await host.command("codex", ["app-server"], cwd: home, env: [:], tty: false)
        let proc = LineProcess(executable: cmd.executable, arguments: cmd.arguments, cwd: cmd.cwd, environment: cmd.environment)
        try proc.start { [weak self] status, stderr in
            Task { await self?.exited(status: status, stderr: stderr) }
        }
        process = proc
        readerTask = Task { [weak self] in
            for await line in proc.lines { await self?.handle(line: line) }
        }
        _ = try await rawRequest(
            "initialize",
            [
                "clientInfo": ["name": "domestique", "title": "Domestique", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true],
            ])
        proc.write(["method": "initialized"])
    }

    private func exited(status: Int32, stderr: String) async {
        process = nil
        for (_, c) in pending { c.resume(throwing: AgentError("codex app-server exited")) }
        pending.removeAll()
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = handlers.values.compactMap(\.value)
        handlers.removeAll()
        for h in live { await h.serverExited(message: status == 0 ? nil : (msg.isEmpty ? "codex exited (\(status))" : String(msg.suffix(2000)))) }
    }

    public func shutdown() {
        process?.closeInput()
        process?.terminate()
        process = nil
    }

    // MARK: requests

    func register(threadID: String, handler: any CodexThreadHandler) {
        handlers[threadID] = WeakHandler(value: handler)
    }

    func unregister(threadID: String) {
        handlers[threadID] = nil
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await ensureRunning()
        return try await rawRequest(method, params)
    }

    private func rawRequest(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let process else { throw AgentError("codex app-server isn't running") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            process.write(["id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    public func listModels() async throws -> [ModelOption] {
        if let cachedModels { return cachedModels }
        let result = try await request("model/list", [:])
        let models = (result["data"]?.array ?? []).compactMap { m -> ModelOption? in
            if m["hidden"]?.bool == true { return nil }
            guard let id = m["id"]?.string ?? m["model"]?.string else { return nil }
            let efforts = (m["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string }
            return ModelOption(
                id: id, displayName: m["displayName"]?.string ?? id, description: m["description"]?.string,
                efforts: efforts, defaultEffort: m["defaultReasoningEffort"]?.string,
                isDefault: m["isDefault"]?.bool ?? false)
        }
        cachedModels = models
        return models
    }

    // MARK: inbound

    private func handle(line: Data) async {
        guard let msg = try? JSONValue.parse(line) else { return }
        let method = msg["method"]?.string
        let idValue = msg["id"]

        if let method, let idValue {
            // Server -> client request.
            // Server -> client request. Approvals can wait on the user for minutes, so never block the reader.
            let params = msg["params"] ?? .null
            let handler = params["threadId"]?.string.flatMap { handlers[$0]?.value }
            let proc = process
            Task {
                let result = await handler?.handleServerRequest(method: method, params: params)
                if let result {
                    proc?.write(["id": idValue, "result": result])
                } else {
                    proc?.write(["id": idValue, "error": ["code": -32601, "message": "Unsupported by Domestique"]])
                }
            }
            return
        }
        if method == "account/rateLimits/updated" {
            let limits = msg["params"]?["rateLimits"]
            var windows: [RateLimitWindow] = []
            for key in ["primary", "secondary"] {
                guard let w = limits?[key], let pct = w["usedPercent"]?.double else { continue }
                let mins = w["windowDurationMins"]?.int
                windows.append(
                    RateLimitWindow(
                        id: key, label: RateLimitInfo.windowLabel(minutes: mins),
                        duration: RateLimitInfo.duration(minutes: mins), usedFraction: pct / 100,
                        resetsAt: w["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) }))
            }
            if !windows.isEmpty {
                rateLimitContinuation.yield(RateLimitInfo(windows: windows, plan: limits?["planType"]?.string))
            }
            return
        }
        if let method {
            let params = msg["params"] ?? .null
            if let tid = params["threadId"]?.string ?? params["thread"]?["id"]?.string,
                let handler = handlers[tid]?.value
            {
                await handler.handleNotification(method: method, params: params)
            }
            return
        }
        if let id = idValue?.int, let cont = pending.removeValue(forKey: id) {
            if let err = msg["error"] {
                cont.resume(throwing: AgentError(err["message"]?.string ?? "codex error"))
            } else {
                cont.resume(returning: msg["result"] ?? .null)
            }
        }
    }
}
