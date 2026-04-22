import AppKit
import SwiftUI
import PdfToolkit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    private func applyDockIconIfAvailable() {
        let candidates: [(name: String, ext: String?, subdirectory: String?)] = [
            ("icon_512x512@2x", "png", "Assets.xcassets/AppIcon.appiconset"),
            ("icon_512x512", "png", "Assets.xcassets/AppIcon.appiconset"),
            ("AppIcon", "icns", nil),
        ]

        func applyIcon(at url: URL) -> Bool {
            guard let icon = NSImage(contentsOf: url) else {
                return false
            }
            NSApp.applicationIconImage = icon
            NSLog("Dock icon applied from: \(url.path)")
            return true
        }

        for candidate in candidates {
            guard let url = Bundle.module.url(
                forResource: candidate.name,
                withExtension: candidate.ext,
                subdirectory: candidate.subdirectory
            ) else {
                continue
            }

            if applyIcon(at: url) {
                return
            }
        }

#if DEBUG
        // Last-resort fallback when running from package schemes that don't materialize resources as expected.
        let sourceIcon = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
        if applyIcon(at: sourceIcon) {
            return
        }
#endif

        NSLog("Dock icon could not be applied from bundle or source fallback.")
    }

    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyDockIconIfAvailable()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            // Re-apply after launch in case the Dock initialized before resources were loaded.
            self.applyDockIconIfAvailable()
            NSApp.mainMenu?.items.first?.title = AppBrand.displayName
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppStateManager.shared
        if state.hasPendingOperations {
            let alert = NSAlert()
            alert.messageText = "Operation in Progress"
            alert.informativeText = "The following operations are still running: \(state.pendingOperationsDescription).\n\nClosing the application will abort them. Are you sure you want to quit?"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                return .terminateNow
            } else {
                return .terminateCancel
            }
        }
        return .terminateNow
    }
}
