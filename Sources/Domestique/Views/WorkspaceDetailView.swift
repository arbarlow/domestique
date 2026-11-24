import DQCore
import SwiftUI

struct WorkspaceDetailView: View {
    @Environment(AppModel.self) private var app
    let model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if let ws = model.workspace {
                WorkspaceHeader(model: model, workspace: ws)
                ChatTabBar(model: model, workspace: ws)
                Hairline()
                if ws.isSandbox, ws.state == .ready { MachineBanner(workspace: ws) }
                if [.creating, .settingUp, .ready].contains(ws.state), let timeline = app.creationTimelines[ws.id] {
                    CreationSummaryBar(timeline: timeline) { app.creationTimelines[ws.id] = nil }
                } else if ws.state == .creating {
                    CreatingBar(title: creatingTitle(ws), detail: creatingDetail(ws))
                }
                switch ws.state {
                case .failed(let message):
                    FailedPlaceholder(message: message, workspace: ws)
                default:
                    // Usable while it's still being created: messages wait until the worktree exists.
                    if let chat = model.selectedChat {
                        ChatView(chat: chat, workspaceModel: model)
                            .id(chat.tabID)
                    }
                }
            }
        }
        .background(Theme.canvas)
        .onAppear {
            model.refreshDiff()
            if model.workspace?.prNumber != nil || model.shipMode == .pullRequest { model.refreshPR() }
        }
    }

    private func creatingTitle(_ ws: Workspace) -> String {
        if ws.serverID != nil { return "Creating on \(ws.host?.machineName ?? "Server")" }
        if ws.isSandbox || ws.path.hasPrefix("/home/user") { return "Creating a boat.dev workspace" }
        return "Creating worktree"
    }

    private func creatingDetail(_ ws: Workspace) -> String {
        if let step = app.creationSteps[ws.id] { return step }
        if ws.isSandbox || ws.path.hasPrefix("/home/user") { return "Starting a sandbox and cloning \(model.repo?.name ?? "the repo")" }
        return "Fetching origin/\(ws.baseBranch) and branching \(ws.branch)"
    }
}

// MARK: - Header

private struct WorkspaceHeader: View {
    @Environment(AppModel.self) private var app
    let model: WorkspaceModel
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            if !app.sidebarVisible {
                Spacer().frame(width: 70)
                IconButton(symbol: "sidebar.left", help: "Show sidebar (⌘\\)") { app.sidebarVisible = true }
            }
            if let repo = model.repo {
                Button {
                    app.settingsRoute = .repo(repo.id)
                } label: {
                    HStack(spacing: 7) {
                        RepoIconView(repo: repo, size: 18)
                        Text(repo.title)
                    }
                }
                .buttonStyle(.plain)
                .help("Repository settings")
                .font(Theme.ui)
                .foregroundStyle(Theme.text2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            Text(workspace.branch)
                .font(Theme.uiMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            WorkspaceMenu(model: model, workspace: workspace)
            if workspace.isSandbox { MachineBadge(model: model, workspace: workspace) }
            if let server = workspace.host, server.provider == .server {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack").font(.system(size: 10))
                    Text(server.machineName ?? "Server").font(Theme.small)
                }
                .foregroundStyle(Theme.text2)
                .help("This workspace runs on \(server.machineName ?? "a server")")
            }
            Spacer(minLength: 12)

            ForEach(model.openTargets) { target in
                Button {
                    NSWorkspace.shared.open(target.url)
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.added).frame(width: 6, height: 6)
                        Text(verbatim: ":\(target.port)").font(Theme.monoDigits)
                    }
                }
                .buttonStyle(.softCompact)
                .help("\(target.name) · \(target.url.absoluteString)")
            }
            if workspace.isRemote {
                if workspace.isSandbox {
                    IconButton(symbol: "display", help: "Open the sandbox desktop", size: 12) {
                        app.cloud.openDesktop(workspace)
                    }
                }
                IconButton(symbol: "terminal", help: "New terminal on \(workspace.isSandbox ? "the sandbox" : workspace.host?.machineName ?? "the server") (⌃`)", size: 12) {
                    model.newTerminal()
                }
            } else {
                OpenMenu(model: model)
            }
            IconButton(symbol: "sidebar.right", help: "Toggle panel (⌥⌘I)", active: app.rightPanelVisible) {
                app.rightPanelVisible.toggle()
            }
        }
        .padding(.horizontal, 12)
        .headerBar()
    }
}

