import Foundation
import Testing
@testable import DQCore

@Suite struct SandboxProviderTests {
    @Test func oldSettingsBecomeTheFirstProvider() throws {
        // Settings saved before sandbox providers existed: one boat.dev setup.
        let json = #"{"defaultProvider":"claude","defaultPermissionMode":"bypass","branchPrefix":"a","editorCommand":"x","boatSettings":{"machineType":"large","autoStopMinutes":60}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.sandboxProviders.count == 1)
        let p = s.sandboxProviders[0]
        #expect(p.id == SandboxProviderConfig.legacyID)
        #expect(p.credentialAccount == "api-key")  // keeps the API key already in the Keychain
        #expect(p.boat.machineType == "large")
        // The old "boat.dev" location and old workspaces (no account recorded) resolve to it.
        #expect(s.provider(for: WorkspaceLocation.cloud(.boat))?.id == p.id)
        #expect(s.provider(for: WorkspaceHost(provider: .boat, machineID: "bx_1"))?.id == p.id)
    }

    @Test func providersFromBeforeTeamCarHaveNoHome() throws {
        // Saved by the previous version: no home, no car status, no snapshot.
        let json = #"{"id":"B0A7DE70-0000-4000-8000-000000000001","kind":"boat","name":"boat.dev","credentialAccount":"api-key","boat":{"machineType":"large","autoStopMinutes":60}}"#
        let p = try JSONDecoder().decode(SandboxProviderConfig.self, from: Data(json.utf8))
        #expect(p.home == nil && !p.isOnTeamCar && p.carStatus == nil)
        #expect(p.boat.fromSnapshot == nil && p.boat.machineType == "large")
    }

    @Test func teamCarHomeRoundTrips() throws {
        let car = UUID()
        var p = SandboxProviderConfig(name: "boat · large")
        p.home = .teamCar(car)
        p.carStatus = SandboxProviderCarStatus(credentialSource: "config", fromConfig: true)
        p.boat.fromSnapshot = "stride"
        let back = try JSONDecoder().decode(SandboxProviderConfig.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        #expect(back.remoteCarID == car)
        #expect(back.carStatus?.hasKey == true)
        var mac = p
        mac.home = .thisMac
        #expect(mac.isOnTeamCar && mac.remoteCarID == nil)
        #expect(SandboxProviderCarStatus(credentialSource: "none", fromConfig: false).hasKey == false)
    }

    @Test func workspacesBelongToTheirProvider() {
        var s = AppSettings()
        let a = SandboxProviderConfig.legacy(BoatSettings())
        let b = SandboxProviderConfig(name: "team")
        s.sandboxProviders = [a, b]
        var host = WorkspaceHost(provider: .boat, machineID: "bx_2")
        host.accountID = b.credentialAccount
        #expect(s.provider(for: host)?.id == b.id)
        #expect(s.provider(for: WorkspaceLocation.sandbox(b.id))?.name == "team")
        #expect(b.credentialAccount != a.credentialAccount)
        // A Team Car host is never a sandbox provider's.
        #expect(s.provider(for: WorkspaceHost(provider: .teamcar, machineID: UUID().uuidString)) == nil)
        // Round-trips through the settings database.
        let back = try! JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.sandboxProviders.map(\.id) == [a.id, b.id])
    }
}
