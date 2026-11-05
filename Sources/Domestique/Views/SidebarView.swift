import DQCore
import GitHubKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var showArchived: Set<UUID> = []
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header: traffic lights live on the left of this row.
            HStack(spacing: 2) {
                Spacer()
                IconButton(symbol: "sidebar.left", help: "Hide sidebar (⌘\\)") { app.sidebarVisible = false }
            }
            .padding(.horizontal, 10)
            .headerBar()

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    HoverRow(height: 30, action: newWorkspace) {
                        Label {
                            HStack {
                                Text("New workspace")
                                Spacer()
                                Text("⌘N").font(Theme.small).foregroundStyle(Theme.text3)
                            }
                        } icon: {
                            Image(systemName: "square.and.pencil")
                        }
                        .font(Theme.ui)
                        .foregroundStyle(Theme.text)
                    }
                    .disabled(app.repositories.isEmpty)

                    Text("Workspaces")
                        .font(Theme.small)
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 8)
                        .padding(.top, 18)
                        .padding(.bottom, 4)

                    ForEach(app.repositories) { repo in
                        RepoSection(
                            repo: repo,
                            collapsed: collapsed.contains(repo.id),
                            showArchived: showArchived.contains(repo.id),
                            toggleCollapsed: { toggle(&collapsed, repo.id) },
                            toggleArchived: { toggle(&showArchived, repo.id) }
                        )
                    }

                    if app.repositories.isEmpty {
                        Text("No repositories yet")
                            .font(Theme.ui)
                            .foregroundStyle(Theme.text3)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            SidebarFooter()
        }
        .background(Theme.sidebar)
    }

    private func toggle(_ set: inout Set<UUID>, _ id: UUID) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func newWorkspace() {
        let repo = app.selectedWorkspaceModel?.repo ?? app.repositories.first
        guard let repo else { return app.promptAddRepository() }
        Task { await app.createWorkspace(in: repo) }
    }
}

