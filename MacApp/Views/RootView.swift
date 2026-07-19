import SwiftUI
import PdfToolkit

struct RootView: View {
    @AppStorage(LiquidGlass.appearanceModeKey)
    private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    var body: some View {
        NavigationStack {
            DashboardView()
        }
        .frame(minWidth: 960, minHeight: 640)
        .onAppear {
            if UserDefaults.standard.string(forKey: SettingsKeys.mainWindowBackground) == "accentGradient" {
                UserDefaults.standard.set(
                    MainWindowBackgroundStyle.liquidGlass.rawValue,
                    forKey: SettingsKeys.mainWindowBackground
                )
            }
            AppAppearance.applyPersisted()
        }
        // The Theme picker lives in the separate Settings window; observing the shared key here
        // re-applies the appearance to NSApp and every window (including that Settings window)
        // no matter which scene wrote the change.
        .onChange(of: appearanceModeRaw) { _, _ in
            AppAppearance.applyPersisted()
        }
    }
}
