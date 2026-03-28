import AppKit
import Foundation

@MainActor
enum FullScreenSupport {
    /// `WindowGroup` content often runs when `keyWindow` / `mainWindow` are still nil; keep the concrete hosting window.
    private static weak var hostingWindow: NSWindow?

    /// Called from the root view hierarchy so full screen always has a real `NSWindow`.
    static func noteHostingWindow(_ window: NSWindow?) {
        guard let window else { return }
        hostingWindow = window
        configureHostingWindow(window)
    }

    private static func configureHostingWindow(_ window: NSWindow) {
        window.tabbingMode = .disallowed
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }

    /// Toggles full screen on the key window (standard macOS full-screen space).
    static func toggle() {
        guard let raw = hostingWindow
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.reversed().first(where: eligibleForFullScreen)
        else {
            return
        }

        var window = raw
        while window.isSheet, let parent = window.parent {
            window = parent
        }

        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
    }

    private static func eligibleForFullScreen(_ window: NSWindow) -> Bool {
        window.isVisible
            && window.level == .normal
            && !window.styleMask.contains(.nonactivatingPanel)
    }
}
