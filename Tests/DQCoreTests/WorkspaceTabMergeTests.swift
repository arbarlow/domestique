import Foundation
import Testing

@testable import DQCore

@Suite struct WorkspaceTabMergeTests {
    private let first = ChatTab(provider: .claude, permissionMode: .bypass)
    private let second = ChatTab(provider: .claude, permissionMode: .bypass)

    private func workspace(tabs: [ChatTab], selected: UUID?) -> Workspace {
        Workspace(
            repoID: UUID(), name: "w", branch: "b", path: "/w", baseBranch: "main", portBase: 41010, tabs: tabs,
            selectedTabID: selected)
    }

    @Test func anotherInstancesSelectionDoesNotMoveThisOne() {
        let local = workspace(tabs: [first, second], selected: second.id)
        var theirs = workspace(tabs: [first, second], selected: first.id)
        theirs.keepLocalTabState(from: local, opening: [])
        #expect(theirs.selectedTabID == second.id)
    }

    @Test func aTabStillOpeningSurvivesAStaleRead() {
        let local = workspace(tabs: [first, second], selected: second.id)
        var theirs = workspace(tabs: [first], selected: first.id)
        theirs.keepLocalTabState(from: local, opening: [second.id])
        #expect(theirs.tabs.map(\.id) == [first.id, second.id])
        #expect(theirs.selectedTabID == second.id)
    }

    @Test func aTabClosedElsewhereFallsBackToTheirSelection() {
        let local = workspace(tabs: [first, second], selected: second.id)
        var theirs = workspace(tabs: [first], selected: first.id)
        theirs.keepLocalTabState(from: local, opening: [])
        #expect(theirs.tabs.map(\.id) == [first.id])
        #expect(theirs.selectedTabID == first.id)
    }
}
