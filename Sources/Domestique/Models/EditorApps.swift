import AppKit
import DQCore

struct InstalledApp {
    let url: URL
    let icon: NSImage
}

@MainActor
enum EditorApps {
    static let xcodeBundleID = "com.apple.dt.Xcode"

    /// Known editors and Xcode found on this Mac, keyed by bundle ID.
    static func installed() -> [String: InstalledApp] {
        var apps: [String: InstalledApp] = [:]
        for id in KnownEditor.allCases.map(\.bundleID) + [xcodeBundleID] {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            apps[id] = InstalledApp(url: url, icon: icon)
        }
        return apps
    }
}
