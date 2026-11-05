import DQCore
import Darwin
import Foundation
import Observation

/// Process-wide monotonic log line ids, so lines from several TaskRuns can be merged in arrival order.
public enum LogLineIDs {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter = 0

    public static func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }
}

public struct LogLine: Identifiable, Sendable, Hashable {
    public let id: Int
    public let raw: String
    public let segments: [ANSISegment]
    /// ANSI-stripped text.
    public let text: String

    public init(id: Int, raw: String) {
        self.id = id
        self.raw = raw
        let segs = ANSI.parse(raw)
        self.segments = segs
        self.text = segs.map(\.text).joined()
    }
}

public enum TaskRunState: Sendable, Hashable {
    case idle
    case starting
    case running(pid: Int32)
    /// Service is up (ready port listening / ready pattern matched).
    case ready
    case succeeded
    case failed(exitCode: Int32)
    case stopped

    public var isActive: Bool {
        switch self {
        case .starting, .running, .ready: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting"
        case .running: "Running"
        case .ready: "Ready"
        case .succeeded: "Passed"
        case .failed(let code): "Failed (\(code))"
        case .stopped: "Stopped"
        }
    }
}

/// One task (service or one-shot) with live, observable state and logs.
@MainActor @Observable
public final class TaskRun: Identifiable {
    public static let maxLines = 5_000

    public let id: String
    public let name: String
    public let kind: TaskConfig.Kind
    public let command: String
    public private(set) var config: TaskConfig

    public private(set) var state: TaskRunState = .idle
    public private(set) var lines: [LogLine] = []
    /// Listening TCP ports of the process tree, refreshed while running.
    public private(set) var ports: [Int] = []
    public private(set) var openURL: URL?
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var exitCode: Int32?
    /// Last spawn error, if starting failed.
    public private(set) var spawnError: String?

    public var pid: Int32? { process?.pid }

    @ObservationIgnored private let workspacePath: String
    @ObservationIgnored private var environment: [String: String]
    @ObservationIgnored private var process: PTYProcess?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var killTask: Task<Void, Never>?
    @ObservationIgnored private var readyRegex: NSRegularExpression?
    @ObservationIgnored private var readyPort: Int?
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []

    /// - Parameters:
    ///   - environment: full environment (login env + workspace vars). `config.env` is expanded against it and merged on top.
    public init(config: TaskConfig, workspacePath: String, environment: [String: String]) {
        self.id = config.id
        self.name = config.name
        self.kind = config.kind
        self.command = config.command
        self.config = config
        self.workspacePath = workspacePath
        self.environment = environment
        recomputeDerived()
    }

    // MARK: lifecycle

    public func start() {
        guard !state.isActive else { return }
        lines.removeAll()
        ports = []
        stopRequested = false
        spawnError = nil
        exitCode = nil
        endedAt = nil
        startedAt = .now
        state = .starting
        generation += 1
        let gen = generation

        let env = mergedEnvironment()
        let cwd = config.cwd.map { ($0 as NSString).isAbsolutePath ? $0 : (workspacePath as NSString).appendingPathComponent($0) }
            ?? workspacePath
        let shell = Self.shell(from: env)
        do {
            let proc = try PTYProcess(
                shell: shell, command: command, cwd: cwd, environment: env, firstLineID: gen << 32,
                onBatch: { [weak self] batch in
                    Task { @MainActor in self?.apply(batch, generation: gen) }
                },
                onExit: { [weak self] code in
                    Task { @MainActor in self?.handleExit(code, generation: gen) }
                })
            process = proc
            state = .running(pid: proc.pid)
            startPolling(pid: proc.pid, generation: gen)
        } catch {
            spawnError = error.localizedDescription
            appendSystemLine("Failed to start: \(error.localizedDescription)")
            state = .failed(exitCode: -1)
            endedAt = .now
            resumeWaiters(false)
        }
    }

