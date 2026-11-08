import Foundation
import Testing

@testable import DQCore

@Suite struct ClaudeMCPImportTests {
    @Test func readsServersAndFillsVariables() throws {
        let json = #"""
            {"numStartups": 3, "mcpServers": {
              "pg": {"command": "/Users/a/bin/pg", "args": ["${HOST:-localhost}"], "env": {"URL": "${DB}"}},
              "api": {"type": "http", "url": "https://x.dev/mcp", "headers": {"Authorization": "Bearer ${MISSING}"}},
              "helper": {"type": "http", "url": "https://y.dev", "headersHelper": "./h.sh"},
              "odd": {"url": "https://z.dev"}
            }}
            """#
        let servers = try ClaudeMCPImport.parse(Data(json.utf8), environment: ["DB": "postgres://a"])
        #expect(servers.map(\.name) == ["api", "pg"])
        #expect(servers[0].transport == .http)
        #expect(servers[0].headers["Authorization"] == "Bearer ${MISSING}")
        #expect(servers[1].transport == .stdio)
        #expect(servers[1].args == ["localhost"])
        #expect(servers[1].env["URL"] == "postgres://a")
        #expect(servers[1].usesMacPath)
        #expect(!servers[0].usesMacPath)
    }

    @Test func noServers() throws {
        #expect(try ClaudeMCPImport.parse(Data("{}".utf8), environment: [:]).isEmpty)
    }
}
