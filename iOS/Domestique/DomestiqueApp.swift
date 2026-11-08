import SwiftUI

/// Domestique for iPhone: a thin client for your servers. Every workspace, agent and transcript lives
/// on a server; the phone connects to each one directly over the Domestique protocol.
@main
struct DomestiqueApp: App {
    @State private var serverList = ServerList()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(serverList)
                .tint(Palette.text)        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { serverList.wake() }
        }
    }
}
