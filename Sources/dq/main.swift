import AgentKit
import DQCore
import Foundation
import GitKit
import HostKit
import ProcessKit

// dq — headless harness for the agent layer.
//
//   dq chat <claude|codex> [--mode bypass|auto|ask] [--model m] [--cwd dir] [--resume id] [--approve] "prompt" ["follow-up" ...]
//   dq models <claude|codex>
//   dq chat … --boat bx_… runs the agent inside a boat.dev sandbox (--cwd is a path there)
//   dq boat <bx_id> status|exec <cmd>|probe|diff <repo-path>|task <cmd>|forward <port>
//
// Each prompt is sent after the previous turn ends. With --approve, approval requests are auto-approved;
// otherwise they're denied. Prints a compact event log plus the session id for --resume.

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var provider: ProviderKind = .claude
    var mode: AgentPermissionMode = .bypass
    var model: String?
    var cwd = FileManager.default.currentDirectoryPath
    var resume: String?
    var approve = false
    var interruptAfter: Double?
    var boat: String?
    var prompts: [String] = []
}

func parse(_ args: ArraySlice<String>) -> Options {
    var o = Options()
    var it = args.makeIterator()
    if let p = it.next() { o.provider = ProviderKind(rawValue: p) ?? .claude }
    while let a = it.next() {
        switch a {
        case "--mode": o.mode = AgentPermissionMode(rawValue: it.next() ?? "") ?? .bypass
        case "--model": o.model = it.next()
        case "--cwd": o.cwd = it.next() ?? o.cwd
        case "--resume": o.resume = it.next()
        case "--approve": o.approve = true
        case "--interrupt-after": o.interruptAfter = Double(it.next() ?? "")
        case "--boat": o.boat = it.next()
        default: o.prompts.append(a)
        }
    }
    return o
}

func short(_ s: String, _ n: Int = 160) -> String {
    let one = s.replacingOccurrences(of: "\n", with: "⏎")
    return one.count > n ? String(one.prefix(n)) + "…" : one
}

func chat(_ o: Options) async throws {
    let session = AgentFactory.makeSession(
        provider: o.provider,
        config: AgentSessionConfig(
            cwd: o.cwd, model: o.model, permissionMode: o.mode, resumeSessionID: o.resume,
            host: o.boat.map { Hosts.boatHost($0) } ?? LocalHost.shared))
    let start = Date()
    var prompts = o.prompts[...]
    guard let first = prompts.popFirst() else { print("no prompt"); return }
    func t() -> String { String(format: "%6.2fs", Date().timeIntervalSince(start)) }

    print("\(t()) → \(first)")
    try await session.send(first, attachments: [])
    if let after = o.interruptAfter {
        Task {
            try? await Task.sleep(for: .seconds(after))
            print("\(t()) ✋ interrupt")
            await session.interrupt()
        }
    }
    var streamed: [String: Int] = [:]
    var sessionID: String?
    for await event in session.events {
        switch event {
        case .started(let id, let model):
            sessionID = id
            print("\(t()) ● session \(id) model=\(model ?? "-")")
        case .upsert(let item):
            switch item.kind {
            case .assistant(let text): if !text.isEmpty { print("\(t()) ◆ assistant[\(item.id.suffix(6))] \(short(text))") }
            case .reasoning(let text): if !text.isEmpty { print("\(t()) ∴ reasoning \(short(text, 80))") }
            case .tool(let call):
                print("\(t()) ⚙ \(call.name) [\(call.status.rawValue)] \(short(call.summary, 100))\(call.output.isEmpty ? "" : " → " + short(call.output, 80))\(call.fileChanges.isEmpty ? "" : " (\(call.fileChanges.count) file diffs)")")
            case .approval(let req):
                print("\(t()) ? \(req.title) [\(req.resolution.rawValue)] \(short(req.detail, 100))")
                if req.resolution == .pending {
                    if req.isQuestion {
                        var answers: [String: String] = [:]
                        for q in req.questions { answers[q.id] = q.options.first?.label ?? "yes" }
                        await session.answer(requestID: req.requestID, answers: answers)
                    } else {
                        await session.respond(requestID: req.requestID, decision: o.approve ? .approve : .deny(message: "Denied by dq"))
                    }
                }
            case .notice(let text): print("\(t()) ℹ \(text)")
            case .error(let text): print("\(t()) ✖ \(text)")
            case .user(let text): print("\(t()) user \(short(text))")
            case .turnSummary: break
            case .trigger(let text): print("\(t()) ↻ \(text)")
            }
        case .appendText(let id, let delta):
            streamed[id, default: 0] += delta.count
        case .turnStarted:
            print("\(t()) ▶ turn")
        case .turnEnded(let s):
            print("\(t()) ■ turn ended error=\(s.isError) \(s.message ?? "") dur=\(s.durationMs ?? -1)ms cost=\(s.costUSD.map { String(format: "$%.4f", $0) } ?? "-") in=\(s.inputTokens ?? 0) out=\(s.outputTokens ?? 0) streamedChars=\(streamed.values.reduce(0, +))")
            if let next = prompts.popFirst() {
                print("\(t()) → \(next)")
                try await session.send(next, attachments: [])
            } else {
                print("SESSION_ID=\(sessionID ?? "")")
                await session.shutdown()
                if o.provider == .codex {
                    await CodexAppServer.shared.shutdown()
                    for s in CodexAppServer.remoteServers { await s.shutdown() }
                }
                return
            }
        case .status(let s): if let s { print("\(t()) … \(s)") }
        case .models(let m): print("\(t()) models: \(m.map(\.id).joined(separator: ", "))")
        case .task(let task): print("\(t()) ◇ agent \(task.description) [\(task.status.rawValue)] tools=\(task.toolUses) steps=\(task.steps.count) \(task.activity ?? "")")
        case .autoTurnStarted(let reason): print("\(t()) ↻ auto turn: \(reason)")
        case .rateLimit(let r): print("\(t()) ◔ \(r.window) \(Int(r.usedFraction * 100))% used")
        case .exited(let msg):
            print("\(t()) ✖ exited \(msg ?? "")")
            return
        }
    }
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "chat":
    try await chat(parse(args.dropFirst()))
case "config":
    // dq config <dir>: parse and print a domestique.toml
    let dir = args.dropFirst().first ?? FileManager.default.currentDirectoryPath
    do {
        guard let cfg = try RepoConfig.load(directory: dir) else { print("no \(RepoConfig.fileName) in \(dir)"); break }
        print("setup: \(cfg.setupScript ?? "-")  copy: \(cfg.copyFiles)  archive: \(cfg.archiveScript ?? "-")")
        for t in cfg.tasks { print("task \(t.id) [\(t.kind)] \(t.name): \(t.command)  ready=\(t.readyPort ?? "-") open=\(t.open ?? "-")") }
        for s in cfg.stacks { print("stack \(s.id) \(s.name): \(s.tasks)") }
    } catch {
        print("error: \(error.localizedDescription)")
    }
case "boat":
    try await boat(Array(args.dropFirst()))
case "models":
    let p = ProviderKind(rawValue: args.dropFirst().first ?? "claude") ?? .claude
    for m in await AgentFactory.defaultModels(p) { print("\(m.id)\t\(m.displayName)") }
    await CodexAppServer.shared.shutdown()
default:
    print("usage: dq chat <claude|codex> [--mode bypass|auto|ask] [--approve] [--model m] [--cwd dir] [--resume id] prompt...")
}

