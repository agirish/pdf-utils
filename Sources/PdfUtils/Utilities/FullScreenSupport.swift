import AppKit

/// Remembers the `WindowGroup` host window so full-screen toggles work when `keyWindow` / `mainWindow` are unset.
enum FullScreenSupport {
    private static weak var hostingWindow: NSWindow?

    static func noteHostingWindow(_ window: NSWindow?) {
        hostingWindow = window
    }

    static func toggle() {
        guard let window = hostingWindow ?? NSApp.keyWindow ?? NSApp.mainWindow ?? visibleDocumentWindow() else {
            return
        }
        window.toggleFullScreen(nil)
    }

    private static func visibleDocumentWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.level == .normal }
    }
}
