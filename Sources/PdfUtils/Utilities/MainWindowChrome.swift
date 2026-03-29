import AppKit

/// AppKit tweaks for the SwiftUI `WindowGroup` host so the green control is **zoom / full screen**, not the tab **“+”**, and full screen is allowed.
///
/// On recent macOS (incl. 26.x), relying only on `NSWindow.allowsAutomaticWindowTabbing` is unreliable; SwiftUI may recreate or adjust chrome after launch.
enum MainWindowChrome {
    @MainActor
    static func applyToHostWindow(_ window: NSWindow) {
        NSWindow.allowsAutomaticWindowTabbing = false
        window.tabbingMode = .disallowed

        var behavior = window.collectionBehavior
        behavior.remove(.fullScreenNone)
        behavior.insert(.fullScreenPrimary)
        window.collectionBehavior = behavior

        var mask = window.styleMask
        mask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.styleMask = mask

        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        FullScreenSupport.noteHostingWindow(window)
    }
}