@MainActor
func boat(_ a: [String]) async throws {
    guard a.count >= 2 else { print("usage: dq boat <bx_id> status|exec|probe|diff|task|forward"); return }
    let host = Hosts.boatHost(a[0])
    let rest = a.dropFirst(2).joined(separator: " ")
    let t0 = Date()
    func t() -> String { String(format: "%6.2fs", Date().timeIntervalSince(t0)) }
    await host.setObserver { s in print("  state \(s.state) archiveAfter=\(s.archiveAfter.map { "\($0)" } ?? "never")") }
    try await host.prepare()
    print("\(t()) prepared")
    switch a[1] {
    case "status":
        let s = try await BoatClient.shared.sandbox(a[0])
        print(s)
    case "exec":
        let r = try await host.runScript(rest, cwd: "/home/user", check: false)
        print("\(t()) exit=\(r.status)\n\(r.stdout)\(r.stderr)")
        let r2 = try await host.runScript("true", cwd: "/home/user", check: false)
        print("\(t()) second exec exit=\(r2.status)")
    case "probe":
        let r = try await RemotePortProbe.probe(host)
        print("\(t()) listening=\(r.listening.sorted()) byRun=\(r.byRun)")
    case "diff":
        let files = try await Git.diff(path: rest, base: "origin/master", host: host)
        print("\(t()) \(files.count) changed: \(files.map { "\($0.path) +\($0.additions)-\($0.deletions)" })")
        let list = try await Git.listFiles(path: rest, host: host)
        print("\(t()) \(list.count) files")
    case "task":
        // Runs a service remotely under a PTY, waits for a port, forwards it, curls it, stops it.
        let cfg = TaskConfig(id: "probe-task", name: "Probe", command: rest, kind: .service, readyPort: "41005")
        let sup = TaskSupervisor(workspacePath: "/home/user", config: RepoConfig(tasks: [cfg]), environment: ["DOMESTIQUE_PORT": "41005"], host: host)
        sup.isFocused = true
        let run = sup.task("probe-task")!
        run.start()
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            if run.state == .ready || !run.state.isActive { break }
        }
        print("\(t()) state=\(run.state.label) ports=\(run.ports) baseline=\(sup.remoteBaseline?.sorted() ?? []) app=\(sup.remoteAppPorts)")
        print("log: \(run.tail(5))")
        if let p = run.ports.first {
            try await host.ssh.forward(local: p, remote: p)
            let r = try await Shell.runRaw("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:\(p)/"], cwd: nil, env: [:])
            print("\(t()) forwarded :\(p) -> local http \(r.stdout)")
            await host.ssh.cancelForward(local: p)
        }
        run.stop()
        _ = await run.waitUntilFinished()
        try await Task.sleep(for: .seconds(1))
        let after = try await RemotePortProbe.probe(host)
        print("\(t()) after stop: state=\(run.state.label) still listening on 41005: \(after.listening.contains(41005))")
    default:
        print("unknown boat command")
    }
    await host.disconnect()
}
