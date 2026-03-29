import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI may create `NSWindow`s after `App.init`; re-apply whenever a window becomes key.
    private var windowKeyObserver: NSObjectProtocol?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        disableTabbingChromeForAllWindows()

        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.disableTabbingChrome(for: window)
        }

        // SwiftUI’s `WindowGroup` window can appear immediately after this returns.
        DispatchQueue.main.async { [weak self] in
            self?.disableTabbingChromeForAllWindows()
        }
    }

    deinit {
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
    }

    /// “+” tabbing replaces the green zoom/full-screen control unless tabbing is off for each window.
    private func disableTabbingChromeForAllWindows() {
        NSWindow.allowsAutomaticWindowTabbing = false
        for window in NSApp.windows {
            disableTabbingChrome(for: window)
        }
    }

    private func disableTabbingChrome(for window: NSWindow) {
        NSWindow.allowsAutomaticWindowTabbing = false
        window.tabbingMode = .disallowed
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
