import Foundation

/// Editors Domestique can launch by bundle ID, so they work without a CLI on PATH. First installed wins as the default.
public enum KnownEditor: String, CaseIterable, Sendable, Identifiable {
    case zed = "dev.zed.Zed"
    case cursor = "com.todesktop.230313mzl4w4u92"
    case vsCode = "com.microsoft.VSCode"
    case windsurf = "com.exafunction.windsurf"
    case sublime = "com.sublimetext.4"
    case nova = "com.panic.Nova"
    case bbEdit = "com.barebones.bbedit"

    public var id: String { rawValue }
    public var bundleID: String { rawValue }

    public var displayName: String {
        switch self {
        case .zed: "Zed"
        case .cursor: "Cursor"
        case .vsCode: "VS Code"
        case .windsurf: "Windsurf"
        case .sublime: "Sublime Text"
        case .nova: "Nova"
        case .bbEdit: "BBEdit"
        }
    }
}

/// Something the Open menu can hand a path to.
public enum EditorChoice: Hashable, Sendable, Identifiable {
    case app(KnownEditor)
    case custom(command: String)

    public static let customID = "custom"

    public var id: String {
        switch self {
        case .app(let editor): editor.id
        case .custom: Self.customID
        }
    }

    public var name: String {
        switch self {
        case .app(let editor): editor.displayName
        case .custom(let command): command.split(separator: " ").first.map(String.init) ?? command
        }
    }
}

extension AppSettings {
    /// The user's command, or the older `editorCommand` if they had changed it from the shipped default.
    public var customCommand: String {
        get { customEditorCommand ?? (editorCommand == "cursor" ? "" : editorCommand) }
        set { customEditorCommand = newValue }
    }

    public func isEditorEnabled(_ editor: KnownEditor) -> Bool {
        !(disabledEditorIDs ?? []).contains(editor.id)
    }

    public mutating func setEditor(_ editor: KnownEditor, enabled: Bool) {
        var disabled = Set(disabledEditorIDs ?? [])
        if enabled { disabled.remove(editor.id) } else { disabled.insert(editor.id) }
        disabledEditorIDs = disabled.isEmpty ? nil : disabled.sorted()
    }

    /// What the Open menu lists, given the bundle IDs installed on this Mac.
    public func editorChoices(installed: Set<String>) -> [EditorChoice] {
        var choices = KnownEditor.allCases
            .filter { installed.contains($0.bundleID) && isEditorEnabled($0) }
            .map(EditorChoice.app)
        let command = customCommand.trimmingCharacters(in: .whitespaces)
        if !command.isEmpty { choices.append(.custom(command: command)) }
        return choices
    }

    /// What "Open in editor" uses: the picked editor if still available, else a custom command, else the first listed.
    public func defaultEditor(installed: Set<String>) -> EditorChoice? {
        let choices = editorChoices(installed: installed)
        if let picked = choices.first(where: { $0.id == defaultEditorID }) { return picked }
        return choices.first { $0.id == EditorChoice.customID } ?? choices.first
    }
}

public struct XcodeProject: Hashable, Sendable, Identifiable {
    public let path: String
    /// Relative to the scanned folder; what the menu shows.
    public let relativePath: String

    public var id: String { path }
}

public enum XcodeProjects {
    static let skippedFolders: Set<String> = ["node_modules", "Pods", "Carthage", "DerivedData", "build", "vendor"]

    /// Finds `.xcodeproj` and `.xcworkspace` bundles under `root`, shallowest first.
    public static func find(in root: String, maxDepth: Int = 5) -> [XcodeProject] {
        var found: [XcodeProject] = []
        scan(root: root, relative: "", depth: 0, maxDepth: maxDepth, into: &found)
        return found.sorted {
            let depths = ($0.relativePath.split(separator: "/").count, $1.relativePath.split(separator: "/").count)
            return depths.0 != depths.1 ? depths.0 < depths.1 : $0.relativePath < $1.relativePath
        }
    }

    private static func scan(root: String, relative: String, depth: Int, maxDepth: Int, into found: inout [XcodeProject]) {
        let folder = relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for entry in entries {
            // Not resolved through symlinks, so links can't loop the scan.
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = entry.lastPathComponent
            let path = relative.isEmpty ? name : relative + "/" + name
            if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                found.append(XcodeProject(path: (root as NSString).appendingPathComponent(path), relativePath: path))
            } else if depth < maxDepth, !skippedFolders.contains(name) {
                scan(root: root, relative: path, depth: depth + 1, maxDepth: maxDepth, into: &found)
            }
        }
    }
}
