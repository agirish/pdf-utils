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
        // Removing .fullScreenAllowsTiling and inserting .fullScreenDisallowsTiling on modern macOS 
        // explicitly strips the full-screen behavior from the green zoom button, forcing it back to a standard "+".
        // Instead, we let SwiftUI's default WindowGroup handle the collection behavior so full screen works cleanly.
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
        while window.isSheet, let parent = window.sheetParent {
            window = parent
        }

        window.toggleFullScreen(nil)
    }

    private static func eligibleForFullScreen(_ window: NSWindow) -> Bool {
        window.isVisible
            && window.level == .normal
            && !window.styleMask.contains(.nonactivatingPanel)
    }
}
