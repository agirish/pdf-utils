import AppKit
import Foundation

enum FullScreenSupport {
    /// Toggles full screen on the key window (standard macOS full-screen space).
    static func toggle() {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else {
            return
        }
        window.toggleFullScreen(nil)
    }
}
