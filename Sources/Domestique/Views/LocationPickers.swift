import DQCore
import SwiftUI

/// Where a new workspace runs is a Team Car plus what it is on that car: a worktree on the car itself
/// or a sandbox from one of the car's providers. These views show that choice the same way everywhere.

/// A repository's "Run new workspaces on": the app default, or a car and target of its own.
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
            ForEach(app.groupedByCar(app.workspaceLocations)) { g in
                Section(app.carName(for: g.car)) {
                    ForEach(g.locations) { Text(app.targetName($0)).tag(Optional($0)) }
                }
            }
        }
    }
}

/// Menu items for "New workspace on…": a section per car, its targets inside, the default marked.
struct NewWorkspaceMenuSections: View {
    @Environment(AppModel.self) private var app
    let locations: [WorkspaceLocation]
    var defaultLocation: WorkspaceLocation?
    let action: (WorkspaceLocation) -> Void

    var body: some View {
        ForEach(app.groupedByCar(locations)) { g in
            Section(app.carName(for: g.car)) {
                ForEach(g.locations) { loc in
                    Button(loc == defaultLocation ? "\(app.targetName(loc)) (default)" : app.targetName(loc)) { action(loc) }
                        .disabled(!app.isUsable(loc))
                }
            }
        }
    }
}

/// Two pickers: which Team Car, then worktree or sandbox provider on it. Switching car picks that
/// car's own default.
struct CarTargetPicker: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: WorkspaceLocation
    let locations: [WorkspaceLocation]

    var body: some View {
        let groups = app.groupedByCar(locations)
        let car = app.car(of: selection)
        let targets = groups.first { $0.car == car }?.locations ?? []
        HStack(spacing: 6) {
            if groups.count > 1 {
                Picker("Run on", selection: Binding(
                    get: { car },
                    set: { c in
                        let offered = groups.first { $0.car == c }?.locations ?? []
                        selection = app.defaultLocation(on: c).flatMap { offered.contains($0) ? $0 : nil } ?? offered.first ?? selection
                    }
                )) {
                    ForEach(groups) { Text(app.carName(for: $0.car)).tag($0.car) }
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