/// Opens the worktree: click for Finder, or pick an editor or Xcode project from the dropdown.
private struct OpenMenu: View {
    @Environment(AppModel.self) private var app
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "folder", help: "Open in Finder", size: 12) { model.openInFinder() }
            Menu {
                Button("Finder") { model.openInFinder() }
                let choices = app.settings.editorChoices(installed: Set(model.installedApps.keys))
                if !choices.isEmpty {
                    Divider()
                    ForEach(choices) { choice in
                        Button { model.openWorktree(with: choice) } label: { label(for: choice) }
                    }
                }
                if let xcode = model.installedApps[EditorApps.xcodeBundleID], !model.xcodeProjects.isEmpty {
                    Divider()
                    ForEach(model.xcodeProjects) { project in
                        Button { model.openXcodeProject(project) } label: {
                            Label { Text(verbatim: project.relativePath) } icon: { Image(nsImage: xcode.icon) }
                        }
                    }
                }
                Divider()
                Button("Editor Settings…") { app.settingsRoute = .general }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 14, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open in…")
        }
        .task(id: model.workspace?.path) { model.refreshOpenTargets() }
        .onHover { if $0 { model.refreshOpenTargets() } }
    }

    @ViewBuilder private func label(for choice: EditorChoice) -> some View {
        if case .app(let editor) = choice, let icon = model.installedApps[editor.bundleID]?.icon {
            Label { Text(choice.name) } icon: { Image(nsImage: icon) }
        } else {
            Label(choice.name, systemImage: "terminal")
        }
    }
}

private struct WorkspaceMenu: View {
    @Environment(AppModel.self) private var app
    let model: WorkspaceModel
    let workspace: Workspace

