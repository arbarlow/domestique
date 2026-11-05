import DQCore
import GitHubKit
import SwiftUI

/// "Clone from GitHub": lists the signed-in user's repos; picking one clones it, adds it as a
/// repository and opens a first workspace.
struct GitHubRepoPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var repos: [GitHubRepo] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var query = ""
    @State private var owner: String?  // nil = all owners
    @State private var cloning: GitHubRepo.ID?
    @State private var cloneError: String?
    @State private var highlighted: GitHubRepo.ID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
            Hairline()
            footer
        }
        .frame(width: 600, height: 560)
        .background(Theme.canvas)
        .task { await load() }
        .onAppear { searchFocused = true }
    }

    // MARK: sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clone from GitHub").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh", size: 12) { Task { await load() } }
                    .disabled(loading)
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    TextField("Search repositories", text: $query)
                        .textFieldStyle(.plain)
                        .font(Theme.ui)
                        .focused($searchFocused)
                        .onSubmit { if let r = highlightedRepo { clone(r) } }
                        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 7))
                if owners.count > 1 {
                    Picker("", selection: $owner) {
                        Text("All owners").tag(String?.none)
                        Divider()
                        ForEach(owners, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        if loading && repos.isEmpty {
            centered { ProgressView().controlSize(.small) }
        } else if let loadError {
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.warning)
                    Text(loadError).font(Theme.ui).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Button("Try again") { Task { await load() } }.buttonStyle(.soft)
                }
            }
        } else if filtered.isEmpty {
            centered {
                Text(query.isEmpty ? "No repositories" : "No repositories match “\(query)”")
                    .font(Theme.ui).foregroundStyle(Theme.text3)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered) { repo in
                            RepoPickerRow(
                                repo: repo, added: app.localRepository(for: repo) != nil,
                                cloning: cloning == repo.id, highlighted: highlightedRepo?.id == repo.id,
                                disabled: cloning != nil
                            ) { clone(repo) }
                            .id(repo.id)
                            .onHover { if $0 { highlighted = repo.id } }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let cloneError {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
                Text(cloneError).font(Theme.small).foregroundStyle(Theme.text2).lineLimit(2).textSelection(.enabled)
            } else if let id = cloning, let repo = repos.first(where: { $0.id == id }) {
                Spinner(size: 11)
                Text("Cloning \(repo.fullName)…").font(Theme.small).foregroundStyle(Theme.text2).lineLimit(1)
            } else {
                Text("Clones into \(displayPath(app.settings.cloneRoot.path))/<owner>/<repo>")
                    .font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.soft)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: data

    private var owners: [String] {
        Array(Set(repos.map(\.owner))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filtered: [GitHubRepo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return repos.filter { r in
            (owner == nil || r.owner == owner)
                && (q.isEmpty || r.fullName.lowercased().contains(q) || (r.description?.lowercased().contains(q) ?? false))
        }
    }

    private var highlightedRepo: GitHubRepo? {
        let list = filtered
        return list.first { $0.id == highlighted } ?? list.first
    }

    private func moveHighlight(_ delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == highlightedRepo?.id } ?? 0
        highlighted = list[max(0, min(list.count - 1, i + delta))].id
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            // Hide archived repos; nobody starts new work there.
            repos = try await GitHubClient.shared.listRepositories().filter { !$0.isArchived }
        } catch {
            await GitHubClient.shared.resetToken()
            loadError = error.localizedDescription
        }
    }

    private func clone(_ repo: GitHubRepo) {
        guard cloning == nil else { return }
        cloning = repo.id
        cloneError = nil
        Task {
            do {
                try await app.cloneFromGitHub(repo)
                cloning = nil
                dismiss()
            } catch {
                cloning = nil
                cloneError = error.localizedDescription
            }
        }
    }

    private func displayPath(_ p: String) -> String {
        p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

private struct RepoPickerRow: View {
    let repo: GitHubRepo
    let added: Bool
    let cloning: Bool
    let highlighted: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(selected: highlighted, height: 50, action: action) {
            HStack(spacing: 10) {
                RepoMonogram(name: repo.name)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(repo.owner + "/").foregroundStyle(Theme.text2)
                            + Text(repo.name).foregroundStyle(Theme.text).fontWeight(.medium)
                        if repo.isPrivate {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.text3)
                        }
                        if repo.isFork {
                            Image(systemName: "tuningfork").font(.system(size: 9)).foregroundStyle(Theme.text3)
                        }
                    }
                    .font(Theme.ui)
                    .lineLimit(1)
                    if let d = repo.description, !d.isEmpty {
                        Text(d).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
        }
        .disabled(disabled && !cloning)
        .help(repo.fullName)
    }

    @ViewBuilder private var trailing: some View {
        if cloning {
            Spinner(size: 11)
        } else if added {
            Text("Added").font(Theme.small).foregroundStyle(Theme.text3)
        } else if let pushed = repo.pushedAt {
            Text(pushed, format: .relative(presentation: .named))
                .font(Theme.small)
                .foregroundStyle(Theme.text3)
        }
    }
}
