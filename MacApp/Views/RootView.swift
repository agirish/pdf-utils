import SwiftUI
import PdfToolkit

struct RootView: View {
    @EnvironmentObject private var settings: SettingsPresenter
    @EnvironmentObject private var quickActions: QuickActionsPresenter
    @EnvironmentObject private var help: HelpPresenter
    @Environment(\.openWindow) private var openWindow

    @AppStorage(LiquidGlass.appearanceModeKey)
    private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage(LiquidGlass.levelKey)
    private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey)
    private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue
    @AppStorage(LiquidGlass.tintKey)
    private var glassTint: Double = 0

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue }

    /// The tool navigation path, owned here (not implicit) so launch can open straight to the last-used
    /// tool. Seeded in `init` rather than `onAppear`: mutating the path on the first render cycle races
    /// the `navigationDestination` registration and the push is silently dropped, so the stack must be
    /// *born* with the tool already on it.
    @State private var toolPath: [Tool]

    init() {
        _toolPath = State(initialValue: Self.initialToolPath())
    }

    /// `[lastTool]` when "Reopen last tool on launch" is on and a valid tool was recorded, else empty.
    private static func initialToolPath() -> [Tool] {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKeys.reopenLastTool),
              let raw = defaults.string(forKey: SettingsKeys.lastToolUsed),
              let tool = Tool(rawValue: raw) else { return [] }
        return [tool]
    }

    var body: some View {
        ZStack {
            NavigationStack(path: $toolPath) {
                DashboardView()
            }
            .frame(minWidth: 960, minHeight: 640)

            if settings.isPresented {
                settingsOverlay
            }

            // Layered above the Settings overlay so ⌘K stays reachable and legible even if Settings
            // happens to be open when the palette is raised.
            if quickActions.isPresented {
                quickActionsOverlay
            }

            // The Help book — same overlay treatment as Settings and ⌘K. Topmost so it always reads
            // clearly; the ⌘? command and the "?" buttons close the other overlays before opening it.
            if help.isPresented {
                helpOverlay
            }
        }
        .animation(.easeOut(duration: 0.15), value: settings.isPresented)
        .animation(.easeOut(duration: 0.15), value: quickActions.isPresented)
        .animation(.easeOut(duration: 0.15), value: help.isPresented)
        .onAppear {
            if UserDefaults.standard.string(forKey: SettingsKeys.mainWindowBackground) == "accentGradient" {
                UserDefaults.standard.set(
                    MainWindowBackgroundStyle.liquidGlass.rawValue,
                    forKey: SettingsKeys.mainWindowBackground
                )
            }
            AppAppearance.applyPersisted()
        }
        // The Theme picker lives in the overlay; re-applying here keeps NSApp and every window in
        // step no matter which view wrote the change.
        .onChange(of: appearanceModeRaw) { _, _ in
            AppAppearance.applyPersisted()
        }
        .onChange(of: settings.tab) { _, newTab in
            UserDefaults.standard.set(newTab.rawValue, forKey: SettingsTab.selectedTabDefaultsKey)
        }
    }

    /// In-window Settings overlay (SyncCloud pattern): a dimmed backdrop that dismisses on a click
    /// outside, behind the centered Settings card. Living inside the window, it floats over content
    /// even in full screen rather than opening a separate window on another Space.
    private var settingsOverlay: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                .ignoresSafeArea()
                .onTapGesture { settings.close() }

            settingsCard
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    private var settingsCard: some View {
        SettingsView(selection: $settings.tab, onClose: { settings.close() })
            .contentSurface(hue: glassHue, tint: glassTint)
            .glassCardStyle(level: glassLevel)
            .overlayCardChrome()
    }

    /// In-window ⌘K palette overlay — the exact parallel of `settingsOverlay`: the same dimmed,
    /// tap-to-dismiss backdrop behind a centered glass card. It lives here (not in the palette view)
    /// because activating an action mutates state this view owns: the tool navigation `toolPath`, the
    /// Settings presenter, and the Activity Log window.
    private var quickActionsOverlay: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                .ignoresSafeArea()
                .onTapGesture { quickActions.close() }

            quickActionsCard
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    private var quickActionsCard: some View {
        QuickActionsPalette(
            actions: QuickAction.catalog,
            onActivate: { activateQuickAction($0) },
            onClose: { quickActions.close() }
        )
        .contentSurface(hue: glassHue, tint: glassTint)
        .glassCardStyle(level: glassLevel)
        .overlayCardChrome()
    }

    /// In-window Help overlay — the exact parallel of `settingsOverlay`: a dimmed, tap-to-dismiss
    /// backdrop behind the centered Help card. It floats over the content even in full screen.
    private var helpOverlay: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                .ignoresSafeArea()
                .onTapGesture { help.close() }

            helpCard
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    private var helpCard: some View {
        HelpView(initialTopicID: help.initialTopicID, onClose: { help.close() })
            .contentSurface(hue: glassHue, tint: glassTint)
            .glassCardStyle(level: glassLevel)
            .overlayCardChrome()
    }

    /// Runs a chosen Quick Action, then dismisses the palette. Navigating replaces the stack with just
    /// the target tool, so the palette jumps straight to it from anywhere and leaves a single Back step
    /// to the dashboard.
    private func activateQuickAction(_ action: QuickAction) {
        quickActions.close()
        switch action.kind {
        case .tool(let tool):
            toolPath = [tool]
        case .settings(let tab):
            settings.open(tab)
        case .activityLog:
            openWindow(id: "activity-log")
        }
    }
}
