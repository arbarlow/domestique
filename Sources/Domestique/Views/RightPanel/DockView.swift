import AppKit
import DQCore
import ProcessKit
import SwiftUI

/// Bottom dock: Setup / Run / terminals, with stack controls on the right.
struct DockView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            DockTabBar(model: model)
            if model.dockExpanded {
                Hairline()
                Group {
                    switch model.dockTab {
                    case .setup: SetupPane(model: model)
                    case .run: RunPane(model: model)
                    case .terminal(let id):
                        if let term = model.terminals.first(where: { $0.id == id }) {
                            TerminalHost(session: term)
                                .id(term.id)
                                .padding(.leading, 16)
                                .padding(.trailing, 8)
                                .padding(.top, 12)
                                .padding(.bottom, 18)
                        } else {
                            RunPane(model: model)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - Tab bar

private struct DockTabBar: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            IconButton(
                symbol: "chevron.down", help: model.dockExpanded ? "Collapse" : "Expand", size: 10, weight: .semibold
            ) {
                withAnimation(.snappy(duration: 0.2)) { model.dockExpanded.toggle() }
            }
            .rotationEffect(.degrees(model.dockExpanded ? 0 : -90))
            .padding(.trailing, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    UnderlineTab(selected: model.dockTab == .setup) { select(.setup) } label: {
                        Text("Setup")
                    }
                    UnderlineTab(selected: model.dockTab == .run) { select(.run) } label: {
                        HStack(spacing: 5) {
                            if model.supervisor?.anyRunning ?? false {
                                Circle().fill(Theme.added).frame(width: 6, height: 6)
                                    .transition(.scale.combined(with: .opacity))
                            }
                            Text("Run")
                        }
                        .animation(.snappy(duration: 0.2), value: model.supervisor?.anyRunning ?? false)
                    }
                    ForEach(model.terminals) { term in
                        UnderlineTab(selected: model.dockTab == .terminal(term.id)) { select(.terminal(term.id)) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 11))
                                    .foregroundStyle(term.exited ? Theme.text3 : Theme.text2)
                                Text(term.title)
                                    .lineLimit(1)
                                    .frame(maxWidth: 130)
                                Button {
                                    model.closeTerminal(term.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.text3)
                                        .frame(width: 14, height: 14)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Close terminal")
                            }
                        }
                    }
                    IconButton(symbol: "plus", help: "New terminal (⌃`)", size: 11) { model.newTerminal() }
                        .padding(.leading, 2)
                }
                .frame(maxHeight: .infinity)
            }
            Spacer(minLength: 8)
            StackControls(model: model)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 36)
    }

    private func select(_ tab: DockTab) {
        model.dockTab = tab
        if !model.dockExpanded { withAnimation(.snappy(duration: 0.2)) { model.dockExpanded = true } }
    }
}

/// "🌐 Open :55050   ■ Stop ⌘R" / "▶ Run ⌘R"
private struct StackControls: View {
    let model: WorkspaceModel

    var body: some View {
        let supervisor = model.supervisor
        let running = supervisor?.anyRunning ?? false
        HStack(spacing: 6) {
            if running {
                let targets = model.openTargets
                if let primary = targets.first {
                    HStack(spacing: 0) {
                        Button {
                            NSWorkspace.shared.open(primary.url)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(Theme.text2)
                                Text("Open").font(Theme.small).foregroundStyle(Theme.text)
                                Text(verbatim: ":\(primary.port)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.text2)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(primary.name) · \(primary.url.absoluteString)")
                        Rectangle().fill(Theme.hairline).frame(width: 1, height: 14)
                        PortsButton(model: model)
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
                }
                Button {
                    supervisor?.stopAll()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("Stop")
                        Text("⌘R").foregroundStyle(Theme.text3)
                    }
                }
                .buttonStyle(.softCompact)
                .help("Stop everything running in this workspace")
            } else if model.canRunStack {
                Button {
                    model.startDefaultStack()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("Run")
                        Text("⌘R").foregroundStyle(Theme.text3)
                    }
                }
                .buttonStyle(.softCompact)
                .help("Run \(model.config?.stacks.first?.name ?? "the stack")")
            }
        }
    }

}

