import DQCore
import Darwin
import Foundation
import Observation

/// All tasks for one workspace: configured tasks, setup, and ad-hoc one-shots.
@MainActor @Observable
public final class TaskSupervisor {
    public let workspacePath: String
    public private(set) var config: RepoConfig
    /// Full environment (login env + workspace vars) given to every run.
    public private(set) var environment: [String: String]

    /// One run per configured task, in config order.
    public private(set) var runs: [TaskRun] = []
    public private(set) var setupRun: TaskRun?
    /// Ad-hoc one-shots (archive script, trunk gate, ...), newest last.
    public private(set) var adhocRuns: [TaskRun] = []

    /// Where tasks run.
    public let host: any ExecutionHost

    /// Remote hosts only: every TCP port listening on the machine, from the last probe.
    public private(set) var remoteListening: [Int] = []
    /// Remote hosts only: ports already listening before Domestique started anything (system services).
    public private(set) var remoteBaseline: Set<Int>?
    /// Probe faster (the workspace is on screen).
    @ObservationIgnored public var isFocused = false
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    public init(
        workspacePath: String, config: RepoConfig, environment: [String: String], host: any ExecutionHost = LocalHost.shared
    ) {
        self.workspacePath = workspacePath
        self.config = config
        self.environment = environment
        self.host = host
        self.runs = config.tasks.map { TaskRun(config: $0, workspacePath: workspacePath, environment: environment, host: host) }
        if !host.isLocal { startRemoteProbe() }
    }

    /// Ports listening on a remote host that Domestique (or the agent) started: everything not in the baseline.
    public var remoteAppPorts: [Int] {
        guard let base = remoteBaseline else { return [] }
        return remoteListening.filter { !base.contains($0) }
    }

    // MARK: remote ports

