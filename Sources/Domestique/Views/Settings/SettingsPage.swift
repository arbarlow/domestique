import DQCore
import SwiftUI

/// Settings shown inside the main window (replaces the conversation + panel while open).
struct SettingsPage: View {
    @Environment(AppModel.self) private var app
    let route: SettingsRoute

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !app.sidebarVisible {
                    Spacer().frame(width: 70)
                    IconButton(symbol: "sidebar.left", help: "Show sidebar (⌘\\)") { app.sidebarVisible = true }
                }
                Image(systemName: "gearshape").foregroundStyle(Theme.text2)
                Text("Settings").font(Theme.uiMedium).foregroundStyle(Theme.text)
                Spacer()
                IconButton(symbol: "xmark", help: "Close settings (Esc)") { app.settingsRoute = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .headerBar()
            Hairline()
            HStack(spacing: 0) {
                SettingsNav(route: route)
                    .frame(width: 210)
                Hairline(vertical: true)
                ScrollView {
                    Group {
                        switch route {
                        case .general: GeneralSettings()
                        case .agents: AgentSettings()
                        case .repo(let id):
                            if let repo = app.repo(id) {
                                RepoSettings(repo: repo)
                            } else {
                                Text("Repository not found").foregroundStyle(Theme.text2)
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.canvas)
    }
}

private struct SettingsNav: View {
    @Environment(AppModel.self) private var app
    let route: SettingsRoute

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                navRow(.general, "General", "slider.horizontal.3")
                navRow(.agents, "Agents", "sparkles")
                Text("Repositories")
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 8)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                ForEach(app.repositories) { repo in
                    HoverRow(selected: route == .repo(repo.id), height: 30, action: { app.settingsRoute = .repo(repo.id) }) {
                        HStack(spacing: 8) {
                            RepoIconView(repo: repo, size: 18)
                            Text(repo.title).font(Theme.ui).foregroundStyle(Theme.text).lineLimit(1)
                        }
                    }
                }
                HoverRow(height: 30, action: { app.promptAddRepository() }) {
                    Label("Add repository…", systemImage: "plus").font(Theme.ui).foregroundStyle(Theme.text2)
                }
            }
            .padding(10)
        }
        .background(Theme.sidebar.opacity(0.5))
    }

    private func navRow(_ r: SettingsRoute, _ title: String, _ symbol: String) -> some View {
        HoverRow(selected: route == r, height: 30, action: { app.settingsRoute = r }) {
            Label(title, systemImage: symbol).font(Theme.ui).foregroundStyle(Theme.text)
        }
    }
}

// MARK: - Building blocks

struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.smallMedium).foregroundStyle(Theme.text2)
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { i, view in
                        if i > 0 { Hairline().padding(.leading, 14) }
                        view
                    }
                }
            }
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 0.5))
            if let footer {
                Text(footer).font(Theme.small).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 24)
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
    }
}

private struct PageTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
            if let subtitle { Text(subtitle).font(Theme.ui).foregroundStyle(Theme.text2) }
        }
        .padding(.bottom, 22)
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.ui)
            .padding(.horizontal, 8)
            .frame(width: 220, height: 26)
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct PathValue: View {
    let path: String
    var body: some View {
        HStack(spacing: 4) {
            Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(Theme.small)
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            IconButton(symbol: "folder", help: "Reveal in Finder", size: 11) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "General")
            SettingsSection(title: "Workspaces") {
                SettingsRow(title: "Branch prefix", subtitle: "New branches are named prefix/workspace") {
                    TextField("alex", text: $app.settings.branchPrefix).modifier(FieldStyle())
                }
                SettingsRow(title: "Editor command", subtitle: "Used by Open in editor") {
                    TextField("cursor", text: $app.settings.editorCommand).modifier(FieldStyle())
                }
                SettingsRow(title: "Worktrees") { PathValue(path: Paths.workspacesRoot.path) }
                SettingsRow(title: "Clone location", subtitle: "Where Clone from GitHub puts repositories") {
                    TextField(
                        Paths.defaultCloneRoot.path.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"),
                        text: Binding(
                            get: { app.settings.cloneDirectory ?? "" },
                            set: { app.settings.cloneDirectory = $0.isEmpty ? nil : $0 })
                    ).modifier(FieldStyle())
                }
                SettingsRow(title: "Database", subtitle: "Shared by every running copy of Domestique") {
                    PathValue(path: Paths.database.path)
                }
            }
        }
    }
}

// MARK: - Agents

