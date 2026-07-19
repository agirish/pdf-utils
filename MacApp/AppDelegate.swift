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
        // Move any pre-GlassLevel install onto the new appearance model before the first
        // @AppStorage read, then set NSApp.appearance before any window exists so the title bar and
        // panels open in the chosen theme rather than flashing the system appearance first.
        LiquidGlass.migrateLegacyAppearance()
        AppAppearance.applyPersisted()
        // Seed the log's minimum level from the persisted setting before any operation records.
        ActivityLog.shared.minimumLevel = ActivityLog.persistedMinimumLevel()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.mainMenu?.items.first?.title = AppBrand.displayName
        }
        // A launch breadcrumb gives the Activity Log's "Show older history" a session boundary and
        // ensures the log is never empty.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        ActivityLog.shared.info("\(AppBrand.displayName) \(version) launched")
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Commit any buffered Activity Log lines before we might quit, so an in-flight operation's
        // breadcrumb survives the exit. Harmless if the user then cancels the quit.
        ActivityLog.shared.flushToDisk()
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
