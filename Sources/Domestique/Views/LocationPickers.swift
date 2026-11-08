import DQCore
import SwiftUI

/// Where a new workspace runs is a server plus what it is on that server: a worktree on the server itself
/// or a sandbox from one of the server's providers. These views show that choice the same way everywhere.

/// A repository's "Run new workspaces on": the app default, or a server and target of its own.
struct RepoLocationPicker: View {
    @Environment(AppModel.self) private var app
    let repo: Repository
    var title = ""

    var body: some View {
        Picker(title, selection: Binding(
            get: { app.repo(repo.id)?.defaultLocation.flatMap { app.workspaceLocations.contains($0) ? $0 : nil } },
            set: { l in app.updateRepo(repo.id) { $0.defaultLocation = l } }
        )) {
            Text("Default · \(app.longLocationName(app.appDefaultLocation))").tag(WorkspaceLocation?.none)
            Divider()
            ForEach(app.groupedByServer(app.workspaceLocations)) { g in
                Section(app.serverName(for: g.server)) {
                    ForEach(g.locations) { Text(app.targetName($0)).tag(Optional($0)) }
                }
            }
        }
    }
}

/// Menu items for "New workspace on…": a section per server, its targets inside, the default marked.
struct NewWorkspaceMenuSections: View {
    @Environment(AppModel.self) private var app
    let locations: [WorkspaceLocation]
    var defaultLocation: WorkspaceLocation?
    let action: (WorkspaceLocation) -> Void

    var body: some View {
        ForEach(app.groupedByServer(locations)) { g in
            Section(app.serverName(for: g.server)) {
                ForEach(g.locations) { loc in
                    Button(loc == defaultLocation ? "\(app.targetName(loc)) (default)" : app.targetName(loc)) { action(loc) }
                        .disabled(!app.isUsable(loc))
                }
            }
        }
    }
}

/// Two pickers: which server, then worktree or sandbox provider on it. Switching server picks that
/// server's own default.
struct ServerTargetPicker: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: WorkspaceLocation
    let locations: [WorkspaceLocation]

    var body: some View {
        let groups = app.groupedByServer(locations)
        let server = app.server(of: selection)
        let targets = groups.first { $0.server == server }?.locations ?? []
        HStack(spacing: 6) {
            if groups.count > 1 {
                Picker("Run on", selection: Binding(
                    get: { server },
                    set: { c in
                        let offered = groups.first { $0.server == c }?.locations ?? []
                        selection = app.defaultLocation(on: c).flatMap { offered.contains($0) ? $0 : nil } ?? offered.first ?? selection
                    }
                )) {
                    ForEach(groups) { Text(app.serverName(for: $0.server)).tag($0.server) }
                }
                .fixedSize()
            }
            if targets.count > 1 {
                Picker(groups.count > 1 ? "as" : "Run as", selection: $selection) {
                    ForEach(targets) { Text(app.targetName($0)).tag($0) }
                }
                .fixedSize()
            }
        }
    }
}