    var body: some View {
        Menu {
            Button("New chat tab") { model.newTab() }
            Button("New terminal") { model.newTerminal() }
            Divider()
            if workspace.isSandbox {
                Button("Open desktop") { app.cloud.openDesktop(workspace) }
                Button("Copy SSH command") { app.cloud.copySSHCommand(workspace) }
            } else if workspace.serverID != nil {
            } else {
                Button("Open in editor") { model.openInEditor() }
                Button("Reveal in Finder") { model.revealInFinder() }
            }
            Button("Copy branch name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.branch, forType: .string)
            }
            Button(workspace.isSandbox ? "Copy path on sandbox" : workspace.serverID != nil ? "Copy path on \(workspace.host?.machineName ?? "Server")" : "Copy worktree path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.path, forType: .string)
            }
            Divider()
            Picker("Ship mode", selection: Binding(
                get: { model.shipMode },
                set: { mode in app.updateWorkspace(workspace.id) { $0.shipModeOverride = mode } }
            )) {
                ForEach(ShipMode.allCases) { Text($0.displayName).tag($0) }
            }
            Divider()
            Button("Archive") { Task { await app.archive(workspace) } }
                .disabled(app.archiving.contains(workspace.id))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Tabs

struct ChatTabBar: View {
    let model: WorkspaceModel
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        let selected = (workspace.selectedTabID ?? workspace.tabs.first?.id) == tab.id
                        ChatTabItem(
                            tab: tab, selected: selected, running: model.isRunning(tabID: tab.id),
                            select: { model.selectTab(tab.id) }, close: { model.closeTab(tab.id) })
                    }
                }
                .padding(.horizontal, 8)
            }
            if let closed = workspace.closedTabs, !closed.isEmpty {
                Menu {
                    Section("Recently closed") {
                        ForEach(closed) { c in
                            Button {
                                model.reopenTab(c.id)
                            } label: {
                                Text(c.tab.title)
                                Text(c.closedAt, format: .relative(presentation: .named))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Reopen a closed chat (⇧⌘T)")
            }
            Menu {
                ForEach(ProviderKind.allCases) { p in
                    Button("New " + p.displayName + " chat") { model.newTab(provider: p) }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            } primaryAction: {
                model.newTab()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New chat tab (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(height: 34)
    }
}

private struct ChatTabItem: View {
    let tab: ChatTab
    let selected: Bool
    let running: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        UnderlineTab(selected: selected, action: select) {
            HStack(spacing: 6) {
                if running {
                    Spinner(size: 10)
                } else {
                    ProviderIcon(provider: tab.provider, size: 10)
                }
                Text(tab.title)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || selected ? 1 : 0)
            }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Placeholders

/// Every stage of creating a workspace: what's done, what's running, and how long each took.
struct CreationStageList: View {
    let timeline: CreationTimeline

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 9) {
                ForEach(timeline.stages) { stage in
                    row(stage, now: ctx.date)
                }
                if let total = timeline.total(now: ctx.date) {
                    Hairline()
                    HStack {
                        Text("Total").font(Theme.uiMedium).foregroundStyle(Theme.text)
                        Spacer(minLength: 12)
                        Text(CreationTimeline.format(total)).font(Theme.monoDigits).foregroundStyle(Theme.text)
                    }
                }
            }
        }
    }

    private func row(_ stage: CreationTimeline.Stage, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon(stage.status).frame(width: 14, height: 14).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.title)
                    .font(Theme.ui)
                    .foregroundStyle(stage.status == .pending ? Theme.text3 : Theme.text)
                if stage.status == .running, let detail = stage.detail {
                    Text(detail).font(Theme.small).foregroundStyle(Theme.text3)
                }
            }
            Spacer(minLength: 12)
            if let duration = stage.duration(now: now) {
                Text(CreationTimeline.format(duration)).font(Theme.monoDigits).foregroundStyle(Theme.text2)
            }
        }
    }

    @ViewBuilder private func icon(_ status: CreationTimeline.Stage.Status) -> some View {
        switch status {
        case .pending: Circle().strokeBorder(Theme.text3, lineWidth: 1).frame(width: 9, height: 9)
        case .running: Spinner(size: 11)
        case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.added)
        case .failed: Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.removed)
        }
    }
}

/// Above the chat while the worktree is being made. The chat already works; sends wait for this.
struct CreatingBar: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Spinner(size: 10)
            Text(title).font(Theme.smallMedium).foregroundStyle(Theme.text)
            Text(detail).font(Theme.small).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Above the chat while the workspace is created and set up: setup's progress, then where the time went.
struct CreationSummaryBar: View {
    let timeline: CreationTimeline
    let onDismiss: () -> Void
    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 8) {
                    if timeline.current != nil { Spinner(size: 10) }
                    Text(summary(now: ctx.date)).font(Theme.small).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Details") { showingDetails.toggle() }
                .buttonStyle(.softCompact)
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                    CreationStageList(timeline: timeline).frame(width: 400).padding(16)
                }
            if timeline.current == nil {
                Button("Dismiss", action: onDismiss).buttonStyle(.softCompact)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func summary(now: Date) -> String {
        if let current = timeline.current {
            return "\(current.title) · \(CreationTimeline.format(current.duration(now: now) ?? 0))"
        }
        var text = "Created in \(CreationTimeline.format(timeline.total(now: now) ?? 0))"
        if let slowest = timeline.slowest, let duration = slowest.duration(now: now) {
            text += " · slowest: \(slowest.title) (\(CreationTimeline.format(duration)))"
        }
        return text
    }
}

struct FailedPlaceholder: View {
    @Environment(AppModel.self) private var app
    let message: String
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.warning)
            Text("Couldn't create workspace").font(Theme.bodyMedium)
            Text(message).font(Theme.ui).foregroundStyle(Theme.text2).textSelection(.enabled).multilineTextAlignment(.center)
            if let timeline = app.creationTimelines[workspace.id] {
                CreationStageList(timeline: timeline).frame(maxWidth: 420).padding(.vertical, 8)
            }
            Button("Archive") { Task { await app.archive(workspace) } }
                .buttonStyle(.soft)
                .disabled(app.archiving.contains(workspace.id))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
