import AppKit
import DQCore
import Observation
import SwiftTerm

/// A terminal tab. Owns its SwiftTerm view so the shell survives inspector tab switches.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    var title: String
    private(set) var exited = false
    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private var delegateProxy: Proxy?
    @ObservationIgnored private var started = false
    var isStarted: Bool { started }
    private let cwd: String
    private let extraEnv: [String: String]

    init(title: String, cwd: String, extraEnv: [String: String]) {
        self.title = title
        self.cwd = cwd
        self.extraEnv = extraEnv
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor.textBackgroundColor
        view.nativeForegroundColor = NSColor.textColor
        let proxy = Proxy(owner: self)
        delegateProxy = proxy
        view.processDelegate = proxy
    }

    /// Started lazily on first display so the PTY gets a real size.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task {
            var env = await LoginEnvironment.shared.environment()
            env.merge(extraEnv) { $1 }
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            let shell = env["SHELL"] ?? "/bin/zsh"
            let pairs = env.map { "\($0.key)=\($0.value)" }
            view.startProcess(
                executable: shell, args: ["-l"], environment: pairs,
                execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: cwd)
        }
    }

    func terminate() {
        if started && !exited { view.terminate() }
    }

    fileprivate func processEnded() { exited = true }

    private final class Proxy: LocalProcessTerminalViewDelegate {
        weak var owner: TerminalSession?
        init(owner: TerminalSession) { self.owner = owner }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            let t = title
            MainActor.assumeIsolated { if !t.isEmpty { owner?.title = t } }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            MainActor.assumeIsolated { owner?.processEnded() }
        }
    }
}
