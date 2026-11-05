import SwiftUI

/// Right-hand panel: files / changes / checks on top, Setup / Run / Terminal dock below.
struct RightPanelView: View {
    let model: WorkspaceModel
    @AppStorage("dq.dockHeight") private var dockHeight: Double = 280

    private static let dockBarHeight: CGFloat = 36
    private static let minTop: CGFloat = 160
    private static let minDock: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            let maxDock = max(Self.minDock, geo.size.height - Theme.headerHeight - 38 - Self.minTop)
            let dock = min(max(CGFloat(dockHeight), Self.minDock), maxDock)
            VStack(spacing: 0) {
                PanelHeader(model: model)
                Hairline()
                PanelTabsRow(model: model)
                Hairline()
                PanelContent(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.dockExpanded {
                    ResizeHandle(axis: .vertical) { delta in
                        dockHeight = Double(min(max(CGFloat(dockHeight) - delta, Self.minDock), maxDock))
                    }
                    DockView(model: model)
                        .frame(height: dock)
                } else {
                    Hairline()
                    DockView(model: model)
                        .frame(height: Self.dockBarHeight)
                }
            }
        }
        .background(Theme.panel)
        .onAppear { model.refreshPanel() }
        .onChange(of: model.diffFiles) { _, _ in model.refreshGitState() }
        .onChange(of: model.shipBusy) { _, busy in if busy == nil { model.refreshGitState() } }
    }
}

/// Top content: the selected tab, or the file viewer when a file is open.
private struct PanelContent: View {
    let model: WorkspaceModel

    var body: some View {
        if let opened = model.openedFile {
            FileViewer(model: model, opened: opened)
                .id(opened)
        } else {
            switch model.panelTab {
            case .changes: ChangesTab(model: model)
            case .files: FilesTab(model: model)
            case .checks: ChecksTab(model: model)
            }
        }
    }
}

// MARK: - Tabs row

private struct PanelTabsRow: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                PillTab(
                    title: tab.title,
                    count: tab == .changes ? model.diffFiles.count : nil,
                    selected: model.panelTab == tab && model.openedFile == nil
                ) {
                    model.panelTab = tab
                    model.openedFile = nil
                    if tab == .files, model.files.isEmpty { model.refreshFiles() }
                    if tab == .checks { model.refreshPR() }
                }
            }
            Spacer(minLength: 8)
            if model.isLoadingDiff {
                Spinner(size: 11)
                    .padding(.trailing, 4)
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh") { model.refreshPanel() }
            IconButton(symbol: "arrow.up.forward.app", help: "Open worktree in editor (⇧⌘E)") { model.openInEditor() }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }
}
