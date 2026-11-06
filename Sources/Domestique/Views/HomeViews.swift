import AppKit
import DQCore
import GitHubKit
import SwiftUI

// MARK: - Project home (a repository is selected, no workspace)

/// A project's landing page: identity, quick actions, its workspaces and open pull requests.
struct ProjectHomeView: View {
    @Environment(AppModel.self) private var app
    let repo: Repository

    @State private var prs: [PullRequestSummary] = []
    @State private var loadingPRs = false
    @State private var prError: String?
    @State private var loadedOnce = false

    var body: some View {
        VStack(spacing: 0) {
            HomeHeaderBar {
                HStack(spacing: 7) {
                    RepoIconView(repo: repo, size: 16)
                    Text(repo.title).font(Theme.uiMedium).foregroundStyle(Theme.text)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    hero
                    workspacesSection
                    pullRequestsSection
                }
                .frame(maxWidth: Theme.contentWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 36)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .background(alignment: .top) {
            let tint = RepoIconStyle.tint(repo)
            PageWash(colors: [tint, tint.opacity(0.6)], height: 380)
        }
        .background(Theme.canvas)
        .task(id: repo.id) { await loadPRs() }
    }

    // MARK: hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            identity
            actions
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 18) {
            RepoIconView(repo: repo, size: 64)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(repo.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if let slug = repo.githubSlug {
                        MetaChip(symbol: "globe", text: slug)
                    }
                    MetaChip(symbol: "arrow.triangle.branch", text: repo.defaultBranch)
                    if repo.shipMode == .trunk { MetaChip(symbol: "arrow.up.to.line", text: "trunk") }
                }
                Text(displayPath(repo.path))
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 16)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New workspace with Claude") { newWorkspace(.claude) }
                Button("New workspace with Codex") { newWorkspace(.codex) }
                if repo.githubSlug != nil {
                    Divider()
                    Button("New workspace from pull request…") { app.pullRequestPickerRepo = repo }
                }
            } label: {
                Label("New workspace", systemImage: "square.and.pencil")
            } primaryAction: {
                newWorkspace(nil)
            }
            .menuStyle(.button)
            .buttonStyle(.softProminent)
            .fixedSize()
            .help("Fresh worktree from origin/\(repo.defaultBranch) (⌘N)")

            if let url = githubURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.soft)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            } label: {
                Label("Finder", systemImage: "folder")
            }
            .buttonStyle(.soft)
            Button { app.settingsRoute = .repo(repo.id) } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.soft)
            Spacer()
        }
        .labelStyle(.titleAndIcon)
    }

    // MARK: workspaces

    private var workspacesSection: some View {
        let workspaces = app.activeWorkspaces(in: repo)
        return VStack(alignment: .leading, spacing: 10) {
            HomeSectionTitle(title: "Workspaces", count: workspaces.count)
            if workspaces.isEmpty {
                DashedEmptyState(message: "No workspaces yet. Each one is an isolated worktree branched from a fresh origin/\(repo.defaultBranch).") {
                    Button("New workspace") { newWorkspace(nil) }.buttonStyle(.soft)
                }
                .frame(maxWidth: .infinity)
            } else {
                Card {
                    ForEach(Array(workspaces.enumerated()), id: \.element.id) { i, ws in
                        if i > 0 { Hairline().padding(.leading, 40) }
                        ProjectWorkspaceRow(workspace: ws, pr: prs.first { $0.number == ws.prNumber || $0.headRefName == ws.branch })
                    }
                }
            }
        }
    }

    // MARK: pull requests

    private var pullRequestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HomeSectionTitle(title: "Open pull requests", count: loadedOnce && prError == nil ? prs.count : nil)
                if loadingPRs { Spinner(size: 10) }
                Spacer()
                if repo.githubSlug != nil {
                    IconButton(symbol: "arrow.clockwise", help: "Refresh", size: 11) { Task { await loadPRs() } }
                        .disabled(loadingPRs)
                }
            }
            if repo.githubSlug == nil {
                HomeNote(symbol: "link.badge.plus", text: "This repository has no GitHub remote, so there are no pull requests to show.")
            } else if let prError {
                HomeNote(symbol: "exclamationmark.triangle", text: prError, tint: Theme.warning) {
                    Button("Retry") { Task { await loadPRs() } }.buttonStyle(.softCompact)
                }
            } else if !loadedOnce {
                Card {
                    ForEach(0..<3, id: \.self) { i in
                        if i > 0 { Hairline().padding(.leading, 40) }
                        PRSkeletonRow()
                    }
                }
            } else if prs.isEmpty {
                HomeNote(symbol: "checkmark.circle", text: "No open pull requests. All caught up.")
            } else {
                Card {
                    ForEach(Array(prs.enumerated()), id: \.element.id) { i, pr in
                        if i > 0 { Hairline().padding(.leading, 40) }
                        PullRequestRow(repo: repo, pr: pr, workspace: workspace(for: pr))
                    }
                }
            }
        }
    }

    // MARK: helpers

    private func workspace(for pr: PullRequestSummary) -> Workspace? {
        app.workspace(for: pr, in: repo)
    }

    private var githubURL: URL? {
        repo.githubSlug.flatMap { URL(string: "https://github.com/\($0)") }
    }

    private func newWorkspace(_ provider: ProviderKind?) {
        Task { await app.createWorkspace(in: repo, provider: provider) }
    }

    private func loadPRs() async {
        guard let slug = repo.githubSlug else { return }
        loadingPRs = true
        defer { loadingPRs = false }
        do {
            prs = try await GitHubClient.shared.openPullRequests(slug: slug)
            prError = nil
        } catch {
            if !Task.isCancelled { prError = error.localizedDescription }
        }
        loadedOnce = true
    }
}

