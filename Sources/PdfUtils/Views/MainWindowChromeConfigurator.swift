import AppKit
import SwiftUI

/// Attach to root `WindowGroup` content so we always configure the *same* `NSWindow` that hosts the UI (SwiftUI may create it after `App.init` / `applicationDidFinishLaunching`).
private struct MainWindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        MainWindowChrome.applyToHostWindow(window)
        // SwiftUI frequently reconfigures the title bar; re-apply on the next turn of the run loop.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            MainWindowChrome.applyToHostWindow(window)
        }
    }
}

extension View {
    /// Ensures the hosting `NSWindow` keeps standard zoom / full-screen traffic-light behavior.
    func mainWindowChromeConfigured() -> some View {
        background { MainWindowChromeConfigurator() }
    }
}
