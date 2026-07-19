import AppKit
import SwiftUI
import PdfToolkit

@main
struct PdfUtilsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Drives the in-window Settings overlay (SyncCloud pattern): ⌘, and the toolbar gears both
    /// open it through this shared presenter rather than a separate Settings window.
    @StateObject private var settingsPresenter = SettingsPresenter()

    init() {
        // Prefer the green zoom / full-screen traffic light over tabbing “+” (system may still override).
        // Do not mutate each NSWindow’s styleMask or collectionBehavior — that breaks native full screen on some macOS versions (see e0656fc).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settingsPresenter)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            // Replace the default ⌘, (which would open a native Settings scene) with one that
            // raises the in-window overlay.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { settingsPresenter.open() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