private struct ProjectWorkspaceRow: View {
    @Environment(AppModel.self) private var app
    let workspace: Workspace
    let pr: PullRequestSummary?

    var body: some View {
        let model = app.existingModel(for: workspace.id)
        HoverRow(height: 48, action: { app.selectedWorkspaceID = workspace.id }) {
            HStack(spacing: 12) {
                WorkspaceGlyph(workspace: workspace, model: model)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.uiMedium)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(workspace.branch).font(Theme.monoSmall)
                        Text("·")
                        Text(workspace.createdAt, format: .relative(presentation: .named))
                    }
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let model, !model.diffFiles.isEmpty {
                    DiffCount(additions: model.diffStat.additions, deletions: model.diffStat.deletions)
                }
                if let n = workspace.prNumber ?? pr?.number {
                    Text(verbatim: "#\(n)")
                        .font(Theme.monoDigits)
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.hover, in: Capsule())
                }
                if workspace.hasUnread {
                    Circle().fill(Theme.running).frame(width: 6, height: 6)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
            }
        }
        .contextMenu { WorkspaceContextMenu(workspace: workspace) }
    }

    private var title: String {
        let tab = workspace.tabs.first { $0.id == workspace.selectedTabID } ?? workspace.tabs.first
        if let t = tab?.title, t != "New chat" { return t }
        return workspace.name.capitalized
    }
}

private struct PullRequestRow: View {
    @Environment(AppModel.self) private var app
    let repo: Repository
    let pr: PullRequestSummary
    let workspace: Workspace?

