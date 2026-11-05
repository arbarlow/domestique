import DQCore
import Foundation

/// Receives notifications / server requests for one Codex thread.
protocol CodexThreadHandler: AnyObject, Sendable {
    func handleNotification(method: String, params: JSONValue) async
    /// Return the JSON-RPC `result` for a server-initiated request (approvals etc).
    func handleServerRequest(method: String, params: JSONValue) async -> JSONValue?
    func serverExited(message: String?) async
}

/// One shared `codex app-server` process (JSON-RPC over stdio) for every Codex tab.
/// Uses the user's existing ChatGPT login from ~/.codex.
public actor CodexAppServer {
    public static let shared = CodexAppServer()

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

    init() {
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
        let exe = try await LoginEnvironment.shared.resolve("codex")
        let env = await LoginEnvironment.shared.environment()
        let proc = LineProcess(
            executable: exe, arguments: ["app-server"], cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            environment: env)
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
