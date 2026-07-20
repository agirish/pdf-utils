import AppKit
import SwiftUI
import PdfToolkit

@main
struct PdfUtilsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Drives the in-window Settings overlay (SyncCloud pattern): ⌘, and the toolbar gears both
    /// open it through this shared presenter rather than a separate Settings window.
    @StateObject private var settingsPresenter = SettingsPresenter()

    /// Drives the in-window ⌘K "Quick Actions" palette. Sibling of `settingsPresenter`: the ⌘K
    /// command below toggles it, and `RootView` renders the overlay from its `isPresented`.
    @StateObject private var quickActionsPresenter = QuickActionsPresenter()

    /// Drives the in-window Help book overlay. Sibling of the two above: the Help ▸ ⌘? command and the
    /// dashboard/tool "?" buttons open it through this shared presenter, and `RootView` renders it.
    @StateObject private var helpPresenter = HelpPresenter()

    init() {
        // Prefer the green zoom / full-screen traffic light over tabbing “+” (system may still override).
        // Do not mutate each NSWindow’s styleMask or collectionBehavior — that breaks native full screen on some macOS versions (see e0656fc).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settingsPresenter)
                .environmentObject(quickActionsPresenter)
                .environmentObject(helpPresenter)
        }
        // Hidden title bar (SyncCloud parity): the traffic lights float on the content and the
        // window's content backing goes transparent, which is what lets `BehindWindowGlass` show the
        // desktop at the Clear glass level. A standard title bar keeps the window opaque.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 720)
        .commands {
            // Replace the default ⌘, (which would open a native Settings scene) with one that
            // raises the in-window overlay. Close Help first so the two overlays never stack.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    helpPresenter.close()
                    settingsPresenter.open()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // ⌘K raises (and, pressed again, dismisses) the Quick Actions palette from anywhere —
            // `toggle()` rather than `open()` so the one shortcut both opens and closes it, wired
            // alongside ⌘, / ⇧⌘L. Sits just after Settings in the app menu, its ⌘-overlay sibling.
            CommandGroup(after: .appSettings) {
                Button("Quick Actions…") {
                    helpPresenter.close()
                    quickActionsPresenter.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            // Replace the whole Help menu. AppKit's default `.help` group is just the search field and
            // a "PdfUtils Help" item that — with no registered Help Book — answers "Help isn't
            // available." Swapping the group lets our in-window Help book take that slot (⌘?), and
            // hosts the Activity Log entry alongside it.
            CommandGroup(replacing: .help) {
                Button("\(AppBrand.displayName) Help") {
                    settingsPresenter.close()
                    quickActionsPresenter.close()
                    helpPresenter.openHome()
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                OpenActivityLogMenuItem()
            }
        }

        // The Activity Log lives in its own window (SyncCloud parity) so it never collides with the
        // tool navigation and can stay open beside the main window.
        Window("Activity Log", id: "activity-log") {
            ActivityLogView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 640)
    }
}

/// The Help ▸ Activity Log menu item. A standalone `View` (not inline in the `.commands` builder) so
/// it can hold `@Environment(\.openWindow)` — that action isn't available directly in the builder.
private struct OpenActivityLogMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Activity Log") { openWindow(id: "activity-log") }
            .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}
