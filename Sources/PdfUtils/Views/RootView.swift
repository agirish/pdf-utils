import SwiftUI

/// Grabs the `NSWindow` that hosts `WindowGroup` so full-screen toggles work when `keyWindow` / `mainWindow` are nil.
private struct MainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        FullScreenSupport.noteHostingWindow(nsView.window)
    }
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
