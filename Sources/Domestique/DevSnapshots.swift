import AppKit
import SwiftUI

/// Dev tool: `DOMESTIQUE_SNAPSHOT_DIR=/tmp/shots swift run DomestiqueDev` opens each settings page in
/// the real window, saves light and dark PNGs of it, and quits. Renders AppKit-backed controls
/// (pickers, fields, switches) faithfully, unlike ImageRenderer, and needs no screen-recording access.
@MainActor
enum DevSnapshots {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["DOMESTIQUE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(app: AppModel) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { exit(1) }
            window.setContentSize(NSSize(width: 1240, height: 860))
            var routes: [(String, SettingsRoute)] = [
                ("general", .general), ("agents", .agents), ("teamcars", .teamCars), ("cloud", .cloud),
            ]
            if let repo = app.repositories.first { routes.append(("repo", .repo(repo.id))) }
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                for (name, route) in routes {
                    app.settingsRoute = route
                    try? await Task.sleep(for: .seconds(1.2))
                    save(window, to: dir.appending(path: "\(name)-\(appearanceName).png"))
                }
            }
            exit(0)
        }
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