    var body: some View {
        HoverRow(height: 52, action: open) {
            HStack(spacing: 12) {
                Image(systemName: pr.isDraft ? "circle.dashed" : "arrow.triangle.pull")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(pr.isDraft ? Theme.text3 : Theme.added)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .font(Theme.uiMedium)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(verbatim: "#\(pr.number)").font(Theme.monoDigits)
                        if let login = pr.authorLogin {
                            Text("·")
                            Avatar(url: pr.authorAvatarURL, size: 14)
                            Text(login)
                        }
                        if let updated = pr.updatedAt {
                            Text("·")
                            Text(updated, format: .relative(presentation: .named))
                        }
                        if pr.comments > 0 {
                            Text("·")
                            Label("\(pr.comments)", systemImage: "bubble.left").labelStyle(.titleAndIcon)
                        }
                    }
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if workspace != nil {
                    Text("Workspace")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.running)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.running.opacity(0.12), in: Capsule())
                }
                ReviewBadge(decision: pr.reviewDecision, draft: pr.isDraft)
                ChecksDot(state: pr.checks)
                DiffCount(additions: pr.additions, deletions: pr.deletions)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .help(workspace != nil ? "Open workspace for \(pr.headRefName)" : "New workspace on #\(pr.number) (\(pr.headRefName))")
        .contextMenu {
            if workspace != nil {
                Button("Open workspace", action: open)
            } else {
                Button("New workspace on #\(pr.number)", action: open)
                if let choices = app.newWorkspaceChoices(for: repo) {
                    Menu("New workspace on #\(pr.number) on") {
                        NewWorkspaceMenuSections(locations: choices, defaultLocation: app.defaultLocation(for: repo)) { loc in
                            Task { await app.openPullRequest(pr, in: repo, location: loc) }
                        }
                    }
                }
            }
            Divider()
            if let url = URL(string: pr.url) {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pr.url, forType: .string)
                }
            }
            Button("Copy branch name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.headRefName, forType: .string)
            }
        }
    }

    private func open() {
        if let workspace {
            app.selectedWorkspaceID = workspace.id
        } else {
            Task { await app.openPullRequest(pr, in: repo) }
        }
    }
}

private struct ReviewBadge: View {
    let decision: String?
    let draft: Bool