    private func startRemoteProbe() {
        probeTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                let host = self.host
                let result = await Task.detached { try? await RemotePortProbe.probe(host) }.value
                if let result {
                    failures = 0
                    self.applyProbe(result)
                } else {
                    failures += 1
                }
                let waitingForReady = self.allRuns.contains { if case .running = $0.state { true } else { false } }
                let seconds: Double =
                    failures > 0 ? min(30, 3 * Double(failures))
                    : (waitingForReady ? 1 : (self.isFocused ? 3 : 10))
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// Run a probe now (e.g. right after a task started).
    public func probeNow() {
        let host = self.host
        guard !host.isLocal else { return }
        Task {
            if let result = try? await RemotePortProbe.probe(host) { self.applyProbe(result) }
        }
    }

    private func applyProbe(_ r: RemotePortProbe.Result) {
        if remoteBaseline == nil {
            // First look at the machine: anything a Domestique run doesn't own is a system service.
            let owned = Set(r.byRun.values.flatMap { $0 })
            remoteBaseline = r.listening.subtracting(owned)
        }
        let sorted = r.listening.sorted()
        if sorted != remoteListening { remoteListening = sorted }
        for run in allRuns {
            run.applyRemotePorts((r.byRun[run.remoteKey] ?? []).sorted(), listening: r.listening)
        }
    }

    private var allRuns: [TaskRun] { runs + adhocRuns + [setupRun].compactMap { $0 } }

    public func stopProbing() {
        probeTask?.cancel()
        probeTask = nil
    }

    public func task(_ id: String) -> TaskRun? { runs.first { $0.id == id } }

    public var anyRunning: Bool {
        runs.contains { $0.state.isActive } || (setupRun?.state.isActive ?? false)
            || adhocRuns.contains { $0.state.isActive }
    }

    /// Every listening port across running tasks.
    public var allPorts: [Int] { Array(Set(runs.flatMap(\.ports))).sorted() }

    // MARK: tasks

    /// Starts the task (no-op if already running).
    public func run(_ taskID: String) { task(taskID)?.start() }

    public func stop(_ taskID: String) { task(taskID)?.stop() }

    public func restart(_ taskID: String) { task(taskID)?.restart() }

    public func startStack(_ stackID: String) {
        guard let stack = config.stacks.first(where: { $0.id == stackID }) else { return }
        for id in stack.tasks { run(id) }
    }

    public func stopStack(_ stackID: String) {
        guard let stack = config.stacks.first(where: { $0.id == stackID }) else { return }
        for id in stack.tasks { stop(id) }
    }

    public func isStackRunning(_ stackID: String) -> Bool {
        guard let stack = config.stacks.first(where: { $0.id == stackID }) else { return false }
        return stack.tasks.contains { task($0)?.state.isActive ?? false }
    }

    public func stopAll() {
        for r in runs { r.stop() }
        setupRun?.stop()
        for r in adhocRuns { r.stop() }
    }

    /// Synchronous SIGKILL of every process group (call from applicationWillTerminate).
    public func shutdownNow() {
        for r in runs { r.killNow() }
        setupRun?.killNow()
        for r in adhocRuns { r.killNow() }
    }

    // MARK: setup / one-shots

    /// Copies `copyFiles` from `rootPath` (skipping missing files, never overwriting), then runs
    /// `script` as a one-shot "Setup" run. Returns true on success (or when there's nothing to run).
    @discardableResult
    public func runSetup(script: String?, copyFiles: [String], from rootPath: String) async -> Bool {
        let copied =
            host.isLocal
            ? Self.copyFiles(copyFiles, from: rootPath, to: workspacePath)
            : await Self.uploadFiles(copyFiles, from: rootPath, to: workspacePath, host: host)
        let trimmed = script?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notes = copied.map { "printf '%s\\n' \(Self.shellQuote("Copied \($0)"))" }
        guard !trimmed.isEmpty || !notes.isEmpty else { return true }
        let command = (notes + (trimmed.isEmpty ? [] : [trimmed])).joined(separator: "\n")
        let run = TaskRun(
            config: TaskConfig(id: "__setup", name: "Setup", command: command, kind: .oneshot),
            workspacePath: workspacePath, environment: environment, host: host)
        setupRun = run
        run.start()
        return await run.waitUntilFinished()
    }

    /// Runs an ad-hoc command as a one-shot. Await `waitUntilFinished()` on the result for the outcome.
    @discardableResult
    public func runOneshot(name: String, command: String) -> TaskRun {
        let run = TaskRun(
            config: TaskConfig(id: "__adhoc-\(UUID().uuidString.prefix(8))", name: name, command: command, kind: .oneshot),
            workspacePath: workspacePath, environment: environment, host: host)
        adhocRuns.append(run)
        if adhocRuns.count > 20 {
            adhocRuns.removeAll { !$0.state.isActive && adhocRuns.count > 20 }
        }
        run.start()
        return run
    }

    /// Reload after domestique.toml changed. Keeps runs (and their logs/processes) for tasks that still exist.
    public func update(config: RepoConfig) {
        self.config = config
        var next: [TaskRun] = []
        for t in config.tasks {
            if let existing = runs.first(where: { $0.id == t.id }) {
                existing.update(config: t)
                next.append(existing)
            } else {
                next.append(TaskRun(config: t, workspacePath: workspacePath, environment: environment, host: host))
            }
        }
        for removed in runs where !config.tasks.contains(where: { $0.id == removed.id }) {
            removed.stop()
        }
        runs = next
    }

    public func update(environment: [String: String]) {
        self.environment = environment
        for r in runs { r.update(environment: environment) }
    }

    // MARK: helpers

    /// Returns the relative paths actually copied.
    static func copyFiles(_ files: [String], from root: String, to dest: String) -> [String] {
        let fm = FileManager.default
        var copied: [String] = []
        for rel in expandGlobs(files, root: root) {
            let src = (root as NSString).appendingPathComponent(rel)
            let dst = (dest as NSString).appendingPathComponent(rel)
            guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) else { continue }
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if (try? fm.copyItem(atPath: src, toPath: dst)) != nil { copied.append(rel) }
        }
        return copied
    }

    /// `copyFiles` for a remote host: local main checkout -> the machine (never overwriting).
    static func uploadFiles(_ files: [String], from root: String, to dest: String, host: any ExecutionHost) async -> [String] {
        var copied: [String] = []
        for rel in expandGlobs(files, root: root) {
            let src = (root as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: src, isDirectory: &isDir), !isDir.boolValue,
                let data = FileManager.default.contents(atPath: src)
            else { continue }
            let dst = (dest as NSString).appendingPathComponent(rel)
            if await host.fileExists(dst) { continue }
            if (try? await host.writeFile(dst, data: data)) != nil { copied.append(rel) }
        }
        return copied
    }

    /// Expands `*`, `?` and `[…]` in the last path component against `root` (no `**`).
    static func expandGlobs(_ patterns: [String], root: String) -> [String] {
        var out: [String] = []
        for pattern in patterns {
            let last = (pattern as NSString).lastPathComponent
            guard last.contains(where: { "*?[".contains($0) }) else {
                out.append(pattern)
                continue
            }
            let dir = (pattern as NSString).deletingLastPathComponent
            let abs = dir.isEmpty ? root : (root as NSString).appendingPathComponent(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: abs)) ?? []
            for name in names.sorted() where fnmatch(last, name, 0) == 0 {
                out.append(dir.isEmpty ? name : (dir as NSString).appendingPathComponent(name))
            }
        }
        return out
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
