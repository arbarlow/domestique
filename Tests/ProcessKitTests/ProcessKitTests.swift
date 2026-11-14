import DQCore
import Darwin
import Foundation
import Testing

@testable import ProcessKit

@Suite struct RemoteBaselineTests {
    @Test func workspacePortsAreNeverSystemPorts() {
        // Backend and frontend were already up on the first probe, in the workspace's block.
        let system = TaskSupervisor.systemPorts(listening: [22, 51000, 51001, 51010], owned: [], portBase: 51000)
        #expect(system == [22, 51010])
    }

    @Test func ownedPortsAreExcludedWithoutAPortBase() {
        #expect(TaskSupervisor.systemPorts(listening: [22, 3000], owned: [3000], portBase: nil) == [22])
    }
}

@Suite struct ANSITests {
    @Test func parsesSGR() {
        let segs = ANSI.parse("\u{1B}[1;31mred\u{1B}[0m plain \u{1B}[32mgreen\u{1B}[39m")
        #expect(segs.count == 3)
        #expect(segs[0] == ANSISegment(text: "red", foreground: .red, bold: true))
        #expect(segs[1] == ANSISegment(text: " plain "))
        #expect(segs[2] == ANSISegment(text: "green", foreground: .green))
    }

    @Test func extendedColorsAndDim() {
        let segs = ANSI.parse("\u{1B}[38;5;196mx\u{1B}[0m\u{1B}[2;38;2;0;255;0my")
        #expect(segs[0].foreground == .brightRed)
        #expect(segs[1].foreground == .brightGreen)
        #expect(segs[1].dim)
        #expect(ANSI.parse("\u{1B}[94mb").first?.foreground == .brightBlue)
    }

    @Test func stripsCursorAndOSC() {
        let s = "\u{1B}]0;title\u{07}\u{1B}[2K\u{1B}[1Gdone\u{1B}[?25h \u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\\r"
        #expect(ANSI.strip(s) == "done link")
        #expect(ANSI.strip("plain text") == "plain text")
    }
}

@MainActor
func waitFor(_ timeout: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

func testEnv(port: Int = 0) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["DOMESTIQUE_PORT"] = String(port)
    return env
}

@MainActor @Suite(.serialized) struct TaskRunTests {
    @Test func oneshotSucceeds() async {
        let run = TaskRun(
            config: TaskConfig(id: "t", command: "printf 'a\\nb\\n'", kind: .oneshot),
            workspacePath: NSTemporaryDirectory(), environment: testEnv())
        run.start()
        let ok = await run.waitUntilFinished()
        #expect(ok)
        #expect(run.state == .succeeded)
        #expect(run.lines.map(\.text) == ["a", "b"])
        #expect(run.tail(1) == "b")
    }

    @Test func oneshotFailsWithCode() async {
        let run = TaskRun(
            config: TaskConfig(id: "t", command: "echo boom; exit 3", kind: .oneshot),
            workspacePath: NSTemporaryDirectory(), environment: testEnv())
        run.start()
        #expect(await run.waitUntilFinished() == false)
        #expect(run.state == .failed(exitCode: 3))
        #expect(run.fullLogText() == "boom")
    }

    @Test func carriageReturnOverwritesAndTTY() async {
        let run = TaskRun(
            config: TaskConfig(
                id: "t", command: "printf 'x 10%%\\rx 100%%\\nnext'; [ -t 1 ] && echo ' tty' || echo ' notty'", kind: .oneshot),
            workspacePath: NSTemporaryDirectory(), environment: testEnv())
        run.start()
        _ = await run.waitUntilFinished()
        #expect(run.lines.map(\.text) == ["x 100%", "next tty"])
    }

    @Test func envAndCwd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dq-pk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = TaskRun(
            config: TaskConfig(
                id: "t", command: "echo $PORT; basename $(pwd); echo $FORCE_COLOR", kind: .oneshot,
                env: ["PORT": "p$DOMESTIQUE_PORT"], cwd: "sub"),
            workspacePath: dir.path, environment: testEnv(port: 41234))
        run.start()
        _ = await run.waitUntilFinished()
        #expect(run.lines.map(\.text) == ["p41234", "sub", "1"])
    }

    @Test func serviceReadyPortAndStopKillsTree() async throws {
        let port = PortAllocator.allocate(used: [], in: 47000...47999)
        let run = TaskRun(
            config: TaskConfig(
                id: "srv", command: "python3 -m http.server $DOMESTIQUE_PORT --bind 127.0.0.1", kind: .service,
                readyPort: "$DOMESTIQUE_PORT", open: "http://localhost:$DOMESTIQUE_PORT/"),
            workspacePath: NSTemporaryDirectory(), environment: testEnv(port: port))
        #expect(run.openURL == URL(string: "http://localhost:\(port)/"))
        run.start()
        let pid = try #require(run.pid)
        #expect(await waitFor(15) { run.state == .ready })
        #expect(await waitFor(5) { run.ports.contains(port) })
        #expect(PortScanner.listeningPorts(rootPID: pid).contains(port))
        #expect(PortScanner.isPortListening(port))

        run.stop()
        #expect(await waitFor(10) { run.state == .stopped })
        #expect(await waitFor(5) { kill(-pid, 0) != 0 })
        #expect(await waitFor(5) { !PortScanner.isPortListening(port) })
    }

    @Test func readyPatternAndRestart() async {
        let run = TaskRun(
            config: TaskConfig(id: "svc", command: "echo 'Server listening on 1234'; sleep 30", kind: .service, readyPattern: "listening on \\d+"),
            workspacePath: NSTemporaryDirectory(), environment: testEnv())
        run.start()
        #expect(await waitFor(5) { run.state == .ready })
        let firstPID = run.pid
        run.restart()
        #expect(await waitFor(8) { run.pid != firstPID && run.state == .ready })
        run.killNow()
        #expect(await waitFor(5) { run.state == .stopped })
    }

    @Test func spawnFailureReported() async {
        var env = testEnv()
        env["SHELL"] = "/nonexistent/zsh"
        // Falls back to /bin/zsh when $SHELL isn't usable, so this should still run.
        let run = TaskRun(
            config: TaskConfig(id: "t", command: "echo ok", kind: .oneshot), workspacePath: NSTemporaryDirectory(),
            environment: env)
        run.start()
        #expect(await run.waitUntilFinished())
    }
}

