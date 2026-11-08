import AppKit
import DQCore
import Observation
import SwiftTerm

/// Follows light and dark mode. SwiftTerm flattens its default colors to RGB when they're
/// assigned, so they have to be assigned again each time the appearance changes.
final class AppearanceTerminalView: LocalProcessTerminalView {
    func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .textBackgroundColor
            nativeForegroundColor = NSColor.textColor.usingColorSpace(.sRGB) ?? .textColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        applyAppearanceColors()
        super.viewDidChangeEffectiveAppearance()
    }
}

/// A terminal tab. Owns its SwiftTerm view so the shell survives inspector tab switches.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    var title: String
    private(set) var exited = false
    @ObservationIgnored let view: AppearanceTerminalView
    @ObservationIgnored private var delegateProxy: Proxy?
    @ObservationIgnored private var started = false
    var isStarted: Bool { started }
    private let cwd: String
    private let extraEnv: [String: String]
    @ObservationIgnored private let host: any ExecutionHost
    /// Set when the shell couldn't start (e.g. the cloud machine didn't come up).
    private(set) var startError: String?

    init(title: String, cwd: String, extraEnv: [String: String], host: any ExecutionHost = LocalHost.shared) {
        self.title = title
        self.cwd = cwd
        self.extraEnv = extraEnv
        self.host = host
        view = AppearanceTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.applyAppearanceColors()
        let proxy = Proxy(owner: self)
        delegateProxy = proxy
        view.processDelegate = proxy
    }

    /// Started lazily on first display so the PTY gets a real size.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        if !host.isLocal {
            startRemote()
            return
        }
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

    /// `ssh -tt` into the machine, `cd` to the clone, login shell.
    private func startRemote() {
        let host = self.host
        let cwd = self.cwd
        var env = extraEnv
        env["COLORTERM"] = "truecolor"
        view.feed(text: "Connecting to \(host.displayName)…\r\n")
        Task {
            do {
                try await host.prepare()
                let cmd = try await host.command("bash", ["-l"], cwd: cwd, env: env, tty: true)
                var local = cmd.environment
                local["TERM"] = "xterm-256color"
                view.startProcess(
                    executable: cmd.executable, args: cmd.arguments, environment: local.map { "\($0.key)=\($0.value)" },
                    execName: nil, currentDirectory: cmd.cwd)
            } catch {
                startError = error.localizedDescription
                view.feed(text: "\r\nCouldn't connect: \(error.localizedDescription)\r\n")
                exited = true
            }
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
