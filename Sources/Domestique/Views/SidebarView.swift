import AgentKit
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
                IconButton(
                    symbol: "house", help: "Home",
                    active: app.selectedWorkspaceID == nil && app.selectedRepoID == nil && app.settingsRoute == nil
                ) { app.showHome() }
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
        let repo = app.selectedRepo ?? app.repositories.first
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

    /// This project's home page is on screen.
    private var isHome: Bool {
        app.selectedWorkspaceID == nil && app.selectedRepoID == repo.id && app.settingsRoute == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                RepoIconView(repo: repo, size: 18)
                    .overlay {
                        // Hovering the icon turns it into the collapse toggle.
                        if hovering {
                            Button(action: toggleCollapsed) {
                                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.text2)
                                    .frame(width: 18, height: 18)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.sidebar))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(collapsed ? "Expand" : "Collapse")
                        }
                    }
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
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius)
                    .fill(isHome ? Theme.selected : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture { app.showProject(repo) }
            .onHover { hovering = $0 }
            .help("Open \(repo.title)")

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
            Menu {
                Button("Clone from GitHub…  ⌥⌘O") { app.showGitHubPicker = true }
                Button("Add local repository…  ⇧⌘O") { app.promptAddRepository() }
            } label: {
                Image(systemName: "plus.rectangle.on.folder").font(.system(size: 13)).foregroundStyle(Theme.text2)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add repository")
            UpdateButton(updater: app.updater)
            Spacer(minLength: 4)
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

/// Bottom-left pill shown when a newer build is out: icon + the newest release's title (its changelog headline).
/// Clicking opens the list of what's new and the restart button.
private struct UpdateButton: View {
    let updater: Updater
    @State private var showDetails = false
    @State private var hovering = false

    var body: some View {
        if let newest = updater.newest {
            Button { showDetails.toggle() } label: {
                HStack(spacing: 6) {
                    UpdateStatusIcon(phase: updater.phase)
                    Text(newest.title)
                        .font(Theme.smallMedium)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 6)
                .padding(.trailing, 9)
                .frame(height: 24)
                .background(Capsule().fill(hovering || showDetails ? Theme.selected : Theme.hover))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help(newest))
            .popover(isPresented: $showDetails, arrowEdge: .top) { UpdateDetails(updater: updater) }
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
        }
    }

    private func help(_ newest: AppRelease) -> String {
        switch updater.phase {
        case .ready: "Build \(newest.build) is ready to install"
        case .failed: "Update failed. Click for details"
        default: "Build \(newest.build) is available"
        }
    }
}

private struct UpdateStatusIcon: View {
    let phase: Updater.Phase

    var body: some View {
        switch phase {
        case .checking, .downloading, .installing:
            Spinner(size: 11)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.warning)
        default:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.running)
        }
    }
}

private struct UpdateDetails: View {
    let updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available").font(Theme.uiMedium).foregroundStyle(Theme.text)
                if let newest = updater.newest {
                    Text(verbatim: "Build \(newest.build) · you have build \(updater.currentBuild)")
                        .font(Theme.small).foregroundStyle(Theme.text3)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(updater.available) { release in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(release.title).font(Theme.ui).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(subtitle(release)).font(Theme.tiny).foregroundStyle(Theme.text3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)

            Hairline()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder private var footer: some View {
        if case .failed(let message) = updater.phase {
            Text(message).font(Theme.small).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            if let url = updater.newest?.htmlURL {
                Button("Release notes") { NSWorkspace.shared.open(url) }.buttonStyle(.softCompact)
            }
            Spacer()
            switch updater.phase {
            case .ready:
                Button("Restart to Update") { updater.installAndRelaunch() }.buttonStyle(.softProminent)
            case .checking, .downloading:
                progress("Downloading…")
            case .installing:
                progress("Restarting…")
            case .failed, .idle:
                Button("Try Again") { updater.downloadNewest() }.buttonStyle(.soft)
            }
        }
        if case .ready = updater.phase {
            Text("Restarting stops running agents and tasks.").font(Theme.tiny).foregroundStyle(Theme.text3)
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 6) {
            Spinner(size: 11)
            Text(label).font(Theme.small).foregroundStyle(Theme.text2)
        }
        .frame(height: 28)
    }

    private func subtitle(_ release: AppRelease) -> String {
        guard let date = release.publishedAt else { return "Build \(release.build)" }
        return "Build \(release.build) · \(date.formatted(.relative(presentation: .named)))"
    }
}

/// Codex-style usage ring for the most-used window. Hover (or click to pin) for every window's details.
struct UsageRing: View {
    let provider: ProviderKind
    let usage: UsageInfo

    @State private var hovering = false
    @State private var showDetails = false
    @State private var pinned = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button {
            pinned.toggle()
            showDetails = pinned
        } label: {
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, 1 - usage.usedFraction))
                    .stroke(
                        UsageDetails.tint(usage.usedFraction),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                ProviderIcon(provider: provider, size: 7)
            }
            .frame(width: 18, height: 18)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering || showDetails ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            guard !pinned else { return }
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(inside ? 250 : 150))
                guard !Task.isCancelled else { return }
                showDetails = inside
            }
        }
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            UsageDetails(provider: provider, usage: usage)
        }
        .onChange(of: showDetails) { _, open in if !open { pinned = false } }
        .accessibilityLabel(
            "\(provider.displayName) usage, \(Int(((1 - usage.usedFraction) * 100).rounded())) percent left")
    }
}