    /// SIGTERM to the process group, SIGKILL after 3s.
    public func stop() {
        guard let process, state.isActive else { return }
        stopRequested = true
        process.signalGroup(SIGTERM)
        killTask?.cancel()
        killTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if process.groupAlive { process.signalGroup(SIGKILL) }
        }
    }

    public func restart() {
        guard state.isActive, let process else {
            start()
            return
        }
        stop()
        Task { [weak self] in
            // Wait for the old process to exit (bounded), then start again.
            for _ in 0..<80 {
                guard let self else { return }
                if !self.state.isActive { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.groupAlive { process.signalGroup(SIGKILL) }
            self?.start()
        }
    }

    /// Synchronous SIGKILL of the whole group (app termination).
    public func killNow() {
        guard let process, state.isActive else { return }
        stopRequested = true
        process.signalGroup(SIGKILL)
    }

    /// Suspends until the run finishes. Returns true on success (oneshot exit 0 / service stopped cleanly).
    public func waitUntilFinished() async -> Bool {
        if !state.isActive {
            return state == .succeeded || state == .stopped
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    public func clearLog() {
        lines.removeAll()
    }

    public func fullLogText() -> String { lines.map(\.text).joined(separator: "\n") }

    /// Last `n` stripped lines (for "send logs to agent").
    public func tail(_ n: Int) -> String { lines.suffix(n).map(\.text).joined(separator: "\n") }

    /// Replace environment / config (e.g. after domestique.toml changed). Takes effect on next start.
    public func update(config: TaskConfig? = nil, environment: [String: String]? = nil) {
        if let config { self.config = config }
        if let environment { self.environment = environment }
        recomputeDerived()
    }

    // MARK: internals

    private func recomputeDerived() {
        let env = mergedEnvironment()
        openURL = config.open.flatMap { URL(string: WorkspaceEnvironment.expand($0, env)) }
        readyPort = config.readyPort.flatMap { Int(WorkspaceEnvironment.expand($0, env).trimmingCharacters(in: .whitespaces)) }
        readyRegex = config.readyPattern.flatMap { try? NSRegularExpression(pattern: $0) }
    }

    private func mergedEnvironment() -> [String: String] {
        var env = environment
        for (k, v) in config.env { env[k] = WorkspaceEnvironment.expand(v, environment) }
        env["TERM"] = "xterm-256color"
        env["FORCE_COLOR"] = env["FORCE_COLOR"] ?? "1"
        env["CLICOLOR_FORCE"] = "1"
        env["CLICOLOR"] = "1"
        env.removeValue(forKey: "NO_COLOR")
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" }
        return env
    }

    static func shell(from env: [String: String]) -> String {
        if let s = env["SHELL"], s.hasSuffix("/zsh") || s.hasSuffix("/bash"), FileManager.default.isExecutableFile(atPath: s) {
            return s
        }
        return "/bin/zsh"
    }

    private func apply(_ batch: LogBatch, generation gen: Int) {
        guard gen == generation else { return }
        // Edits only ever touch the live tail, so search a bounded window from the end.
        let window = LogScreen.liveRows + 64
        for line in batch.upserts {
            let lower = max(0, lines.count - window)
            if let i = lines[lower...].lastIndex(where: { $0.id == line.id }) {
                lines[i] = line
            } else {
                lines.append(line)
            }
        }
        if !batch.removed.isEmpty {
            let gone = Set(batch.removed)
            let lower = max(0, lines.count - window)
            let tail = lines[lower...].filter { !gone.contains($0.id) }
            lines.replaceSubrange(lower..., with: tail)
        }
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
        if let readyRegex, kind == .service, case .running = state {
            for line in batch.upserts {
                let range = NSRange(line.text.startIndex..., in: line.text)
                if readyRegex.firstMatch(in: line.text, range: range) != nil {
                    state = .ready
                    break
                }
            }
        }
    }

    private func handleExit(_ code: Int32, generation gen: Int) {
        guard gen == generation else { return }
        pollTask?.cancel()
        pollTask = nil
        killTask?.cancel()
        killTask = nil
        exitCode = code
        endedAt = .now
        ports = []
        let success: Bool
        if stopRequested {
            state = .stopped
            success = true
        } else if kind == .oneshot {
            state = code == 0 ? .succeeded : .failed(exitCode: code)
            success = code == 0
        } else {
            state = code == 0 ? .stopped : .failed(exitCode: code)
            success = code == 0
        }
        if let process, kind == .service, process.groupAlive {
            // Leader died; don't leave orphaned dev servers holding ports.
            process.signalGroup(SIGTERM)
        }
        resumeWaiters(success)
    }

    private func resumeWaiters(_ value: Bool) {
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume(returning: value) }
    }

    private func appendSystemLine(_ text: String) {
        lines.append(LogLine(id: LogLineIDs.next(), raw: text))
    }

    private func startPolling(pid: Int32, generation gen: Int) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                let readyPort = self?.readyPort
                let (found, readyHit) = await Task.detached(priority: .utility) { () -> ([Int], Bool) in
                    let ports = PortScanner.listeningPorts(rootPID: pid)
                    // Fall back to a connect probe: some servers (docker, proxies) listen outside the tree.
                    let hit = readyPort.map { ports.contains($0) || PortScanner.isPortListening($0) } ?? false
                    return (ports, hit)
                }.value
                guard let self, gen == self.generation, self.state.isActive else { return }
                if found != self.ports { self.ports = found }
                if readyHit, case .running = self.state {
                    self.state = .ready
                }
                tick += 1
                // Fast while waiting to be ready, slower once settled.
                let waitingForReady = self.readyPort != nil && self.state != .ready
                try? await Task.sleep(for: .milliseconds(waitingForReady || tick < 10 ? 500 : 2_000))
            }
        }
    }
}
