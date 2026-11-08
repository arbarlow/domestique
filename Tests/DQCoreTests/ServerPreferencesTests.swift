import Foundation
import Testing
@testable import DQCore

@Suite struct ServerPreferencesTests {
    @Test func olderSettingsOfferWorktreesOnThisMac() throws {
        let json = #"{"defaultProvider":"claude","defaultPermissionMode":"bypass","branchPrefix":"a","editorCommand":"x"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.defaultServer == nil)
        #expect(s.preferences(for: .thisMac) == ServerPreferences())
        #expect(s.preferences(for: .thisMac).worktrees)
    }

    @Test func preferencesAreKeptPerServerAndRoundTrip() throws {
        let server = UUID(), provider = UUID()
        var s = AppSettings()
        s.defaultServer = .server(server)
        s.setPreferences(ServerPreferences(worktrees: false, defaultSandbox: provider), for: .server(server))
        #expect(s.preferences(for: .thisMac).worktrees)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.defaultServer == .server(server))
        #expect(back.preferences(for: .server(server)) == ServerPreferences(worktrees: false, defaultSandbox: provider))
        // Back to defaults: nothing stored.
        s.setPreferences(ServerPreferences(), for: .server(server))
        #expect(s.carPreferenceMap == nil)
    }

    @Test func missingFieldsDecodeToDefaults() throws {
        let p = try JSONDecoder().decode(ServerPreferences.self, from: Data("{}".utf8))
        #expect(p.worktrees && p.defaultSandbox == nil)
    }
}
