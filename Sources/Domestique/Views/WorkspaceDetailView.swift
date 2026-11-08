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
                switch ws.state {
                case .creating where ws.serverID != nil:
                    ProgressPlaceholder(
                        title: "Creating on \(ws.host?.machineName ?? "Server")",
                        detail: app.creationSteps[ws.id] ?? "Cloning \(model.repo?.name ?? "the repo") and branching \(ws.branch)")
                case .creating where ws.isSandbox || ws.path.hasPrefix("/home/user"):
                    ProgressPlaceholder(
                        title: "Creating a boat.dev workspace",
                        detail: app.creationSteps[ws.id] ?? "Starting a sandbox and cloning \(model.repo?.name ?? "the repo")")
                case .settingUp where ws.isRemote:
                    if let chat = model.selectedChat {
                        ChatView(chat: chat, workspaceModel: model).id(chat.tabID)
                    }
                case .creating:
                    ProgressPlaceholder(title: "Creating worktree", detail: "Fetching origin/\(ws.baseBranch) and branching \(ws.branch)")
                case .failed(let message):
                    FailedPlaceholder(message: message, workspace: ws)
                default:
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

            if let target = model.primaryOpenTarget {
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
            if model.canRunStack {
                IconButton(
                    symbol: model.isDefaultStackRunning ? "stop.fill" : "play.fill",
                    help: model.isDefaultStackRunning ? "Stop stack (⌘R)" : "Run stack (⌘R)",
                    size: 11
                ) { model.startDefaultStack() }
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
                IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor (⇧⌘E)", size: 12) {
                    model.openInEditor()
                }
            }
            IconButton(symbol: "sidebar.right", help: "Toggle panel (⌥⌘I)", active: app.rightPanelVisible) {
                app.rightPanelVisible.toggle()
            }
        }
        .padding(.horizontal, 12)
        .headerBar()
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
                            canClose: workspace.tabs.count > 1,
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
    let canClose: Bool
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
                if canClose {
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
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Placeholders

struct ProgressPlaceholder: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Spinner(size: 20)
            Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
            Text(detail).font(Theme.ui).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Button("Archive") { Task { await app.archive(workspace) } }.buttonStyle(.soft)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