private struct AgentSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Agents", subtitle: "Defaults for new chats. Each chat can change these from the composer.")
            SettingsSection(title: "Defaults") {
                SettingsRow(title: "Provider") {
                    Picker("", selection: $app.settings.defaultProvider) {
                        ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Permissions", subtitle: "Full access never asks; Auto lets the provider's reviewer decide") {
                    Picker("", selection: $app.settings.defaultPermissionMode) {
                        ForEach(AgentPermissionMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            ProviderDefaults(provider: .claude, model: $app.settings.defaultClaudeModel, effort: $app.settings.defaultClaudeEffort)
            ProviderDefaults(provider: .codex, model: $app.settings.defaultCodexModel, effort: $app.settings.defaultCodexEffort)
            Text("Domestique runs your own `claude` and `codex` with their existing logins (Claude subscription / ChatGPT). It never sees the tokens.")
                .font(Theme.small)
                .foregroundStyle(Theme.text3)
        }
    }
}

private struct ProviderDefaults: View {
    @Environment(AppModel.self) private var app
    let provider: ProviderKind
    @Binding var model: String?
    @Binding var effort: String?

    var body: some View {
        let resolved = app.resolvedModel(provider, model)
        SettingsSection(title: provider.displayName) {
            SettingsRow(title: "Model") {
                Picker("", selection: $model) {
                    Text("Default · \(app.modelLabel(provider, nil))").tag(String?.none)
                    ForEach(app.pickableModels(for: provider)) { Text($0.displayName).tag(Optional($0.id)) }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow(title: "Thinking", subtitle: resolved?.efforts.isEmpty == false ? nil : "Not supported by this model") {
                Picker("", selection: $effort) {
                    Text("Model default").tag(String?.none)
                    ForEach(resolved?.efforts ?? [], id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                }
                .labelsHidden().fixedSize()
                .disabled(resolved?.efforts.isEmpty ?? true)
            }
        }
    }
}

// MARK: - Repository

private struct RepoSettings: View {
    @Environment(AppModel.self) private var app
    let repo: Repository
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                RepoIconView(repo: repo, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(repo.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(repo.githubSlug ?? repo.remoteURL ?? repo.path).font(Theme.ui).foregroundStyle(Theme.text2)
                }
            }
            .padding(.bottom, 24)

            RepoIconPicker(repo: repo)

            SettingsSection(title: "Details") {
                SettingsRow(title: "Name", subtitle: "Shown in the sidebar") {
                    TextField(repo.name, text: Binding(
                        get: { app.repo(repo.id)?.displayName ?? "" },
                        set: { v in app.updateRepo(repo.id) { $0.displayName = v.isEmpty ? nil : v } }
                    ))
                    .modifier(FieldStyle())
                }
                SettingsRow(title: "Ship mode", subtitle: "Pull requests, or push straight to \(repo.defaultBranch)") {
                    Picker("", selection: Binding(
                        get: { app.repo(repo.id)?.shipMode ?? .pullRequest },
                        set: { m in app.updateRepo(repo.id) { $0.shipMode = m } }
                    )) {
                        ForEach(ShipMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Default branch", subtitle: "New workspaces branch from a fresh origin/\(repo.defaultBranch)") {
                    Text(repo.defaultBranch).font(Theme.mono).foregroundStyle(Theme.text2)
                }
                SettingsRow(title: "Location") { PathValue(path: repo.path) }
                SettingsRow(title: "Config", subtitle: configSubtitle) {
                    Button("Open") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: repo.path + "/" + RepoConfig.fileName))
                    }
                    .buttonStyle(.softCompact)
                    .disabled(!hasConfig)
                }
            }

            SettingsSection(title: "Danger zone") {
                SettingsRow(title: "Remove repository", subtitle: "Archive its workspaces first. Your clone isn't touched.") {
                    Button("Remove…") { confirmRemove = true }
                        .buttonStyle(.softCompact)
                        .foregroundStyle(Theme.removed)
                }
            }
        }
        .confirmationDialog("Remove \(repo.title) from Domestique?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                app.removeRepository(repo)
                if app.repo(repo.id) == nil { app.settingsRoute = .general }
            }
        }
    }

    private var hasConfig: Bool { FileManager.default.fileExists(atPath: repo.path + "/" + RepoConfig.fileName) }
    private var configSubtitle: String {
        hasConfig ? "\(RepoConfig.fileName) in the main checkout" : "No \(RepoConfig.fileName) in the main checkout"
    }
}