    var body: some View {
        if draft {
            badge("Draft", Theme.text2)
        } else {
            switch decision {
            case "APPROVED": badge("Approved", Theme.added)
            case "CHANGES_REQUESTED": badge("Changes", Theme.removed)
            case "REVIEW_REQUIRED": badge("Review", Theme.warning)
            default: EmptyView()
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }
}

private struct ChecksDot: View {
    let state: ChecksOverall

    var body: some View {
        switch state {
        case .none:
            Color.clear.frame(width: 12, height: 12)
        case .passing:
            icon("checkmark.circle.fill", Theme.added, "Checks passing")
        case .failing:
            icon("xmark.circle.fill", Theme.removed, "Checks failing")
        case .pending:
            icon("clock.fill", Theme.warning, "Checks running")
        }
    }

    private func icon(_ s: String, _ c: Color, _ help: String) -> some View {
        Image(systemName: s).font(.system(size: 12)).foregroundStyle(c).help(help)
    }
}

private struct PRSkeletonRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.hover).frame(width: 14, height: 14).frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.hover).frame(width: 260, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(Theme.hover).frame(width: 160, height: 8)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .opacity(pulse ? 0.5 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Welcome (no project selected)

/// Domestique's front door: open a GitHub project, add a local one, or jump back into a known project.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app

    @State private var ghRepos: [GitHubRepo] = []
    @State private var ghLoading = true
    @State private var ghError: String?
    @State private var cloning: GitHubRepo.ID?
    @State private var cloneError: String?

    var body: some View {
        VStack(spacing: 0) {
            HomeHeaderBar { EmptyView() }
            ScrollView {
                VStack(spacing: 40) {
                    hero
                    if !app.repositories.isEmpty { projectsSection }
                    githubSection
                    shortcuts
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 32)
                .padding(.top, 56)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .background(alignment: .top) { PageWash(colors: [Brand.violet, Brand.sunset], height: 520) }
        .background(Theme.canvas)
        .task { await loadGitHub() }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            DomestiqueMark(size: 96)
            Text("Domestique")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Run Claude Code and Codex side by side, each in its own git worktree\nbranched from a fresh origin.")
                .font(Theme.body)
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            HStack(spacing: 8) {
                Button { app.showGitHubPicker = true } label: {
                    Label("Open from GitHub…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.softProminent)
                Button { app.promptAddRepository() } label: {
                    Label("Add local repository…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.soft)
            }
            .labelStyle(.titleAndIcon)
            .padding(.top, 8)
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionTitle(title: "Your projects", count: app.repositories.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                ForEach(app.repositories) { repo in
                    ProjectTile(repo: repo, active: app.activeWorkspaces(in: repo).count) { app.showProject(repo) }
                }
            }
        }
    }

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HomeSectionTitle(title: "Recent on GitHub", count: nil)
                if ghLoading && !ghRepos.isEmpty { Spinner(size: 10) }
                Spacer()
                Button("Browse all") { app.showGitHubPicker = true }
                    .buttonStyle(.plain)
                    .font(Theme.small)
                    .foregroundStyle(Theme.text2)
            }
            if let ghError {
                HomeNote(symbol: "person.crop.circle.badge.exclamationmark", text: ghError, tint: Theme.warning) {
                    Button("Retry") {
                        Task {
                            await GitHubClient.shared.resetToken()
                            await loadGitHub()
                        }
                    }
                    .buttonStyle(.softCompact)
                }
            } else if ghLoading && ghRepos.isEmpty {
                Card {
                    ForEach(0..<4, id: \.self) { i in
                        if i > 0 { Hairline().padding(.leading, 40) }
                        PRSkeletonRow()
                    }
                }
            } else if ghRepos.isEmpty {
                HomeNote(symbol: "tray", text: "No repositories found on your GitHub account.")
            } else {
                Card {
                    ForEach(Array(ghRepos.enumerated()), id: \.element.id) { i, gh in
                        if i > 0 { Hairline().padding(.leading, 40) }
                        GitHubRepoRow(
                            repo: gh, added: app.localRepository(for: gh) != nil, cloning: cloning == gh.id,
                            disabled: cloning != nil
                        ) { open(gh) }
                    }
                }
                if let cloneError {
                    Text(cloneError).font(Theme.small).foregroundStyle(Theme.warning).textSelection(.enabled)
                }
            }
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 18) {
            ShortcutHint(keys: "⌥⌘O", label: "Open from GitHub")
            ShortcutHint(keys: "⇧⌘O", label: "Add local")
            ShortcutHint(keys: "⌘N", label: "New workspace")
        }
        .frame(maxWidth: .infinity)
    }

    private func loadGitHub() async {
        ghLoading = true
        defer { ghLoading = false }
        do {
            let all = try await GitHubClient.shared.listRepositories(maxPages: 1).filter { !$0.isArchived }
            ghRepos = Array(all.prefix(8))
            ghError = nil
        } catch {
            if !Task.isCancelled { ghError = error.localizedDescription }
        }
    }

    private func open(_ gh: GitHubRepo) {
        if let existing = app.localRepository(for: gh) { return app.showProject(existing) }
        guard cloning == nil else { return }
        cloning = gh.id
        cloneError = nil
        Task {
            do {
                try await app.cloneFromGitHub(gh)
            } catch {
                cloneError = error.localizedDescription
            }
            cloning = nil
        }
    }
}

private struct ProjectTile: View {
    let repo: Repository
    let active: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RepoIconView(repo: repo, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.title).font(Theme.uiMedium).foregroundStyle(Theme.text).lineLimit(1)
                    Text(active == 0 ? "No workspaces" : active == 1 ? "1 workspace" : "\(active) workspaces")
                        .font(Theme.small).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(
                    LinearGradient(
                        colors: [RepoIconStyle.tint(repo).opacity(hovering ? 0.14 : 0.08), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.hover : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(repo.githubSlug ?? repo.path)
    }
}

private struct GitHubRepoRow: View {
    let repo: GitHubRepo
    let added: Bool
    let cloning: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(height: 50, action: action) {
            HStack(spacing: 12) {
                Avatar(url: "https://github.com/\(repo.owner).png?size=64", size: 22, square: true)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(repo.owner + "/").foregroundStyle(Theme.text2)
                            + Text(repo.name).foregroundStyle(Theme.text).fontWeight(.medium)
                        if repo.isPrivate {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.text3)
                        }
                    }
                    .font(Theme.ui)
                    .lineLimit(1)
                    if let d = repo.description, !d.isEmpty {
                        Text(d).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if cloning {
                    HStack(spacing: 6) {
                        Spinner(size: 10)
                        Text("Cloning…").font(Theme.small).foregroundStyle(Theme.text2)
                    }
                } else if added {
                    Text("Open").font(Theme.smallMedium).foregroundStyle(Theme.text2)
                } else {
                    if let pushed = repo.pushedAt {
                        Text(pushed, format: .relative(presentation: .named))
                            .font(Theme.small).foregroundStyle(Theme.text3)
                    }
                    Text("Clone").font(Theme.smallMedium).foregroundStyle(Theme.text)
                        .padding(.horizontal, 8).frame(height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
                }
            }
        }
        .disabled(disabled && !cloning)
        .help(repo.fullName)
    }
}

private struct ShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.sunken))
            Text(label).font(Theme.small).foregroundStyle(Theme.text3)
        }
    }
}

