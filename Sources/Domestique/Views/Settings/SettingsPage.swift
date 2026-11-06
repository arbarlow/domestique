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
                        case .cloud: SandboxProviderSettings()
                        case .teamCars: TeamCarSettings()
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
                navRow(.general, "General", "gearshape.fill", .gray)
                navRow(.agents, "Agents", "sparkles", .purple)
                navRow(.teamCars, "Team Cars", "server.rack", .blue)
                navRow(.cloud, "Sandbox Providers", "shippingbox.fill", .teal)
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

    private func navRow(_ r: SettingsRoute, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        HoverRow(selected: route == r, height: 30, action: { app.settingsRoute = r }) {
            HStack(spacing: 8) {
                SettingsIconTile(symbol: symbol, tint: tint)
                Text(title).font(Theme.ui).foregroundStyle(Theme.text)
            }
        }
    }
}

/// A white glyph on a coloured rounded square, like System Settings. Same size as repository icons
/// in the list below, so the column lines up.
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
            if !title.isEmpty || subtitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if !title.isEmpty { Text(title).font(Theme.ui).foregroundStyle(Theme.text) }
                    if let subtitle {
                        Text(subtitle).font(Theme.small).foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }
}

struct PageTitle<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(Theme.ui).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.bottom, 22)
    }
}

extension PageTitle where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.ui)
            .padding(.horizontal, 8)
            .frame(width: 220, height: 26)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

struct PathValue: View {
    let path: String
    var body: some View {
        HStack(spacing: 4) {
            Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(Theme.small)
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .trailing)
                .textSelection(.enabled)
                .help(path)
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
            SettingsSection(
                title: "Ship prompts",
                footer: "What the agent is told when you ship from the panel. {base} and {branch} are filled in for you; edit freely, or reset to the built-in prompt."
            ) {
                ForEach(ShipPromptKind.allCases) { ShipPromptEditor(kind: $0) }
            }
            Text("Domestique runs your own `claude` and `codex` with their existing logins (Claude subscription / ChatGPT). It never sees the tokens.")
                .font(Theme.small)
                .foregroundStyle(Theme.text3)
        }
    }
}

/// One ship prompt: a one-line summary that opens into an editor, so the page stays scannable.
private struct ShipPromptEditor: View {
    @Environment(AppModel.self) private var app
    let kind: ShipPromptKind
    @State private var expanded = false

    var body: some View {
        let customized = app.settings.isShipPromptCustomized(kind)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kind.displayName).font(Theme.ui).foregroundStyle(Theme.text)
                        if customized {
                            Text("Customized")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.running)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.running.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(kind.summary).font(Theme.small).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 12)
                if customized, expanded {
                    Button("Reset") { app.settings.setShipPromptTemplate(kind, nil) }
                        .buttonStyle(.softCompact)
                        .help("Go back to the built-in prompt")
                }
                Button(expanded ? "Done" : "Edit") {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(.softCompact)
            }
            if expanded {
                TextEditor(text: Binding(
                    get: { app.settings.shipPromptTemplate(kind) },
                    set: { app.settings.setShipPromptTemplate(kind, $0) }
                ))
                .font(Theme.mono)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 140)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
                Text(kind.placeholders.map { "\($0.token) \($0.meaning)" }.joined(separator: " · "))
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
                SettingsRow(title: "Run new workspaces on", subtitle: "This Mac (git worktree), a cloud sandbox, or one of your Team Cars") {
                    Picker("", selection: Binding(
                        get: { app.repo(repo.id)?.defaultLocation ?? .local },
                        set: { l in app.updateRepo(repo.id) { $0.defaultLocation = l == .local ? nil : l } }
                    )) {
                        ForEach(app.workspaceLocations) { Text(app.locationName($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Default branch", subtitle: "New workspaces branch from a fresh origin/\(repo.defaultBranch)") {
                    Text(repo.defaultBranch).font(Theme.mono).foregroundStyle(Theme.text2)
                }
                SettingsRow(title: "Location") { PathValue(path: repo.path) }
                SettingsRow(title: "Config", subtitle: configSubtitle) {
                    Button(hasConfig ? "Open" : "Create") {
                        let path = repo.path + "/" + RepoConfig.fileName
                        if !hasConfig { try? RepoConfig.template.write(toFile: path, atomically: true, encoding: .utf8) }
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .buttonStyle(.softCompact)
                }
            }

            SettingsSection(title: "Danger zone") {
                SettingsRow(title: "Remove repository", subtitle: "Archive its workspaces first. Your clone isn't touched.") {
                    Button("Remove…") { confirmRemove = true }
                        .buttonStyle(.softDestructive)
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
        hasConfig
            ? "\(RepoConfig.fileName) in the main checkout: setup, run tasks and ship gates"
            : "No \(RepoConfig.fileName) yet. It defines setup, run tasks and ship gates"
    }
}
