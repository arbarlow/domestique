import AppKit
import DQCore
import HostKit
import SwiftUI

/// In a sandbox provider's editor: the variables each project's new sandboxes start with, imported
/// from a `.env` file. Values stay out of the UI.
struct SandboxEnvironmentEditor: View {
    @Environment(AppModel.self) private var app
    let provider: SandboxProviderConfig

    @State private var repoID: UUID?
    @State private var saved: [EnvVariable] = []
    @State private var candidates: [EnvVariable]?
    @State private var chosen: Set<String> = []
    @State private var sourceName = ""
    @State private var error: String?

    private var repos: [Repository] { app.repositories.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
    private var repo: Repository? { repos.first { $0.id == repoID } ?? repos.first }

    var body: some View {
        Group {
            SettingsRow(title: "Environment variables", subtitle: error ?? subtitle) {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { repo?.id }, set: { select($0) })) {
                        ForEach(repos) { Text($0.title).tag(Optional($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Project")
                    Button("Import .env…", action: chooseFile)
                        .buttonStyle(.softCompact)
                        .disabled(repo == nil || candidates != nil)
                }
            }
            if let candidates {
                importList(candidates)
            } else {
                ForEach(saved) { v in
                    SettingsRow(title: v.key) {
                        Button("Remove") { remove(v) }.buttonStyle(.softDestructive)
                    }
                }
            }
        }
        .task(id: repo?.id) { reload() }
    }

    private var subtitle: String {
        guard let repo else { return "Add a project first" }
        return saved.isEmpty
            ? "None for \(repo.title). Added to its new sandboxes when they start; saved in your Keychain"
            : "\(saved.count) for \(repo.title)'s new sandboxes; saved in your Keychain"
    }

    @ViewBuilder private func importList(_ found: [EnvVariable]) -> some View {
        let existing = Set(saved.map(\.key))
        ForEach(found) { v in
            SettingsRow(title: v.key, subtitle: existing.contains(v.key) ? "Replaces the saved value" : nil) {
                Toggle("", isOn: Binding(
                    get: { chosen.contains(v.key) },
                    set: { on in
                        if on { chosen.insert(v.key) } else { chosen.remove(v.key) }
                    }
                ))
                .labelsHidden()
                .accessibilityLabel("Import \(v.key)")
            }
        }
        SettingsRow(title: found.isEmpty ? "No variables in \(sourceName)" : "", subtitle: found.isEmpty ? nil : "From \(sourceName)") {
            HStack(spacing: 6) {
                if !found.isEmpty {
                    Button(chosen.count == found.count ? "Select None" : "Select All") {
                        chosen = chosen.count == found.count ? [] : Set(found.map(\.key))
                    }
                    .buttonStyle(.softCompact)
                }
                Button("Cancel") { candidates = nil }.buttonStyle(.softCompact)
                Button(chosen.isEmpty ? "Import" : "Import \(chosen.count)", action: importChosen)
                    .buttonStyle(SoftButtonStyle(prominent: true, compact: true))
                    .disabled(chosen.isEmpty)
            }
        }
    }

    private func select(_ id: UUID?) {
        repoID = id
        candidates = nil
    }

    private func reload() {
        error = nil
        guard let repo else { return saved = [] }
        saved = SandboxEnvironmentStore.variables(provider: provider.id, repo: repo.id)
    }

    private func chooseFile() {
        guard let repo else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a .env file for \(repo.title)"
        panel.prompt = "Choose"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: repo.path, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let found = DotEnv.parse(try String(contentsOf: url, encoding: .utf8))
            error = nil
            sourceName = url.lastPathComponent
            chosen = Set(found.map(\.key))
            candidates = found
        } catch {
            self.error = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func importChosen() {
        guard let repo, let candidates else { return }
        var merged = saved
        for v in candidates where chosen.contains(v.key) {
            if let i = merged.firstIndex(where: { $0.key == v.key }) { merged[i] = v } else { merged.append(v) }
        }
        if store(merged, repo: repo) { self.candidates = nil }
    }

    private func remove(_ v: EnvVariable) {
        guard let repo else { return }
        _ = store(saved.filter { $0.key != v.key }, repo: repo)
    }

    private func store(_ variables: [EnvVariable], repo: Repository) -> Bool {
        guard SandboxEnvironmentStore.save(variables, provider: provider.id, repo: repo.id) else {
            error = "Couldn't save to your Keychain"
            return false
        }
        error = nil
        saved = variables
        return true
    }
}