private struct RepoSection: View {
    @Environment(AppModel.self) private var app
    let repo: Repository
    let collapsed: Bool
    let showArchived: Bool
    let toggleCollapsed: () -> Void
    let toggleArchived: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                RepoIconView(repo: repo, size: 18)
                Text(repo.title)
                    .font(Theme.uiMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if repo.shipMode == .trunk {
                    Text("trunk")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.hover, in: Capsule())
                }
                Spacer(minLength: 4)
                if hovering {
                    Menu {
                        Button("New workspace with Claude") { Task { await app.createWorkspace(in: repo, provider: .claude) } }
                        Button("New workspace with Codex") { Task { await app.createWorkspace(in: repo, provider: .codex) } }
                        Divider()
                        Picker("Ship mode", selection: Binding(
                            get: { repo.shipMode },
                            set: { mode in app.updateRepo(repo.id) { $0.shipMode = mode } }
                        )) {
                            ForEach(ShipMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        Button(showArchived ? "Hide archived" : "Show archived", action: toggleArchived)
                        Button("Repository settings…") { app.settingsRoute = .repo(repo.id) }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
                        }
                        Divider()
                        Button("Remove repository", role: .destructive) { app.removeRepository(repo) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.text2)
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    IconButton(symbol: "plus", help: "New workspace from origin/\(repo.defaultBranch)", size: 12) {
                        Task { await app.createWorkspace(in: repo) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleCollapsed)
            .onHover { hovering = $0 }

            if !collapsed {
                ForEach(app.activeWorkspaces(in: repo)) { ws in
                    WorkspaceRow(workspace: ws)
                }
                if showArchived {
                    ForEach(app.archivedWorkspaces(in: repo)) { ws in
                        WorkspaceRow(workspace: ws).opacity(0.5)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }
}

struct RepoMonogram: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
    private var color: Color {
        let palette: [Color] = [.indigo, .teal, .orange, .pink, .blue, .green, .purple, .brown]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }
}

struct WorkspaceRow: View {
    @Environment(AppModel.self) private var app
    let workspace: Workspace

    var body: some View {
        let model = app.existingModel(for: workspace.id)
        let selected = app.selectedWorkspaceID == workspace.id
        HoverRow(selected: selected, height: 32, action: { app.selectedWorkspaceID = workspace.id }) {
            HStack(spacing: 8) {
                WorkspaceGlyph(workspace: workspace, model: model)
                    .frame(width: 16)
                Text(title(model))
                    .font(workspace.hasUnread ? Theme.uiMedium : Theme.ui)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let model, !model.diffFiles.isEmpty {
                    DiffCount(additions: model.diffStat.additions, deletions: model.diffStat.deletions)
                } else if workspace.hasUnread {
                    Circle().fill(Theme.running).frame(width: 6, height: 6)
                }
            }
        }
        .help("\(workspace.name) · \(workspace.branch)")
        .contextMenu { WorkspaceContextMenu(workspace: workspace) }
        .padding(.leading, 8)
    }

    private func title(_ model: WorkspaceModel?) -> String {
        switch workspace.state {
        case .creating: return "Creating \(workspace.name)…"
        case .settingUp: return "Setting up \(workspace.name)…"
        case .failed: return "\(workspace.name) (failed)"
        default:
            let tab = workspace.tabs.first { $0.id == workspace.selectedTabID } ?? workspace.tabs.first
            if let t = tab?.title, t != "New chat" { return t }
            return workspace.name.capitalized
        }
    }
}

/// Branch glyph that doubles as status: spinner while the agent works, hand when it needs you,
/// PR colours once a PR exists.
struct WorkspaceGlyph: View {
    let workspace: Workspace
    let model: WorkspaceModel?

    var body: some View {
        switch workspace.state {
        case .creating, .settingUp:
            Spinner(size: 11)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
        case .archived:
            Image(systemName: "archivebox").font(.system(size: 11)).foregroundStyle(Theme.text3)
        case .ready:
            if model?.needsAttention == true {
                Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
            } else if model?.isAgentRunning == true {
                Spinner(size: 11)
            } else {
                Image(systemName: workspace.prNumber != nil ? "arrow.triangle.pull" : "arrow.triangle.branch")
                    .font(.system(size: 11.5))
                    .foregroundStyle(glyphColor)
            }
        }
    }

    private var glyphColor: Color {
        guard let status = model?.prStatus else {
            return model?.supervisor?.anyRunning == true ? Theme.added : Theme.text2
        }
        if status.pr.state == .merged { return Theme.merged }
        if status.pr.state == .closed { return Theme.text3 }
        switch status.overall {
        case .failing: return Theme.removed
        case .pending: return Theme.warning
        default: return Theme.added
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "plus.rectangle.on.folder", help: "Add repository (⇧⌘O)") { app.promptAddRepository() }
            Spacer()
            ForEach([ProviderKind.claude, .codex], id: \.self) { p in
                if let u = app.usage[p] { UsageRing(provider: p, usage: u) }
            }
            IconButton(symbol: "gearshape", help: "Settings (⌘,)", active: app.settingsRoute != nil) {
                app.settingsRoute = app.settingsRoute == nil ? .general : nil
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }
}

/// Codex-style usage ring: "Weekly · 82% left".
struct UsageRing: View {
    let provider: ProviderKind
    let usage: UsageInfo

    var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, 1 - usage.usedFraction))
                .stroke(usage.usedFraction > 0.85 ? Theme.warning : Theme.text2, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ProviderIcon(provider: provider, size: 7)
        }
        .frame(width: 18, height: 18)
        .frame(width: 26, height: 26)
        .help("\(provider.displayName) · \(usage.windowLabel) · \(Int(((1 - usage.usedFraction) * 100).rounded()))% left")
    }
}

struct WorkspaceContextMenu: View {
    @Environment(AppModel.self) private var app
    let workspace: Workspace

    var body: some View {
        let model = app.model(for: workspace.id)
        Button("New chat tab") { model.newTab() }
        Button("Open in editor") { model.openInEditor() }
        Button("Reveal in Finder") { model.revealInFinder() }
        Button("Copy branch name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.branch, forType: .string)
        }
        Divider()
        Picker("Ship mode", selection: Binding(
            get: { workspace.shipModeOverride ?? app.repo(workspace.repoID)?.shipMode ?? .pullRequest },
            set: { mode in app.updateWorkspace(workspace.id) { $0.shipModeOverride = mode } }
        )) {
            ForEach(ShipMode.allCases) { Text($0.displayName).tag($0) }
        }
        Divider()
        if workspace.isArchived {
            Button("Delete permanently", role: .destructive) { Task { await app.deleteArchived(workspace) } }
        } else {
            Button("Archive") { Task { await app.archive(workspace) } }
        }
    }
}

struct ProviderIcon: View {
    let provider: ProviderKind
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: provider == .claude ? "asterisk" : "circle.hexagongrid.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(provider == .claude ? Theme.claude : Theme.codex)
    }
}