// MARK: - Shared pieces

/// The official Domestique app icon. Bundled builds read it from the app; `swift run` has no bundle,
/// so it's loaded straight from the asset catalog in the source tree.
struct DomestiqueMark: View {
    var size: CGFloat = 96

    var body: some View {
        Image(nsImage: Self.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: Brand.violet.opacity(0.25), radius: size * 0.16, y: size * 0.06)
    }

    @MainActor static let icon: NSImage = {
        if Bundle.main.bundleURL.pathExtension == "app" { return NSApp.applicationIconImage }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
        return NSImage(contentsOf: source) ?? NSApp.applicationIconImage
    }()
}

/// Colours sampled from the app icon (dusk violet → sunset orange), for subtle washes.
enum Brand {
    static let violet = Color(red: 0.43, green: 0.38, blue: 0.86)
    static let sunset = Color(red: 1.0, green: 0.56, blue: 0.40)
}

/// Soft top-of-page wash that fades into the canvas.
private struct PageWash: View {
    let colors: [Color]
    var height: CGFloat = 420

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: colors.map { $0.opacity(0.09) } + [.clear], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [(colors.last ?? .clear).opacity(0.07), .clear], center: .top, startRadius: 0,
                endRadius: height)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

/// A gentle top-lit sheen for raised surfaces.
private struct Sheen: View {
    var radius: CGFloat = Theme.cardRadius
    var tint: Color = .white

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(LinearGradient(colors: [tint.opacity(0.05), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
    }
}

/// Header row for the home pages: window drag area, sidebar toggle when hidden.
private struct HomeHeaderBar<Content: View>: View {
    @Environment(AppModel.self) private var app
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            if !app.sidebarVisible {
                Spacer().frame(width: 70)
                IconButton(symbol: "sidebar.left", help: "Show sidebar (⌘\\)") { app.sidebarVisible = true }
            }
            content
            Spacer()
        }
        .padding(.horizontal, 14)
        .headerBar()
    }
}

private struct HomeSectionTitle: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.smallMedium).foregroundStyle(Theme.text2)
            if let count {
                Text(verbatim: "\(count)").font(Theme.small).foregroundStyle(Theme.text3)
            }
        }
        .textCase(nil)
    }
}

private struct MetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text).lineLimit(1)
        }
        .font(Theme.small)
        .foregroundStyle(Theme.text2)
    }
}

/// Bordered list container.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(4)
            .background(Sheen())
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.raised))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(
                        LinearGradient(colors: [Theme.border, Theme.hairline], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5))
    }
}

private struct HomeNote<Trailing: View>: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.text3
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint)
            Text(text).font(Theme.ui).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.sunken))
    }
}

extension HomeNote where Trailing == EmptyView {
    init(symbol: String, text: String, tint: Color = Theme.text3) {
        self.init(symbol: symbol, text: text, tint: tint) { EmptyView() }
    }
}

private struct Avatar: View {
    let url: String?
    var size: CGFloat = 16
    var square = false

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).scaledToFill()
            } else {
                Theme.hover
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: square ? size * 0.25 : size / 2))
    }
}

private func displayPath(_ p: String) -> String {
    p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
}
