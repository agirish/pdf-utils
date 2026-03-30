import AppKit
import SwiftUI
import PdfToolkit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Apply activation policy and Dock icon as early as possible so the process is not stuck with the generic
    /// Unix executable tile (green “exec”) in the Dock.
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ApplicationDockIcon.apply()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        ApplicationDockIcon.apply()
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
