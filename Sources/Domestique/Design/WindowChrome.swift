import AppKit
import SwiftUI

/// With `.hiddenTitleBar` the traffic lights sit in a 28pt strip. Our header rows are taller
/// (Theme.headerHeight), so we grow the titlebar container and re-centre the buttons in it.
struct WindowChrome: NSViewRepresentable {
    var height: CGFloat = Theme.headerHeight
    var leading: CGFloat = 18

    func makeNSView(context: Context) -> NSView {
        let v = ChromeView()
        v.height = height
        v.leading = leading
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ChromeView: NSView {
        var height: CGFloat = 46
        var leading: CGFloat = 18
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
            ]
            for name in names {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.layoutButtons() }
                    })
            }
            DispatchQueue.main.async { self.layoutButtons() }
        }

        override func layout() {
            super.layout()
            layoutButtons()
        }

        private func layoutButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                let close = window.standardWindowButton(.closeButton),
                let mini = window.standardWindowButton(.miniaturizeButton),
                let zoom = window.standardWindowButton(.zoomButton),
                let titlebar = close.superview, let container = titlebar.superview
            else { return }
            // Grow the titlebar container to our header height.
            var frame = container.frame
            if abs(frame.height - height) > 0.5 {
                frame.size.height = height
                frame.origin.y = window.frame.height - height
                container.frame = frame
            }
            let spacing: CGFloat = 20
            for (i, button) in [close, mini, zoom].enumerated() {
                let y = (titlebar.frame.height - button.frame.height) / 2
                let origin = NSPoint(x: leading + CGFloat(i) * spacing, y: y.rounded())
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }

        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
