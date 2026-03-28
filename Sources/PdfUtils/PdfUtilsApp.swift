import AppKit
import SwiftUI

@main
struct PdfUtilsApp: App {
    init() {
        // Enforce standard GUI activation policy. When running directly via `swift run` or as an unbundled executable,
        // this guarantees the app has a menu bar and natively supports full-screen spaces.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Without this, macOS can show a title-bar “+” for window tabbing instead of the usual zoom / full-screen traffic light.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1040, height: 720)
    }
}
