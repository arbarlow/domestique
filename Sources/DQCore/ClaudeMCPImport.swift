import Foundation

/// A user-scope MCP server from Claude Code's own config, ready to copy to a server.
public struct ImportedMCPServer: Identifiable, Sendable, Hashable {
    public enum Transport: Sendable, Hashable { case stdio, http, sse }

    public var name: String
    public var transport: Transport
    public var command = ""
    public var args: [String] = []
    public var url = ""
    public var env: [String: String] = [:]
    public var headers: [String: String] = [:]
    public var id: String { name }

    /// Points at something on this Mac, so it won't start on a Linux sandbox.
    public var usesMacPath: Bool {
        ([command] + args).contains { $0.hasPrefix("/Users/") || $0.hasPrefix("/opt/homebrew/") || $0.hasPrefix("/Applications/") }
    }
}

/// Reads the top-level `mcpServers` of ~/.claude.json.
public enum ClaudeMCPImport {
    public static var configURL: URL { URL.homeDirectory.appending(path: ".claude.json") }

    private struct File: Decodable { var mcpServers: [String: Entry]? }
    private struct Entry: Decodable {
        var type: String?
        var command: String?
        var args: [String]?
        var url: String?
        var env: [String: String]?
        var headers: [String: String]?
        var headersHelper: String?
    }

    /// `${VAR}` references are filled in from `environment`: the sandbox won't have the Mac's variables.
    /// Servers using `headersHelper` are left out, since it's a command that only exists on this Mac.
    public static func parse(_ data: Data, environment: [String: String]) throws -> [ImportedMCPServer] {
        let file = try JSONDecoder().decode(File.self, from: data)
        func fill(_ s: String) -> String { expand(s, environment) }
        return (file.mcpServers ?? [:]).compactMap { name, e -> ImportedMCPServer? in
            guard e.headersHelper == nil else { return nil }
            let transport: ImportedMCPServer.Transport
            switch e.type {
            case "http": transport = .http
            case "sse": transport = .sse
            case "stdio": transport = .stdio
            case nil where e.command != nil: transport = .stdio
            default: return nil
            }
            var s = ImportedMCPServer(name: name, transport: transport)
            s.command = fill(e.command ?? "")
            s.args = (e.args ?? []).map(fill)
            s.url = fill(e.url ?? "")
            s.env = (e.env ?? [:]).mapValues(fill)
            s.headers = (e.headers ?? [:]).mapValues(fill)
            return s
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func expand(_ s: String, _ environment: [String: String]) -> String {
        s.replacing(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/) { m in
            if let v = environment[String(m.1)], !v.isEmpty { return v }
            if let fallback = m.2 { return String(fallback) }
            return String(m.0)
        }
    }
}
