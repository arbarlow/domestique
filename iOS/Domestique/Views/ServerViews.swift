import DQCore
import ServerKit
import SwiftUI

/// Add a server: URL and token, checked with a handshake before saving.
struct AddServerView: View {
    @Environment(ServerList.self) private var serverList
    @Environment(\.dismiss) private var dismiss
    var editing: ServerConfig?
    /// From a QR code or link.
    var prefill: ServerLink?

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ws://100.64.0.5:7420", text: $url)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(editing == nil ? "Token (dq_…)" : "Token (unchanged)", text: $token)
                        .textContentType(.oneTimeCode)  // not a password: keep the "Save Password?" sheet away
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("Use `wss://` behind a TLS proxy, or `ws://` on a private network like Tailscale. Create a token on the server with `domestique token create --name iphone --scope operate`.")
                }
                if prefill != nil {
                    Section {
                        Label("Filled in from a link. Only connect to servers you own: a server can see everything you send it.", systemImage: "qrcode")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.removed) }
                }
            }
            .navigationTitle(editing == nil ? "Add server" : "Edit server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking {
                        ProgressView()
                    } else {
                        Button("Connect") { Task { await connect() } }
                            .disabled(url.isEmpty || (editing == nil && token.isEmpty))
                    }
                }
            }
            .onAppear {
                if let editing, url.isEmpty {
                    name = editing.name
                    url = editing.url
                }
                if let prefill {
                    url = prefill.url
                    token = prefill.token
                    if name.isEmpty { name = prefill.name }
                }
            }
        }
    }

    private func connect() async {
        checking = true
        defer { checking = false }
        let useToken = token.isEmpty ? (editing.flatMap { ServerTokens.get($0.id) } ?? "") : token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let info = try await ServerList.test(url: url, token: useToken)
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            let server = ServerConfig(
                id: editing?.id ?? UUID(),
                name: trimmedName.isEmpty ? (info.serverName.isEmpty ? "Server" : info.serverName) : trimmedName,
                url: url.trimmingCharacters(in: .whitespacesAndNewlines))
            try serverList.save(server, token: token.isEmpty ? nil : useToken)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A server's details: connection, scope, agents, repositories; edit and remove.
struct ServerDetailView: View {
    let server: ServerConnection
    @Environment(ServerList.self) private var serverList
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmRemove = false
    @State private var addingRepo = false
    @State private var cloneURL = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        StatusDot(status: server.status)
                        Text(statusText)
                    }
                }
                LabeledContent("URL", value: server.config.url)
                if let w = server.welcome {
                    LabeledContent("Server", value: w.serverName)
                    LabeledContent("Version", value: w.serverVersion)
                    LabeledContent("Access", value: scopeName(w.scope))
                }
                if let info = server.info {
                    LabeledContent("Platform", value: info.platform)
                    LabeledContent("Agents", value: info.providers.map { ProviderKind(proto: $0).displayName }.joined(separator: ", "))
                }
            }
            Section("Repositories") {
                ForEach(server.sortedRepositories, id: \.id) { repo in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.title)
                        Text(repo.remoteURL.isEmpty ? repo.path : repo.remoteURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if server.canTrigger {
                    Button("Add repository", systemImage: "plus") { addingRepo = true }
                }
            }
            Section {
                Button("Edit connection") { editing = true }
                Button("Remove server", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(server.name)
        .sheet(isPresented: $editing) { AddServerView(editing: server.config) }
        .alert("Add repository", isPresented: $addingRepo) {
            TextField("git@github.com:acme/api.git", text: $cloneURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Clone") {
                let url = cloneURL
                cloneURL = ""
                Task {
                    do { _ = try await server.addRepository(cloneURL: url) } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(server.name) clones it into its repos folder.")
        }
        .confirmationDialog("Remove \(server.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                dismiss()
                serverList.remove(server.id)
            }
        } message: {
            Text("This only forgets the server on this iPhone. Nothing on the server changes.")
        }
        .alert("Couldn't add the repository", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var statusText: String {
        switch server.status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .offline(let why): why
        }
    }

    private func scopeName(_ s: Proto_TokenScope) -> String {
        switch s {
        case .read: "Read only"
        case .trigger: "Trigger"
        case .operate: "Operate"
        case .admin: "Admin"
        default: "Unknown"
        }
    }
}
