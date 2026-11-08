import DQCore
import SafariServices
import ServerKit
import SwiftUI

/// The workspace's `domestique.toml` tasks, and the dev servers it's listening on, opened in a browser on this phone.
struct RunView: View {
    let server: ServerConnection
    let workspaceID: String

    @State private var tasks: [TaskConfig] = []
    @State private var states: [String: TaskRunner.State] = [:]
    @State private var ports: [UInt16] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var error: String?
    @State private var opening: UInt16?
    @State private var preview: PreviewPage?
    @State private var log: TaskConfig?
    @State private var askPort = false
    @State private var portText = ""
    @Environment(\.dismiss) private var dismiss

    private var runner: TaskRunner? {
        server.workspaces[workspaceID].map { TaskRunner(server: server, workspace: $0, repository: server.repositories[$0.repositoryID]) }
    }

    var body: some View {
        List {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            Section {
                ForEach(ports, id: \.self) { port in
                    Button {
                        open(port: port)
                    } label: {
                        HStack {
                            Label("localhost:\(String(port))", systemImage: "globe")
                            Spacer()
                            if opening == port { ProgressView() } else { Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }
                        }
                    }
                }
                Button("Open another port…", systemImage: "number") { askPort = true }
            } header: {
                Text("Open on this phone")
            } footer: {
                if ports.isEmpty && loaded { Text("Nothing is listening on this workspace's ports yet.") }
            }
            if !tasks.isEmpty {
                Section("Tasks") {
                    ForEach(tasks) { task in row(task) }
                }
            } else if loaded && failure == nil {
                Text("Add tasks to \(RepoConfig.fileName) to start them from here.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Run & preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", systemImage: "xmark") { dismiss() }
            }
        }
        .task { await poll() }
        .sheet(item: $log) { task in
            if let runner { NavigationStack { TaskLogView(task: task, runner: runner) } }
        }
        .fullScreenCover(item: $preview) { page in
            SafariPreview(page: page, server: server)
        }
        .alert("Open port", isPresented: $askPort) {
            TextField("Port", text: $portText).keyboardType(.numberPad)
            Button("Open") {
                if let port = UInt16(portText) { open(port: port) }
                portText = ""
            }
            Button("Cancel", role: .cancel) { portText = "" }
        }
        .alert("Something went wrong", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func row(_ task: TaskConfig) -> some View {
        let state = states[task.id] ?? .idle
        return HStack {
            Button {
                log = task
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).foregroundStyle(.primary)
                    Text(state.label).font(.caption).foregroundStyle(state.isFailure ? Palette.removed : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if state == .running {
                if let target = runner?.openTarget(of: task) {
                    Button("Open", systemImage: "arrow.up.right") { open(port: target.port, path: target.path) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                Button("Stop", systemImage: "stop.fill") { act { try await $0.stop(task) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .tint(Palette.removed)
            } else {
                Button("Start", systemImage: "play.fill") { act { try await $0.start(task) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func poll() async {
        do {
            tasks = try await server.repoConfig(of: workspaceID)?.tasks ?? []
        } catch {
            failure = error.localizedDescription
        }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func refresh() async {
        guard let runner else { return }
        do {
            (states, ports) = try await runner.status(of: tasks)
            if failure != nil, !tasks.isEmpty { failure = nil }
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    private func act(_ action: @escaping (TaskRunner) async throws -> Void) {
        guard let runner else { return }
        Task {
            do {
                try await action(runner)
            } catch {
                self.error = error.localizedDescription
            }
            await refresh()
        }
    }

    private func open(port: UInt16, path: String = "") {
        opening = port
        Task {
            defer { opening = nil }
            do {
                let url = try await server.previewURL(port: port, path: path, in: workspaceID)
                preview = PreviewPage(url: url, remotePort: port)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Running tasks

/// Starts tasks detached from the connection that started them: a phone locks and drops its socket, and the server
/// hangs up a process's whole group when that happens, or when its leader exits. So each task gets its own session
/// (perl, because macOS has no `setsid` command), with its pid, log and exit status in a directory per workspace.
@MainActor
struct TaskRunner {
    enum State: Equatable {
        case idle, running
        case exited(Int32)

        var label: String {
            switch self {
            case .idle: "Stopped"
            case .running: "Running"
            case .exited(0): "Finished"
            case .exited(let code): "Failed (exit \(code))"
            }
        }
        var isFailure: Bool {
            if case .exited(let code) = self { return code != 0 }
            return false
        }
    }

    let server: ServerConnection
    let workspace: Proto_Workspace
    let repository: Proto_Repository?

    private static let dir = #"d="${TMPDIR:-/tmp}/domestique-tasks/$DOMESTIQUE_WORKSPACE""#

    /// A file-safe form of a task id, usable unquoted in the scripts below.
    private func key(_ task: TaskConfig) -> String {
        String(task.id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
    }

    private var variables: [String: String] {
        var vars = [
            "DOMESTIQUE": "1",
            "DOMESTIQUE_WORKSPACE": workspace.name,
            "DOMESTIQUE_WORKSPACE_PATH": workspace.path,
            "DOMESTIQUE_ROOT_PATH": repository?.path ?? workspace.path,
            "DOMESTIQUE_BRANCH": workspace.branch,
            "DOMESTIQUE_DEFAULT_BRANCH": server.defaultBranch(of: workspace),
            "DOMESTIQUE_PORT": String(workspace.portBase),
        ]
        for i in 0..<WorkspaceEnvironment.portCount { vars["DOMESTIQUE_PORT_\(i)"] = String(Int(workspace.portBase) + i) }
        return vars
    }

    func status(of tasks: [TaskConfig]) async throws -> ([String: State], [UInt16]) {
        var script = [Self.dir]
        for task in tasks {
            let k = key(task)
            script.append(#"p=$(cat "$d/\#(k).pid" 2>/dev/null); if [ -n "$p" ] && kill -0 -- "-$p" 2>/dev/null; then echo "task \#(k) running"; elif [ -f "$d/\#(k).status" ]; then echo "task \#(k) $(cat "$d/\#(k).status")"; else echo "task \#(k) idle"; fi"#)
        }
        let first = Int(workspace.portBase)
        let range = first..<(first + WorkspaceEnvironment.portCount)
        script.append("for p in \(range.map(String.init).joined(separator: " ")); do if (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then echo \"port $p\"; fi; done")
        let output = try await server.runChecked(in: workspace.id, script.joined(separator: "\n")).stdout

        let byKey = Dictionary(tasks.map { (key($0), $0.id) }, uniquingKeysWith: { a, _ in a })
        var states: [String: State] = [:]
        var ports: [UInt16] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            if words.count == 3, words[0] == "task", let id = byKey[String(words[1])] {
                states[id] = words[2] == "running" ? .running : words[2] == "idle" ? .idle : Int32(words[2]).map(State.exited) ?? .idle
            } else if words.count == 2, words[0] == "port", let port = UInt16(words[1]) {
                ports.append(port)
            }
        }
        return (states, ports)
    }

    func start(_ task: TaskConfig) async throws {
        let k = key(task)
        let vars = variables
        let env = task.env.mapValues { WorkspaceEnvironment.expand($0, vars) }
        let body = "(\(task.command)\n)\necho $? > \"$DOMESTIQUE_TASK_STATUS\""
        var script = [
            Self.dir,
            #"mkdir -p "$d""#,
            #"p=$(cat "$d/\#(k).pid" 2>/dev/null); if [ -n "$p" ] && kill -0 -- "-$p" 2>/dev/null; then exit 0; fi"#,
            #"rm -f "$d/\#(k).status" "$d/\#(k).pid""#,
            #"export DOMESTIQUE_TASK_STATUS="$d/\#(k).status" DOMESTIQUE_TASK_PID="$d/\#(k).pid""#,
        ]
        if let cwd = task.cwd { script.append("cd \(ShellQuote.quote(cwd)) || exit 1") }
        let exports = ShellQuote.exports(env)
        if !exports.isEmpty { script.append(exports) }
        let detach = #"POSIX::setsid() or die "setsid: $!"; open(F, ">", $ENV{DOMESTIQUE_TASK_PID}) or die "pid: $!"; print F $$; close F; exec @ARGV or die "exec: $!";"#
        script.append(#"perl -MPOSIX -e \#(ShellQuote.quote(detach)) bash -lc \#(ShellQuote.quote(body)) > "$d/\#(k).log" 2>&1 < /dev/null &"#)
        // Leaving before it has its own session would take it down with this shell's group.
        script.append(#"for i in $(seq 50); do [ -s "$d/\#(k).pid" ] && exit 0; sleep 0.1; done; echo "Couldn't start \#(task.name): $(tail -n 3 "$d/\#(k).log")" >&2; exit 1"#)
        try await server.runChecked(in: workspace.id, script.joined(separator: "\n"))
    }

    func stop(_ task: TaskConfig) async throws {
        let k = key(task)
        // TERM the task's process group, then KILL whatever ignored it. Waits here, as a background timer would be
        // hung up along with this shell.
        let script = [
            Self.dir,
            #"p=$(cat "$d/\#(k).pid" 2>/dev/null); [ -n "$p" ] || exit 0"#,
            #"kill -TERM -- "-$p" 2>/dev/null"#,
            #"for i in $(seq 30); do kill -0 -- "-$p" 2>/dev/null || exit 0; sleep 0.1; done"#,
            #"kill -KILL -- "-$p" 2>/dev/null"#,
            "exit 0",
        ]
        try await server.runChecked(in: workspace.id, script.joined(separator: "\n"))
    }

    func log(of task: TaskConfig) async throws -> String {
        let k = key(task)
        let r = try await server.run(in: workspace.id, "\(Self.dir)\ntail -n 400 \"$d/\(k).log\" 2>/dev/null")
        return r.stdout.replacing(/\x1B\[[0-9;?]*[ -\/]*[@-~]/, with: "")
    }

    /// Where the task's Open button goes on the server. Nil when it names no local port.
    func openTarget(of task: TaskConfig) -> (port: UInt16, path: String)? {
        let vars = variables
        if let open = task.open, let url = URLComponents(string: WorkspaceEnvironment.expand(open, vars)),
            let host = url.host, ["localhost", "127.0.0.1", "0.0.0.0"].contains(host), let port = url.port.flatMap(UInt16.init)
        {
            let query = url.percentEncodedQuery.map { "?\($0)" } ?? ""
            return (port, url.percentEncodedPath + query)
        }
        if let ready = task.readyPort, let port = UInt16(WorkspaceEnvironment.expand(ready, vars)) { return (port, "") }
        return nil
    }
}

private struct TaskLogView: View {
    let task: TaskConfig
    let runner: TaskRunner
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No output yet" : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle(task.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", systemImage: "xmark") { dismiss() }
            }
        }
        .task {
            while !Task.isCancelled {
                if let log = try? await runner.log(of: task) { text = log }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - Browser

struct PreviewPage: Identifiable {
    let url: URL
    let remotePort: UInt16
    var id: URL { url }
}

private struct SafariPreview: View {
    let page: PreviewPage
    let server: ServerConnection
    @Environment(\.scenePhase) private var phase

    var body: some View {
        SafariController(url: page.url)
            .ignoresSafeArea()
            // The system tears the listener down while the app is suspended.
            .onChange(of: phase) { _, new in
                if new == .active { Task { _ = try? await server.tunnel(to: page.remotePort).open() } }
            }
    }
}

private struct SafariController: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
