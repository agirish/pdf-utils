import AppKit
import SwiftUI

@main
struct PdfUtilsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Prefer the green zoom / full-screen traffic light over tabbing “+” (system may still override).
        // Do not mutate each NSWindow’s styleMask or collectionBehavior — that breaks native full screen on some macOS versions (see e0656fc).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1040, height: 720)

        Settings {
            SettingsView()
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentMinSize)
    }
}