/// The chevron beside Open: every port this workspace serves, its free ports, and what else is
/// listening on this Mac (other workspaces, databases).
private struct PortsButton: View {
    let model: WorkspaceModel
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ports")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            PortsMenu(model: model) { shown = false }
        }
    }
}

private struct PortsMenu: View {
    @Environment(AppModel.self) private var app
    let model: WorkspaceModel
    let dismiss: () -> Void
    @State private var services: [(name: String, port: Int)] = []

    /// Well-known local services worth listing when they're up.
    nonisolated private static let knownServices: [(String, Int)] = [
        ("Postgres", 5432), ("MySQL", 3306), ("Redis", 6379), ("MongoDB", 27017),
        ("Elasticsearch", 9200), ("Pub/Sub emulator", 8085), ("Firestore emulator", 8080),
    ]

    var body: some View {
        let targets = model.openTargets
        let others = otherWorkspaces
        VStack(alignment: .leading, spacing: 1) {
            sectionTitle("This workspace")
            ForEach(targets) { t in
                row(dot: .live, name: t.name, port: "localhost:\(t.port)") { NSWorkspace.shared.open(t.url) }
            }
            if let free = freeRange(used: Set(targets.map(\.port))) {
                row(dot: .free, name: free, port: nil, action: nil)
            }
            if !others.isEmpty || !services.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 2)
                sectionTitle("Shared on this Mac")
                ForEach(services, id: \.port) { s in
                    row(symbol: "cylinder", name: s.name, port: ":\(s.port)") { open(port: s.port) }
                }
                ForEach(others, id: \.target.port) { o in
                    row(symbol: "rectangle.on.rectangle", name: "\(o.workspace) · \(o.target.name)", port: ":\(o.target.port)") {
                        NSWorkspace.shared.open(o.target.url)
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 300)
        .task {
            let known = Self.knownServices
            let found = await Task.detached {
                known.filter { PortScanner.isPortListening($0.1) }
            }.value
            services = found.map { (name: $0.0, port: $0.1) }
        }
    }

    private var otherWorkspaces: [(workspace: String, target: WorkspaceModel.OpenTarget)] {
        app.state.workspaces
            .filter { !$0.isArchived && $0.id != model.id }
            .flatMap { ws in
                (app.existingModel(for: ws.id)?.openTargets ?? []).map { (workspace: ws.name, target: $0) }
            }
    }

    /// "41002 – 41009 free": the rest of this workspace's port block.
    private func freeRange(used: Set<Int>) -> String? {
        guard let base = model.workspace?.portBase, base > 0, !model.isSandbox else { return nil }
        let free = (base..<(base + 10)).filter { !used.contains($0) }
        guard let lo = free.first, let hi = free.last else { return nil }
        return lo == hi ? "\(lo) free" : "\(lo) – \(hi) free"
    }

    private func open(port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium))
            .kerning(0.5)
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 3)
    }

    private enum Dot { case live, free }

    private func row(
        dot: Dot? = nil, symbol: String? = nil, name: String, port: String?, action: (() -> Void)?
    ) -> some View {
        PortRow(dot: dot.map { $0 == .live }, symbol: symbol, name: name, port: port) {
            guard let action else { return }
            dismiss()
            action()
        }
        .disabled(action == nil)
    }
}

