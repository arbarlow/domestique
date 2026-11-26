import DQCore
import SwiftUI

/// ⌘K: jump to a workspace or project, or run a command, from the keyboard. Replaces the sidebar's
/// old Home / New workspace entries. Typing ">" narrows to commands.
struct QuickOpenView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text3)
                TextField("Search workspaces, chats, files and commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { run(results) }
                Text("esc").font(Theme.small).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)

            if !results.isEmpty {
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                if i == 0 || results[i - 1].section != item.section {
                                    Text(item.section.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.text3)
                                        .padding(.horizontal, 12)
                                        .padding(.top, i == 0 ? 6 : 12)
                                        .padding(.bottom, 4)
                                }
                                QuickOpenRow(item: item, query: highlight, selected: i == selection)
                                    .id(item.id)
                                    .onTapGesture { selection = i; run(results) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(420, listHeight(results)))
                    .onChange(of: selection) { _, i in
                        if results.indices.contains(i) { proxy.scrollTo(results[i].id) }
                    }
                }
            }
            Hairline()
            HStack(spacing: 16) {
                Text("↑↓ to move")
                Text("↩ to open")
                Spacer()
                Text("> for commands")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 18)
            .frame(height: 34)
        }
        .frame(width: 620)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 30, y: 16)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) { move(1, results.count); return .handled }
        .onKeyPress(.upArrow) { move(-1, results.count); return .handled }
        .onKeyPress(.escape) { app.showQuickOpen = false; return .handled }
    }

    /// The list's natural height (rows + section titles + padding), so short result lists don't leave a gap.
    private func listHeight(_ results: [QuickOpenItem]) -> CGFloat {
        var h: CGFloat = 12
        for (i, item) in results.enumerated() {
            if i == 0 || results[i - 1].section != item.section { h += i == 0 ? 25 : 31 }
            h += (item.section == .chats ? 44 : item.section == .workspaces ? 38 : 32) + 1
        }
        return h
    }

    private func move(_ by: Int, _ count: Int) {
        guard count > 0 else { return }
        selection = (selection + by + count) % count
    }

    private func run(_ results: [QuickOpenItem]) {
        guard results.indices.contains(selection) else { return }
        app.showQuickOpen = false
        results[selection].action()
    }

    // MARK: results

    /// The text to embolden in results.
    private var highlight: String {
        let raw = query.trimmingCharacters(in: .whitespaces)
        return (raw.hasPrefix(">") ? String(raw.dropFirst()) : raw).trimmingCharacters(in: .whitespaces)
    }

    private var results: [QuickOpenItem] {
        let raw = query.trimmingCharacters(in: .whitespaces)
        let commandsOnly = raw.hasPrefix(">")
        let q = (commandsOnly ? String(raw.dropFirst()) : raw).trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ fields: [String]) -> Bool {
            q.isEmpty || fields.contains { $0.lowercased().contains(q) }
        }

        var out: [QuickOpenItem] = []
        if !commandsOnly {
            for repo in app.repositories {
                for ws in app.activeWorkspaces(in: repo) where matches([ws.displayTitle, ws.name, ws.branch, repo.title]) {
                    out.append(QuickOpenItem(
                        id: "ws-\(ws.id)", section: .workspaces, symbol: "arrow.triangle.branch",
                        title: ws.displayTitle, detail: "\(repo.title) · \(ws.name)", workspace: ws
                    ) { app.selectedWorkspaceID = ws.id })
                }
            }
            if q.count >= 2 {
                for repo in app.repositories {
                    for ws in app.activeWorkspaces(in: repo) {
                        guard let model = app.existingModel(for: ws.id) else { continue }
                        for hit in model.searchChats(q) {
                            out.append(QuickOpenItem(
                                id: "chat-\(ws.id)-\(hit.tabID)-\(hit.date.timeIntervalSince1970)", section: .chats,
                                symbol: "bubble.left", title: hit.text,
                                detail: "\(ws.displayTitle) · \(hit.date.formatted(date: .omitted, time: .shortened))"
                            ) {
                                app.selectedWorkspaceID = ws.id
                                model.selectTab(hit.tabID)
                            })
                        }
                    }
                }
                if let model = app.selectedWorkspaceModel {
                    let ranked = model.files.filter { $0.lowercased().contains(q) }
                        .sorted { ($0 as NSString).lastPathComponent.lowercased().contains(q) && !($1 as NSString).lastPathComponent.lowercased().contains(q) }
                    for path in ranked.prefix(6) {
                        out.append(QuickOpenItem(
                            id: "file-\(path)", section: .files, symbol: "doc",
                            title: (path as NSString).lastPathComponent, detail: (path as NSString).deletingLastPathComponent
                        ) { model.openFile(path) })
                    }
                }
            }
            for repo in app.repositories where !q.isEmpty && matches([repo.title, repo.name]) {
                out.append(QuickOpenItem(
                    id: "repo-\(repo.id)", section: .projects, symbol: "folder", title: repo.title, detail: repo.path
                ) { app.showProject(repo) })
            }
        }
        out += commands.filter { matches([$0.title]) }
        return out
    }

    private var commands: [QuickOpenItem] {
        var cmds: [QuickOpenItem] = []
        func cmd(_ id: String, _ symbol: String, _ title: String, _ shortcut: String? = nil, _ action: @escaping () -> Void) {
            cmds.append(QuickOpenItem(id: "cmd-\(id)", section: .commands, symbol: symbol, title: title, detail: shortcut, action: action))
        }
        for repo in app.repositories {
            cmd("new-\(repo.id)", "square.and.pencil", "New workspace in \(repo.title)", repo.id == (app.selectedRepo ?? app.repositories.first)?.id ? "⌘N" : nil) {
                Task { await app.createWorkspace(in: repo) }
            }
        }
        if let model = app.selectedWorkspaceModel {
            cmd("run", "play", "Run stack", "⌘R") { model.startDefaultStack() }
            cmd("terminal", "terminal", "New terminal", "⌃`") { model.newTerminal() }
            if let ws = model.workspace, !ws.isArchived {
                cmd("archive", "archivebox", "Archive \(ws.name)") { Task { await app.archive(ws) } }
            }
        }
        cmd("home", "house", "Home") { app.showHome() }
        cmd("settings", "gearshape", "Settings", "⌘,") { app.settingsRoute = .general }
        cmd("clone", "square.and.arrow.down", "Clone from GitHub…", "⌥⌘O") { app.showGitHubPicker = true }
        cmd("add", "plus.rectangle.on.folder", "Add local repository…", "⇧⌘O") { app.promptAddRepository() }
        return cmds
    }
}

