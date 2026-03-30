import SwiftUI
import PdfToolkit

struct RootView: View {
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
        }
    }
}
