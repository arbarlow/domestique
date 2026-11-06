import Foundation
import Testing
@testable import DQCore

@Suite struct CarPreferencesTests {
    @Test func olderSettingsOfferWorktreesOnThisMac() throws {
        let json = #"{"defaultProvider":"claude","defaultPermissionMode":"bypass","branchPrefix":"a","editorCommand":"x"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.defaultCar == nil)
        #expect(s.preferences(for: .thisMac) == CarPreferences())
        #expect(s.preferences(for: .thisMac).worktrees)
    }

    @Test func preferencesAreKeptPerCarAndRoundTrip() throws {
        let car = UUID(), provider = UUID()
        var s = AppSettings()
        s.defaultCar = .teamCar(car)
        s.setPreferences(CarPreferences(worktrees: false, defaultSandbox: provider), for: .teamCar(car))
        #expect(s.preferences(for: .thisMac).worktrees)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.defaultCar == .teamCar(car))
        #expect(back.preferences(for: .teamCar(car)) == CarPreferences(worktrees: false, defaultSandbox: provider))
        // Back to defaults: nothing stored.
        s.setPreferences(CarPreferences(), for: .teamCar(car))
        #expect(s.carPreferenceMap == nil)
    }

    @Test func missingFieldsDecodeToDefaults() throws {
        let p = try JSONDecoder().decode(CarPreferences.self, from: Data("{}".utf8))
        #expect(p.worktrees && p.defaultSandbox == nil)
    }
}