/// Per-window breakdown: session, weekly, weekly per-model, with reset times.
private struct UsageDetails: View {
    let provider: ProviderKind
    let usage: UsageInfo

    static func tint(_ used: Double) -> Color {
        used >= 0.9 ? Theme.removed : used > 0.75 ? Theme.warning : Theme.text2
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    ProviderIcon(provider: provider, size: 12)
                    Text("\(provider.displayName) usage").font(Theme.uiMedium).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    if let plan = usage.plan {
                        Text(plan.capitalized).font(Theme.tiny).foregroundStyle(Theme.text3)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(usage.windows) { w in row(w, now: context.date) }
                }

                if let note = overageNote {
                    Text(note).font(Theme.tiny).foregroundStyle(usage.usingOverage ? Theme.warning : Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Hairline()
                Text(footer(now: context.date)).font(Theme.tiny).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func row(_ w: RateLimitWindow, now: Date) -> some View {
        let used = UsageInfo.used(w, now: now)
        let pct = Int((used * 100).rounded())
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(w.label).font(Theme.smallMedium).foregroundStyle(Theme.text)
                if let d = w.duration {
                    Text(d).font(Theme.tiny).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 8)
                Text("\(pct)% used").font(Theme.monoDigits).foregroundStyle(Self.tint(used))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(Self.tint(used))
                        .frame(width: max(used > 0 ? 4 : 0, geo.size.width * min(1, used)))
                }
            }
            .frame(height: 5)
            if let reset = resetText(w, now: now) {
                Text(reset).font(Theme.tiny).foregroundStyle(Theme.text3)
            }
        }
    }

    private func resetText(_ w: RateLimitWindow, now: Date) -> String? {
        if w.status == "rejected", let r = w.resetsAt, r > now {
            return "Limit reached · resets \(Self.when(r, now: now))"
        }
        guard let r = w.resetsAt else { return nil }
        if r <= now { return "Reset \(r.formatted(.relative(presentation: .named, unitsStyle: .wide)))" }
        return "Resets \(Self.when(r, now: now))"
    }

    /// "in 3h 12m" for soon, "Fri 09:00" for later in the week.
    static func when(_ date: Date, now: Date) -> String {
        let secs = date.timeIntervalSince(now)
        if secs < 24 * 3600 {
            let mins = max(1, Int(secs / 60))
            let h = mins / 60, m = mins % 60
            return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            + " (in \(Int((secs / 86400).rounded())) days)"
    }

    private var overageNote: String? {
        if usage.usingOverage { return "Using extra usage — limits reached, now drawing on overage." }
        guard provider == .claude, let status = usage.overageStatus else { return nil }
        if status == "rejected" || status == "disabled" {
            switch usage.overageDisabledReason {
            case "out_of_credits": return "Extra usage unavailable: out of credits."
            case let reason?: return "Extra usage unavailable (\(reason.replacingOccurrences(of: "_", with: " ")))."
            case nil: return "Extra usage unavailable."
            }
        }
        return "Extra usage available once limits are reached."
    }

    private func footer(now: Date) -> String {
        let ago =
            now.timeIntervalSince(usage.updatedAt) < 60
            ? "just now" : usage.updatedAt.formatted(.relative(presentation: .named))
        let partial = provider == .claude ? " Windows appear as \(provider.displayName) reports them." : ""
        return "Updated \(ago), from the last \(provider.displayName) turn.\(partial)"
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