private struct PortRow: View {
    /// true = live (green), false = free (hollow), nil = use `symbol`.
    let dot: Bool?
    let symbol: String?
    let name: String
    let port: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let dot {
                        if dot {
                            Circle().fill(Theme.added).frame(width: 6, height: 6)
                        } else {
                            Circle().strokeBorder(Theme.text3, lineWidth: 1).frame(width: 6, height: 6)
                        }
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    }
                }
                .frame(width: 12)
                Text(name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(enabled ? (dot == nil ? Theme.text2 : Theme.text) : Theme.text3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let port {
                    Text(port).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Run

/// Log prefixes stay grey: with colour reserved for status, the task name is enough to tell lines apart.
private let tagPalette: [Color] = [Theme.text3]

/// "Run Stack", but not "Run Run this branch" when the stack's own name already says it.
private func runLabel(_ name: String?) -> String {
    guard let name, !name.isEmpty else { return "Run stack" }
    return name.lowercased().hasPrefix("run") ? name : "Run \(name)"
}

private struct RunPane: View {
    let model: WorkspaceModel
    @State private var follow = true

    var body: some View {
        if let supervisor = model.supervisor, let config = model.config, !config.tasks.isEmpty || !supervisor.adhocRuns.isEmpty {
            let runs = supervisor.runs + supervisor.adhocRuns
            let everStarted = runs.contains { $0.startedAt != nil }
            VStack(spacing: 0) {
                RunCaption(model: model, supervisor: supervisor, config: config, follow: $follow)
                Hairline()
                if everStarted {
                    MergedLogView(runs: runs, follow: follow)
                } else {
                    VStack {
                        Spacer()
                        DashedEmptyState(message: "Run tests or a development server to test changes in this workspace") {
                            Button {
                                model.startDefaultStack()
                            } label: {
                                Label(runLabel(config.stacks.first?.name), systemImage: "play.fill")
                            }
                            .buttonStyle(.soft)
                            .disabled(!model.canRunStack)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                }
            }
        } else {
            VStack {
                Spacer()
                DashedEmptyState(message: "Run tests or a development server to test changes in this workspace") {
                    Button("Add action") { model.createConfigFile() }
                        .buttonStyle(.soft)
                }
                if let err = model.configError {
                    Text(err).font(Theme.small).foregroundStyle(Theme.removed).padding(.top, 8)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        }
    }
}

/// "▭ Running Stack     ● api  ● web  ○ test     Send to agent  ⤓"
private struct RunCaption: View {
    let model: WorkspaceModel
    let supervisor: TaskSupervisor
    let config: RepoConfig
    @Binding var follow: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(caption)
                .font(Theme.ui)
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(supervisor.runs.enumerated()), id: \.element.id) { i, run in
                        if run.state.isActive || isRecentFailure(run) {
                            TaskChip(run: run, color: tagPalette[i % tagPalette.count])
                        }
                    }
                }
            }
            TasksMenu(supervisor: supervisor)
            Spacer(minLength: 4)
            if let run = model.latestRun {
                Button("Send to agent") { model.sendLogsToAgent(run) }
                    .buttonStyle(.softCompact)
                    .help("Paste the tail of \(run.name)'s log into the chat")
            }
            IconButton(symbol: "arrow.down.to.line", help: follow ? "Following output" : "Follow output", size: 11, active: follow) {
                follow.toggle()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    /// A task that just failed stays visible so you notice; idle/stopped ones go to the Tasks menu.
    private func isRecentFailure(_ run: TaskRun) -> Bool {
        if case .failed = run.state, let ended = run.endedAt { return Date().timeIntervalSince(ended) < 600 }
        return false
    }

    private var caption: String {
        if let stack = config.stacks.first(where: { supervisor.isStackRunning($0.id) }) {
            return "Running \(stack.name)"
        }
        return supervisor.anyRunning ? "Running" : "Tasks"
    }
}

private struct TaskChip: View {
    let run: TaskRun
    let color: Color

    var body: some View {
        Menu {
            Button("Stop") { run.stop() }.disabled(!run.state.isActive)
            Button("Restart") { run.restart() }
            if let url = run.openURL { Button("Open \(url.absoluteString)") { NSWorkspace.shared.open(url) } }
            Divider()
            Button("Copy log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.fullLogText(), forType: .string)
            }
            Button("Clear log") { run.clearLog() }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(run.name).font(Theme.small).foregroundStyle(Theme.text)
                if let port = run.ports.first {
                    Text(verbatim: ":\(port)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(run.state.label) · \(run.command)")
    }

    private var dotColor: Color {
        switch run.state {
        case .idle, .stopped: Theme.text3.opacity(0.6)
        case .starting: Theme.warning
        case .running: Theme.running
        case .ready, .succeeded: Theme.added
        case .failed: Theme.removed
        }
    }
}

/// Everything you can run that isn't running: one-offs (Xcode, Pulumi…) and stopped services.
private struct TasksMenu: View {
    let supervisor: TaskSupervisor

    var body: some View {
        let idle = supervisor.runs.filter { !$0.state.isActive }
        if !idle.isEmpty {
            Menu {
                ForEach(idle) { run in
                    Button {
                        run.start()
                    } label: {
                        Label(run.name, systemImage: run.kind == .oneshot ? "play" : "play.circle")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.circle").font(.system(size: 11))
                    Text("Tasks").font(Theme.small)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Run another task")
        }
    }
}

/// All task logs interleaved by arrival (LogLine ids are globally monotonic), each prefixed "[name]".
private struct MergedLogView: View {
    let runs: [TaskRun]
    let follow: Bool

    private struct Entry: Identifiable {
        let line: LogLine
        let run: Int
        var id: Int { line.id }
    }

    @State private var position = ScrollPosition(edge: .bottom)

    /// Scrolls to the content's bottom edge (so the bottom padding stays visible), repeated over the
    /// next couple of runloop turns: the lazy stack only knows estimated heights for rows it hasn't
    /// laid out, so the first jump can land short of the real end.
    private func scrollToBottom() {
        position.scrollTo(edge: .bottom)
        DispatchQueue.main.async {
            position.scrollTo(edge: .bottom)
            DispatchQueue.main.async { position.scrollTo(edge: .bottom) }
        }
    }

    var body: some View {
        let entries = merged()
        let names = runs.count == 1 ? [""] : runs.map { "[\($0.id)] " }
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(entries) { e in
                    Text(tagged(names[e.run], color: tagPalette[e.run % tagPalette.count], line: e.line))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 18)
            .textSelection(.enabled)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        .onChange(of: entries.last?.id) { _, id in
            if follow, id != nil { scrollToBottom() }
        }
        .onChange(of: follow) { _, on in
            if on { scrollToBottom() }
        }
        .onAppear {
            if !entries.isEmpty { scrollToBottom() }
        }
    }

    private func tagged(_ tag: String, color: Color, line: LogLine) -> AttributedString {
        var t = AttributedString(tag)
        t.foregroundColor = color
        return t + ansiAttributed(line)
    }

    /// Last ~2000 lines across runs. Each run's lines are already id-sorted, so this is a cheap sort of suffixes.
    private func merged() -> [Entry] {
        var all: [Entry] = []
        for (i, run) in runs.enumerated() {
            for line in run.lines.suffix(1200) { all.append(Entry(line: line, run: i)) }
        }
        all.sort { $0.line.id < $1.line.id }
        return Array(all.suffix(2000))
    }
}

// MARK: - Setup

private struct SetupPane: View {
    let model: WorkspaceModel

    var body: some View {
        if let run = model.supervisor?.setupRun {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TaskChip(run: run, color: Theme.running)
                    Text(run.state.label)
                        .font(Theme.small)
                        .foregroundStyle(Theme.text2)
                    Spacer()
                    Button("Send to agent") { model.sendLogsToAgent(run) }
                        .buttonStyle(.softCompact)
                    Button("Re-run") { Task { await model.runSetup() } }
                        .buttonStyle(.softCompact)
                        .disabled(run.state.isActive)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                Hairline()
                MergedLogView(runs: [run], follow: true)
            }
        } else {
            VStack {
                Spacer()
                if model.config?.setupScript != nil || !(model.config?.copyFiles.isEmpty ?? true) {
                    DashedEmptyState(message: "The setup script runs when a workspace is created.") {
                        Button("Run setup") { Task { await model.runSetup() } }
                            .buttonStyle(.soft)
                    }
                } else {
                    DashedEmptyState(
                        message: "Add a [setup] script to domestique.toml to install dependencies and copy .env files into every new workspace."
                    ) {
                        Button("Add action") { model.createConfigFile() }
                            .buttonStyle(.soft)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Helpers

func ansiAttributed(_ line: LogLine) -> AttributedString {
    var out = AttributedString()
    for seg in line.segments {
        var a = AttributedString(seg.text)
        if let c = seg.foreground { a.foregroundColor = ansiColor(c) }
        if seg.bold { a.inlinePresentationIntent = .stronglyEmphasized }
        if seg.dim { a.foregroundColor = Theme.text3 }
        out += a
    }
    if out.characters.isEmpty { out = AttributedString(" ") }
    return out
}

func ansiColor(_ c: ANSIColor) -> Color {
    switch c {
    case .black, .brightBlack: Theme.text3
    case .red, .brightRed: Theme.removed
    case .green, .brightGreen: Theme.added
    case .yellow, .brightYellow: Theme.warning
    case .blue, .brightBlue: Theme.running
    case .magenta, .brightMagenta: Theme.merged
    case .cyan, .brightCyan: .teal
    case .white, .brightWhite: Theme.text
    }
}
