import SwiftUI
import PdfToolkit

struct RootView: View {
    @EnvironmentObject private var settings: SettingsPresenter

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

    var body: some View {
        ZStack {
            NavigationStack {
                DashboardView()
            }
            .frame(minWidth: 960, minHeight: 640)

            if settings.isPresented {
                settingsOverlay
            }
        }
        .animation(.easeOut(duration: 0.15), value: settings.isPresented)
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
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
    }
}
