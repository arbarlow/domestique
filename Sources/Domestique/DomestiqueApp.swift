import AppKit
import DQCore
import SwiftUI

@main
struct DomestiqueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("Domestique", id: "main") {
            RootView()
                .environment(app)
                .onAppear {
                    delegate.app = app
                    DevSnapshots.run(app: app)
                }
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1480, height: 920)
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(app: app) }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var app: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashCapture.install()
        NSSetUncaughtExceptionHandler { exc in
            let text = "\(Date()) UNCAUGHT \(exc.name.rawValue): \(exc.reason ?? "")\n"
                + exc.callStackSymbols.prefix(80).joined(separator: "\n") + "\n\n"
            try? text.write(to: Paths.logs.appendingPathComponent("crash.log"), atomically: true, encoding: .utf8)
        }
        // Running as a bare SPM executable (swift run) needs this to get a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        installSignalHandlers()
    }

    /// SIGTERM/SIGINT/SIGHUP (kill, Ctrl-C, logout) would otherwise skip applicationWillTerminate and
    /// orphan dev servers. Route them through a normal terminate so task process groups get killed.
    private var signalSources: [DispatchSourceSignal] = []

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { app?.shutdown() }
    }
}

struct AppCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task {
                    await app.updater.check(userInitiated: true)
                    guard app.updater.available.isEmpty else { return }  // the sidebar button takes it from here
                    if case .failed(let message) = app.updater.phase {
                        app.alert = AppAlert(title: "Couldn't check for updates", message: message)
                        app.updater.dismissError()
                    } else {
                        app.alert = AppAlert(
                            title: "Domestique is up to date", message: "Build \(app.updater.currentBuild) is the latest.")
                    }
                }
            }
            .disabled(!app.updater.isEnabled)
        }
        // Settings open inside the main window, not as a separate one.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.settingsRoute = app.settingsRoute == nil ? .general : nil }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Workspace") {
                guard let repoID = app.selectedRepo?.id ?? app.repositories.first?.id,
                    let repo = app.repo(repoID)
                else { return app.promptAddRepository() }
                Task { await app.createWorkspace(in: repo) }
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("New Cloud Workspace (boat.dev)") {
                let repo = app.selectedWorkspaceModel?.repo ?? app.repositories.first
                if let repo { Task { await app.createWorkspace(in: repo, location: .cloud(.boat)) } } else { app.promptAddRepository() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Workspace from Pull Request…") {
                guard let repo = app.selectedRepo ?? app.repositories.first else { return app.promptAddRepository() }
                app.pullRequestPickerRepo = repo
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Chat Tab") { app.selectedWorkspaceModel?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Reopen Closed Chat Tab") { app.selectedWorkspaceModel?.reopenLastClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(app.selectedWorkspaceModel?.closedTabs.isEmpty ?? true)
            Button("Previous Chat Tab") { app.selectedWorkspaceModel?.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Chat Tab") { app.selectedWorkspaceModel?.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("New Terminal") { app.selectedWorkspaceModel?.newTerminal() }
                .keyboardShortcut("`", modifiers: .control)
            Divider()
            Button("Add Repository…") { app.promptAddRepository() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Clone from GitHub…") { app.showGitHubPicker = true }
                .keyboardShortcut("o", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { app.sidebarVisible.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
            Button("Toggle Panel") { app.rightPanelVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Toggle Run Dock") { app.selectedWorkspaceModel?.dockExpanded.toggle() }
                .keyboardShortcut("j", modifiers: .command)
        }
        CommandMenu("Workspace") {
            Button("Run Stack") { app.selectedWorkspaceModel?.startDefaultStack() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Stop Agent") { app.selectedWorkspaceModel?.selectedChat?.interrupt() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.offset) { i, tab in
                Button("Show \(tab.title)") {
                    app.rightPanelVisible = true
                    app.selectedWorkspaceModel?.openedFile = nil
                    app.selectedWorkspaceModel?.panelTab = tab
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
            Divider()
            Button("Open in Editor") { app.selectedWorkspaceModel?.openInEditor() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Reveal in Finder") { app.selectedWorkspaceModel?.revealInFinder() }
        }
    }
}

/// Principal class (see Info.plist). Writes uncaught AppKit exceptions to the logs dir before crashing.
@objc(DQApplication)
final class DQApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        let text = "\(Date()) \(exception.name.rawValue): \(exception.reason ?? "")\n"
            + exception.callStackSymbols.prefix(40).joined(separator: "\n") + "\n\n"
        let url = Paths.logs.appendingPathComponent("exceptions.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        FileHandle.standardError.write(Data(text.utf8))
        super.reportException(exception)
    }
}

/// AppKit layout exceptions go through +[NSApplication _crashOnException:], not reportException.
/// Log them so crashes are diagnosable.
enum CrashCapture {
    nonisolated(unsafe) static var original: IMP?

    static func install() {
        let sel = NSSelectorFromString("_crashOnException:")
        guard let method = class_getClassMethod(NSApplication.self, sel) else { return }
        original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, NSException) -> Void = { cls, exc in
            let text = "\(Date()) CRASH \(exc.name.rawValue): \(exc.reason ?? "")\n"
                + exc.callStackSymbols.prefix(60).joined(separator: "\n") + "\n\n"
            try? text.write(to: Paths.logs.appendingPathComponent("crash.log"), atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data(text.utf8))
            typealias Fn = @convention(c) (AnyObject, Selector, NSException) -> Void
            if let original { unsafeBitCast(original, to: Fn.self)(cls, sel, exc) }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

enum Trace {
    static func log(_ s: String) {
        guard DebugFlags.has("trace") else { return }
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        let url = Paths.logs.appendingPathComponent("trace.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