struct QuickOpenItem: Identifiable {
    enum Section: Int {
        case workspaces, chats, files, projects, commands
        var title: String {
            switch self {
            case .workspaces: "Workspaces"
            case .chats: "In chats"
            case .files: "Files"
            case .projects: "Projects"
            case .commands: "Commands"
            }
        }
    }

    let id: String
    let section: Section
    let symbol: String
    let title: String
    let detail: String?
    /// Set for workspace results: the row shows its live status glyph (spinner, hand, PR) instead of `symbol`.
    var workspace: Workspace? = nil
    let action: () -> Void
}

private struct QuickOpenRow: View {
    @Environment(AppModel.self) private var app
    let item: QuickOpenItem
    let query: String
    let selected: Bool

    /// The title with the matched text in semibold.
    private var attributedTitle: AttributedString {
        var a = AttributedString(item.title)
        if !query.isEmpty, let r = a.range(of: query, options: .caseInsensitive) {
            a[r].font = .system(size: 13, weight: .semibold)
        }
        return a
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let ws = item.workspace {
                    WorkspaceGlyph(workspace: ws, model: app.existingModel(for: ws.id))
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text2)
                }
            }
            .frame(width: 18)
            if item.section == .chats {
                // A matched message: the snippet, then which chat and when.
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributedTitle).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                    if let detail = item.detail {
                        Text(detail).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
            } else {
                Text(attributedTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(detail)
                        .font(Theme.small)
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: item.section == .chats ? 44 : item.section == .workspaces ? 38 : 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.selected : .clear))
        .contentShape(Rectangle())
    }
}

extension Workspace {
    /// What the sidebar calls it: its AI-written title, else the current chat's title, else its climb name.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let tab = tabs.first { $0.id == selectedTabID } ?? tabs.first
        if let t = tab?.title, t != "New chat" { return t }
        return name.capitalized
    }
}