@MainActor @Suite(.serialized) struct SupervisorTests {
    @Test func setupCopiesFilesAndRunsScript() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dq-root-\(UUID().uuidString)")
        let ws = fm.temporaryDirectory.appendingPathComponent("dq-ws-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: ws)
        }
        try "SECRET=1".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "nested".write(to: root.appendingPathComponent("config/local.json"), atomically: true, encoding: .utf8)
        try "keep".write(to: ws.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
        try "overwrite?".write(to: root.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)

        let sup = TaskSupervisor(workspacePath: ws.path, config: RepoConfig(), environment: testEnv())
        let ok = await sup.runSetup(
            script: "cat .env > out.txt", copyFiles: [".env", "config/local.json", "missing", "existing.txt"],
            from: root.path)
        #expect(ok)
        #expect(try String(contentsOf: ws.appendingPathComponent("out.txt"), encoding: .utf8) == "SECRET=1")
        #expect(try String(contentsOf: ws.appendingPathComponent("config/local.json"), encoding: .utf8) == "nested")
        #expect(try String(contentsOf: ws.appendingPathComponent("existing.txt"), encoding: .utf8) == "keep")
        #expect(sup.setupRun?.state == .succeeded)
        #expect(sup.setupRun?.lines.contains { $0.text == "Copied .env" } == true)
    }

    @Test func stacksAndUpdate() async throws {
        let config = try RepoConfig.parse(
            toml: """
                [tasks.a]
                command = "sleep 30"
                [tasks.b]
                command = "sleep 30"
                [tasks.c]
                command = "true"
                kind = "oneshot"
                [stacks.dev]
                tasks = ["a", "b"]
                """)
        let sup = TaskSupervisor(workspacePath: NSTemporaryDirectory(), config: config, environment: testEnv())
        #expect(sup.runs.map(\.id) == ["a", "b", "c"])
        sup.startStack("dev")
        #expect(await waitFor(5) { sup.task("a")!.state.isActive && sup.task("b")!.state.isActive })
        #expect(sup.isStackRunning("dev"))
        #expect(sup.anyRunning)
        let a = sup.task("a")

        let next = try RepoConfig.parse(toml: "[tasks.a]\ncommand = \"sleep 30\"\n[tasks.d]\ncommand = \"true\"\n")
        sup.update(config: next)
        #expect(sup.runs.map(\.id) == ["a", "d"])
        #expect(sup.task("a") === a)  // kept, still running

        sup.shutdownNow()
        #expect(await waitFor(5) { !sup.anyRunning })
    }

    @Test func oneshotAdhoc() async {
        let sup = TaskSupervisor(workspacePath: NSTemporaryDirectory(), config: RepoConfig(), environment: testEnv())
        let run = sup.runOneshot(name: "Gate", command: "exit 1")
        #expect(await run.waitUntilFinished() == false)
        #expect(sup.adhocRuns.count == 1)
    }
}

@Suite struct PortAllocatorTests {
    @Test func skipsUsed() {
        let base = PortAllocator.allocate(used: [48000, 48010], in: 48000...48999)
        #expect(base >= 48020)
        #expect(base % 10 == 0)
    }

    @Test func rangesDontOverlap() {
        #expect(!PortAllocator.localRange.overlaps(PortAllocator.cloudRange))
        let cloud = PortAllocator.allocate(used: [], in: PortAllocator.cloudRange)
        #expect(PortAllocator.cloudRange.contains(cloud) && PortAllocator.cloudRange.contains(cloud + 9))
    }

    @Test func staysInRange() {
        // Every block taken: falls back to the start rather than spilling into another range.
        let used = Set(stride(from: 49000, through: 49090, by: 10))
        #expect(PortAllocator.allocate(used: used, in: 49000...49099) == 49000)
    }

    @Test func descendants() async throws {
        // A shell with a child sleep.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 5 & wait"]
        try p.run()
        defer { p.terminate() }
        try await Task.sleep(for: .milliseconds(300))
        let kids = PortScanner.descendants(of: p.processIdentifier)
        #expect(!kids.isEmpty)
        for k in kids { kill(k, SIGTERM) }
    }
}
