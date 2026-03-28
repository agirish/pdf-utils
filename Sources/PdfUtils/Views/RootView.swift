import SwiftUI

/// Grabs the `NSWindow` that hosts `WindowGroup` so full-screen toggles work when `keyWindow` / `mainWindow` are nil.
private struct MainWindowAccessor: NSViewRepresentable {
    private final class WindowAccessorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            FullScreenSupport.noteHostingWindow(window)
            // SwiftUI may reset `NSWindow` chrome after this pass; re-apply on the next main-queue turn.
            DispatchQueue.main.async {
                FullScreenSupport.noteHostingWindow(self.window)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        WindowAccessorView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            DashboardView()
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(MainWindowAccessor())
    }
}
