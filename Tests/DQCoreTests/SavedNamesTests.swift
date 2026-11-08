import DQCore
import Foundation
import Testing

/// Settings saved before the Team Car rename have to keep decoding.
@Suite struct SavedNamesTests {
    private let id = UUID()

    @Test func legacyLocationDecodes() throws {
        let json = #"{"teamCar":{"_0":"\#(id.uuidString)"}}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(WorkspaceLocation.self, from: json) == .server(id))
        #expect(try JSONDecoder().decode(SandboxProviderHome.self, from: json) == .server(id))
    }

    @Test func serverLocationKeepsItsSavedForm() throws {
        let data = try JSONEncoder().encode(WorkspaceLocation.server(id))
        #expect(String(decoding: data, as: UTF8.self).contains("teamCar"))
    }

    @Test func legacyProviderRawValue() {
        #expect(CloudProviderID(rawValue: "teamcar") == .server)
    }
}
