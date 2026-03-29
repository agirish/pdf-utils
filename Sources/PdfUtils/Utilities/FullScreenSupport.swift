import AppKit

/// Remembers the `WindowGroup` host window so full-screen toggles work when `keyWindow` / `mainWindow` are unset.
@MainActor
enum FullScreenSupport {
    private static weak var hostingWindow: NSWindow?

    static func noteHostingWindow(_ window: NSWindow?) {
        hostingWindow = window
    }

    static func toggle() {
        guard let window = bestWindow() else { return }
        if !window.collectionBehavior.contains(.fullScreenPrimary) {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        window.toggleFullScreen(nil)
    }

    private static func bestWindow() -> NSWindow? {
        if let w = hostingWindow { return w }
        if let w = NSApp.keyWindow, w.isVisible { return w }
        if let w = NSApp.mainWindow, w.isVisible { return w }
        return visibleDocumentWindow()
    }

    private static func visibleDocumentWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.level == .normal }
    }
}
