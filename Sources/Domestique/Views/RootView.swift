import DQCore
import SwiftUI

/// Three columns, Codex/Conductor style: sidebar | conversation | right panel.
/// Custom HStack + drag handles instead of NavigationSplitView/inspector: full control over chrome,
/// and no NSSplitView constraint negotiation.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("dq.sidebarWidth") private var sidebarWidth: Double = 260
    @AppStorage("dq.rightWidth") private var rightWidth: Double = 540

    var body: some View {
        @Bindable var app = app
        let model = app.selectedWorkspaceModel
        GeometryReader { geo in
            HStack(spacing: 0) {
                if app.sidebarVisible {
                    SidebarView()
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading))
                    ResizeHandle(axis: .horizontal) { dx in
                        sidebarWidth = min(420, max(200, sidebarWidth + dx))
                    }
                }
                Group {
                    if let route = app.settingsRoute {
                        SettingsPage(route: route)
                    } else if let model {
                        WorkspaceDetailView(model: model)
                            .id(model.id)
                    } else {
                        EmptyStateView()
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)

                if app.rightPanelVisible, app.settingsRoute == nil, let model {
                    ResizeHandle(axis: .horizontal) { dx in
                        let maxW = max(360, geo.size.width - (app.sidebarVisible ? sidebarWidth : 0) - 420)
                        rightWidth = min(maxW, max(340, rightWidth - dx))
                    }
                    RightPanelView(model: model)
                        .id(model.id)
                        .frame(width: clampedRight(total: geo.size.width))
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Theme.canvas)
        .background(WindowChrome())
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.22), value: app.sidebarVisible)
        .animation(.snappy(duration: 0.22), value: app.rightPanelVisible)
        .animation(.snappy(duration: 0.18), value: app.settingsRoute)
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }

    private func clampedRight(total: CGFloat) -> CGFloat {
        let available = total - (app.sidebarVisible ? sidebarWidth : 0) - 380
        return max(300, min(rightWidth, available))
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !app.sidebarVisible {
                    Spacer().frame(width: 76)
                    IconButton(symbol: "sidebar.left", help: "Show sidebar") { app.sidebarVisible = true }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .headerBar()
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "bicycle")
                    .font(.system(size: 40, weight: .ultraLight))
                    .foregroundStyle(Theme.text3)
                Text(app.repositories.isEmpty ? "Add a repository to get started" : "Pick a workspace or start a new one")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("Every workspace is an isolated git worktree branched from a fresh origin.")
                    .font(Theme.ui)
                    .foregroundStyle(Theme.text2)
                if app.repositories.isEmpty {
                    Button("Add repository…") { app.promptAddRepository() }
                        .buttonStyle(.softProminent)
                        .padding(.top, 6)
                }
            }
            Spacer()
        }
    }
}

enum DebugFlags {
    static let flags = Set((ProcessInfo.processInfo.environment["DQ_DEBUG"] ?? "").split(separator: ",").map(String.init))
    static func has(_ f: String) -> Bool { flags.contains(f) }
}
