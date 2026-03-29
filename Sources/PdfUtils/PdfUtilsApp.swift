import AppKit
import SwiftUI

@main
struct PdfUtilsApp: App {
    init() {
        // Without this, macOS can show a title-bar “+” for window tabbing instead of the usual zoom / full-screen traffic light.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Toggle Full Screen") {
                    FullScreenSupport.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
