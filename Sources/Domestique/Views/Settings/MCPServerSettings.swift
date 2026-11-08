import DQCore
import Foundation
import ServerKit
import SwiftUI

/// Settings → Agents: the MCP servers a server gives Claude. Each server keeps its own list and the
/// secrets in its database; sandboxes started from that server's providers get them.
struct MCPServerSettings: View {
    @Environment(AppModel.self) private var app
    @State private var server: SandboxProviderHome = .thisMac
    @State private var servers: [Proto_McpServer] = []
    @State private var error: String?
    @State private var form: Form?

    private enum Form: Equatable {
        case add
        case edit(Proto_McpServer)
        case importing
    }

    var body: some View {
        SettingsSection(
            title: "MCP servers",
            footer: error ?? "Given to Claude in sandboxes, even when the sandbox provider replaces Claude's own config. Secrets are stored in the server's database and can't be read back here."
        ) {
            if app.servers.count > 1 {
                SettingsRow(title: "Server", subtitle: "Sandboxes use the MCP servers on the server that owns their provider") {
                    Picker("", selection: $server) {
                        ForEach(app.servers, id: \.self) { Text(app.serverName(for: $0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            ForEach(servers, id: \.id) { s in
                row(s)
                if form == .edit(s) {
                    MCPServerForm(existing: s, onDone: finish, save: save)
                }
            }
            switch form {
            case .add:
                MCPServerForm(existing: nil, onDone: finish, save: save)
            case .importing:
                MCPImportForm(existing: Set(servers.map(\.name)), onDone: finish, save: save)
            default:
                SettingsRow(title: servers.isEmpty ? "No servers yet" : "") {
                    HStack(spacing: 6) {
                        Button("Import from Claude Code…") { open(.importing) }.buttonStyle(.softCompact)
                        Button("Add Server…") { open(.add) }.buttonStyle(.softCompact)
                    }
                }
            }
        }
        .task(id: server) { await load() }
    }

    private func row(_ s: Proto_McpServer) -> some View {
        SettingsRow(title: s.name, subtitle: summary(s)) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { s.everywhere },
                    set: { v in update(s) { $0.everywhere = v } }
                )) {
                    Text("Sandboxes").tag(false)
                    Text("Everywhere").tag(true)
                }
                .labelsHidden().fixedSize()
                .help("Everywhere also gives it to Claude in this server's worktrees")
                Button("Edit") { open(.edit(s)) }.buttonStyle(.softCompact)
                Button("Remove") { remove(s) }.buttonStyle(.softCompact)
                Toggle("", isOn: Binding(
                    get: { s.enabled },
                    set: { v in update(s) { $0.enabled = v } }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private func summary(_ s: Proto_McpServer) -> String {
        let target = s.transport == .stdio ? ([s.command] + s.args).joined(separator: " ") : s.url
        let secrets = s.envNames.count + s.headerNames.count
        return secrets == 0 ? target : "\(target) · \(secrets) secret\(secrets == 1 ? "" : "s")"
    }

    private func open(_ f: Form) { withAnimation(.snappy(duration: 0.2)) { form = f } }
    private func finish() { withAnimation(.snappy(duration: 0.2)) { form = nil } }

    private func load() async {
        do {
            let c = try await app.serverClient(for: server)
            servers = try await c.mcpServers()
            error = nil
        } catch {
            servers = []
            self.error = AppModel.serverErrorMessage(error)
        }
    }

    /// Throws so that a form can stay open and show what went wrong.
    private func save(_ req: Proto_SaveMcpServer) async throws {
        _ = try await app.serverClient(for: server).saveMcpServer(req)
        await load()
    }

    private func update(_ s: Proto_McpServer, _ change: (inout Proto_McpServer) -> Void) {
        var req = Proto_SaveMcpServer()
        req.server = s
        change(&req.server)
        Task {
            do { try await save(req) } catch { self.error = AppModel.serverErrorMessage(error) }
        }
    }

    private func remove(_ s: Proto_McpServer) {
        Task {
            do {
                try await app.serverClient(for: server).removeMcpServer(id: s.id)
                await load()
            } catch {
                self.error = AppModel.serverErrorMessage(error)
            }
        }
    }
}

/// One secret being edited. A stored one has an empty value until it's replaced.
private struct SecretField: Identifiable {
    let id = UUID()
    var name: String
    var value = ""
    var stored = false
}

private struct MCPServerForm: View {
    let existing: Proto_McpServer?
    let onDone: () -> Void
    let save: (Proto_SaveMcpServer) async throws -> Void

    @State private var name = ""
    @State private var transport = Proto_McpTransport.stdio
    @State private var command = ""
    @State private var args = ""
    @State private var url = ""
    @State private var secrets: [SecretField] = []
    @State private var error: String?
    @State private var saving = false

    private var isStdio: Bool { transport == .stdio }
    private var canSave: Bool { !name.isEmpty && !(isStdio ? command.isEmpty : url.isEmpty) && !saving }

    var body: some View {
        SettingsRow(title: "Name", subtitle: "Letters, digits, - and _") {
            TextField("postgres", text: $name).modifier(FieldStyle())
        }
        SettingsRow(title: "Type") {
            Picker("", selection: $transport) {
                Text("Command").tag(Proto_McpTransport.stdio)
                Text("HTTP").tag(Proto_McpTransport.http)
                Text("SSE").tag(Proto_McpTransport.sse)
            }
            .labelsHidden().fixedSize()
        }
        if isStdio {
            SettingsRow(title: "Command", subtitle: "Runs on the sandbox, so it must be installed there") {
                TextField("npx", text: $command).modifier(FieldStyle())
            }
            SettingsRow(title: "Arguments", subtitle: "One per line") {
                TextField("", text: $args, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.plain).font(Theme.ui).padding(6).frame(width: 220)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
            }
        } else {
            SettingsRow(title: "URL") {
                TextField("https://example.com/mcp", text: $url).modifier(FieldStyle())
            }
        }
        ForEach($secrets) { $secret in
            SettingsRow(title: isStdio ? "Variable" : "Header") {
                HStack(spacing: 6) {
                    TextField("Name", text: $secret.name)
                        .textFieldStyle(.plain).font(Theme.ui).padding(.horizontal, 8).frame(width: 130, height: 26)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                        .disabled(secret.stored)
                    SecureField(secret.stored ? "Saved; type to replace" : "Value", text: $secret.value)
                        .modifier(FieldStyle())
                    Button {
                        secrets.removeAll { $0.id == secret.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        SettingsRow(title: "", subtitle: error) {
            HStack(spacing: 6) {
                Button(isStdio ? "Add Variable" : "Add Header") { secrets.append(SecretField(name: "")) }
                    .buttonStyle(.softCompact)
                Button("Cancel", action: onDone).buttonStyle(.softCompact)
                Button("Save", action: submit)
                    .buttonStyle(SoftButtonStyle(prominent: true, compact: true))
                    .disabled(!canSave)
            }
        }
        .onAppear(perform: fill)
        .onChange(of: isStdio) { _, _ in
            // Variables and headers are different lists: start the other one from what's stored.
            guard let e = existing else {
                secrets = []
                return
            }
            let matches = isStdio == (e.transport == .stdio)
            secrets = matches ? (isStdio ? e.envNames : e.headerNames).map { SecretField(name: $0, stored: true) } : []
        }
    }

    private func fill() {
        guard let e = existing else { return }
        name = e.name
        transport = e.transport
        command = e.command
        args = e.args.joined(separator: "\n")
        url = e.url
        secrets = (e.transport == .stdio ? e.envNames : e.headerNames).map { SecretField(name: $0, stored: true) }
    }

    private func submit() {
        var req = Proto_SaveMcpServer()
        var s = existing ?? Proto_McpServer()
        if existing == nil {
            s.id = UUID().uuidString.lowercased()
            s.enabled = true
        }
        s.name = name.trimmingCharacters(in: .whitespaces)
        s.transport = transport
        s.command = isStdio ? command.trimmingCharacters(in: .whitespaces) : ""
        s.args = isStdio ? args.split(whereSeparator: \.isNewline).map(String.init) : []
        s.url = isStdio ? "" : url.trimmingCharacters(in: .whitespaces)
        req.server = s

        let changed = secrets.filter { !$0.name.isEmpty && !$0.value.isEmpty }
        let values = Dictionary(changed.map { ($0.name, $0.value) }) { _, new in new }
        let kept = Set(secrets.map(\.name))
        if isStdio {
            req.setEnv = values
            req.removeEnv = (existing?.envNames ?? []).filter { !kept.contains($0) }
        } else {
            req.setHeaders = values
            req.removeHeaders = (existing?.headerNames ?? []).filter { !kept.contains($0) }
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await save(req)
                onDone()
            } catch {
                self.error = AppModel.serverErrorMessage(error)
            }
        }
    }
}

/// Copies servers from this Mac's ~/.claude.json to the server, secrets included.
private struct MCPImportForm: View {
    let existing: Set<String>
    let onDone: () -> Void
    let save: (Proto_SaveMcpServer) async throws -> Void

    @State private var found: [ImportedMCPServer] = []
    @State private var selected: Set<String> = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ForEach(found) { s in
            SettingsRow(title: s.name, subtitle: subtitle(s)) {
                Toggle("", isOn: Binding(
                    get: { selected.contains(s.name) },
                    set: { on in
                        if on { selected.insert(s.name) } else { selected.remove(s.name) }
                    }
                ))
                .labelsHidden()
            }
        }
        SettingsRow(title: loaded && found.isEmpty ? "Nothing new to import" : "", subtitle: error) {
            HStack(spacing: 6) {
                Button("Cancel", action: onDone).buttonStyle(.softCompact)
                Button("Import", action: importSelected)
                    .buttonStyle(SoftButtonStyle(prominent: true, compact: true))
                    .disabled(selected.isEmpty)
            }
        }
        .task { await read() }
    }

    private func subtitle(_ s: ImportedMCPServer) -> String {
        let target = s.transport == .stdio ? ([s.command] + s.args).joined(separator: " ") : s.url
        return s.usesMacPath ? "Uses a path on this Mac, so it won't start on a sandbox: \(target)" : target
    }

    private func read() async {
        do {
            let data = try Data(contentsOf: ClaudeMCPImport.configURL)
            let env = await LoginEnvironment.shared.environment()
            found = try ClaudeMCPImport.parse(data, environment: env).filter { !existing.contains($0.name) }
        } catch {
            self.error = "Couldn't read ~/.claude.json: \(error.localizedDescription)"
        }
        loaded = true
    }

    private func importSelected() {
        let chosen = found.filter { selected.contains($0.name) }
        Task {
            do {
                for s in chosen { try await save(Self.request(s)) }
                onDone()
            } catch {
                self.error = AppModel.serverErrorMessage(error)
            }
        }
    }

    private static func request(_ s: ImportedMCPServer) -> Proto_SaveMcpServer {
        var server = Proto_McpServer()
        server.id = UUID().uuidString.lowercased()
        server.name = s.name
        server.enabled = true
        server.command = s.command
        server.args = s.args
        server.url = s.url
        switch s.transport {
        case .stdio: server.transport = .stdio
        case .http: server.transport = .http
        case .sse: server.transport = .sse
        }
        var req = Proto_SaveMcpServer()
        req.server = server
        req.setEnv = s.env
        req.setHeaders = s.headers
        return req
    }
}
