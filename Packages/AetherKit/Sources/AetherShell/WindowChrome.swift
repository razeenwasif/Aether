import AppKit
import SwiftUI

/// Stacks the window's traffic lights down the 32 pt rail (RESEARCH_PLAN.md
/// §6.5, Q5). The system buttons stay the system's: their container is
/// re-laid out, as Electron's `trafficLightPosition` does, and laid out again
/// whenever AppKit puts it back (resize, full screen, key changes).
struct WindowChrome: NSViewRepresentable {
    /// The rail space the three lights take, from the window's top.
    static let lightsHeight: CGFloat = 70

    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.layoutLights() }

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // The canvas drags; the window moves by its rail and title strip only.
            window.isMovableByWindowBackground = false
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutLights() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.layoutLights() }
        }

        func layoutLights() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let mini = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let titlebar = close.superview,
                  let container = titlebar.superview
            else { return }
            let size = close.frame.size
            let gap: CGFloat = 6
            let top: CGFloat = 13
            let height = WindowChrome.lightsHeight
            container.frame = NSRect(x: 0, y: window.frame.height - height, width: 32, height: height)
            titlebar.frame = container.bounds
            for (index, button) in [close, mini, zoom].enumerated() {
                let y = height - top - size.height - CGFloat(index) * (size.height + gap)
                button.setFrameOrigin(NSPoint(x: (32 - size.width) / 2, y: y))
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
            }
        }
    }
}
