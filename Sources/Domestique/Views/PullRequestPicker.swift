import DQCore
import GitHubKit
import SwiftUI

/// "New workspace from pull request": lists a repository's open PRs; picking one opens the workspace
/// already on it, or starts a new one checked out at its head.
struct PullRequestPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let repo: Repository

    @State private var prs: [PullRequestSummary] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var query = ""
    @State private var highlighted: PullRequestSummary.ID?
    @State private var location: WorkspaceLocation?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
            Hairline()
            footer
        }
        .frame(width: 620, height: 540)
        .background(Theme.canvas)
        .task { await load() }
        .onAppear { searchFocused = true }
    }

    // MARK: sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RepoIconView(repo: repo, size: 18)
                Text("Start from a pull request").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(repo.githubSlug ?? repo.title).font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1)
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh", size: 12) { Task { await load() } }
                    .disabled(loading)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.text3)
                TextField("Search by title, number, branch or author", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui)
                    .focused($searchFocused)
                    .onSubmit { if let pr = highlightedPR { pick(pr) } }
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        if repo.githubSlug == nil {
            centered {
                Text("This repository has no GitHub remote, so there are no pull requests to start from.")
                    .font(Theme.ui).foregroundStyle(Theme.text3).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        } else if loading && prs.isEmpty {
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
                Text(query.isEmpty ? "No open pull requests" : "No pull requests match “\(query)”")
                    .font(Theme.ui).foregroundStyle(Theme.text3)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered) { pr in
                            PRPickerRow(
                                pr: pr, hasWorkspace: app.workspace(for: pr, in: repo) != nil,
                                highlighted: highlightedPR?.id == pr.id
                            ) { pick(pr) }
                            .id(pr.id)
                            .onHover { if $0 { highlighted = pr.id } }
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
            if let pr = highlightedPR, pr.isCrossRepository {
                Image(systemName: "tuningfork").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Text("From a fork: checked out as a local pr-\(pr.number) branch; pushes won't update the PR.")
                    .font(Theme.small).foregroundStyle(Theme.text3).lineLimit(2)
            } else {
                Text("Checks out the PR's branch in a fresh worktree; pushing updates the PR.")
                    .font(Theme.small).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            if let choices = app.newWorkspaceChoices(for: repo) {
                CarTargetPicker(
                    selection: Binding(get: { location ?? app.defaultLocation(for: repo) }, set: { location = $0 }),
                    locations: choices)
            }
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

    private var filtered: [PullRequestSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return prs }
        let number = Int(q.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        return prs.filter { pr in
            pr.number == number || pr.title.lowercased().contains(q) || pr.headRefName.lowercased().contains(q)
                || (pr.authorLogin?.lowercased().contains(q) ?? false)
        }
    }

    private var highlightedPR: PullRequestSummary? {
        let list = filtered
        return list.first { $0.id == highlighted } ?? list.first
    }

    private func moveHighlight(_ delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == highlightedPR?.id } ?? 0
        highlighted = list[max(0, min(list.count - 1, i + delta))].id
    }

    private func load() async {
        guard let slug = repo.githubSlug else { return loading = false }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            prs = try await GitHubClient.shared.openPullRequests(slug: slug, first: 100)
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func pick(_ pr: PullRequestSummary) {
        let repo = repo
        let location = location
        dismiss()
        Task { await app.openPullRequest(pr, in: repo, location: location) }
    }
}

private struct PRPickerRow: View {
    let pr: PullRequestSummary
    let hasWorkspace: Bool
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(selected: highlighted, height: 50, action: action) {
            HStack(spacing: 10) {
                Image(systemName: pr.isDraft ? "circle.dashed" : "arrow.triangle.pull")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(pr.isDraft ? Theme.text3 : Theme.added)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title).font(Theme.uiMedium).foregroundStyle(Theme.text).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(verbatim: "#\(pr.number)").font(Theme.monoDigits)
                        Text(pr.headRefName).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                        if pr.isCrossRepository {
                            Image(systemName: "tuningfork").font(.system(size: 9))
                        }
                        if let login = pr.authorLogin {
                            Text("·")
                            Text(login)
                        }
                        if let updated = pr.updatedAt {
                            Text("·")
                            Text(updated, format: .relative(presentation: .named))
                        }
                    }
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if hasWorkspace {
                    Text("Open workspace")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.running)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.running.opacity(0.12), in: Capsule())
                }
                DiffCount(additions: pr.additions, deletions: pr.deletions)
                    .frame(minWidth: 60, alignment: .trailing)
            }
        }
        .help(hasWorkspace ? "Go to the workspace on \(pr.headRefName)" : "New workspace on #\(pr.number)")
    }
}
