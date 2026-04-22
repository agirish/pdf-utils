import AppKit
import SwiftUI
import PdfToolkit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    private func applyDockIconIfAvailable() {
        // SwiftPM places app assets in the module bundle when running package schemes.
        guard let iconURL = Bundle.module.url(
            forResource: "icon_512x512@2x",
            withExtension: "png",
            subdirectory: "Assets.xcassets/AppIcon.appiconset"
        ),
        let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyDockIconIfAvailable()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
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
