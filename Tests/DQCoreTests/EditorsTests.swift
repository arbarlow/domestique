import Foundation
import Testing
@testable import DQCore

@Suite struct EditorsTests {
    private let zed = KnownEditor.zed.bundleID
    private let cursor = KnownEditor.cursor.bundleID

    @Test func listsInstalledEnabledEditorsWithZedAsDefault() {
        var s = AppSettings()
        #expect(s.editorChoices(installed: [zed, cursor]) == [.app(.zed), .app(.cursor)])
        #expect(s.defaultEditor(installed: [zed, cursor]) == .app(.zed))
        s.setEditor(.zed, enabled: false)
        #expect(s.editorChoices(installed: [zed, cursor]) == [.app(.cursor)])
        #expect(s.defaultEditor(installed: [zed, cursor]) == .app(.cursor))
    }

    @Test func aChangedOlderEditorCommandBecomesTheCustomDefault() {
        var s = AppSettings()
        s.editorCommand = "nvim-qt --maximized"
        #expect(s.defaultEditor(installed: [zed]) == .custom(command: "nvim-qt --maximized"))
        #expect(s.defaultEditor(installed: [zed])?.name == "nvim-qt")
    }

    @Test func aPickedDefaultWinsUntilItIsUnavailable() {
        var s = AppSettings()
        s.customCommand = "vim"
        s.defaultEditorID = cursor
        #expect(s.defaultEditor(installed: [zed, cursor]) == .app(.cursor))
        #expect(s.defaultEditor(installed: [zed]) == .custom(command: "vim"))
    }

    @Test func noEditorsMeansNoDefault() {
        #expect(AppSettings().defaultEditor(installed: []) == nil)
    }

    @Test func findsProjectsShallowestFirstAndSkipsDependencies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in [
            "App.xcodeproj/project.xcworkspace",
            "App.xcworkspace",
            "ios/Mobile.xcodeproj",
            "node_modules/dep/Dep.xcodeproj",
            "Pods/Pods.xcodeproj",
            ".hidden/Secret.xcodeproj",
        ] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let found = XcodeProjects.find(in: root.path)
        #expect(found.map(\.relativePath) == ["App.xcodeproj", "App.xcworkspace", "ios/Mobile.xcodeproj"])
        #expect(found.last?.path == root.path + "/ios/Mobile.xcodeproj")
    }
}
