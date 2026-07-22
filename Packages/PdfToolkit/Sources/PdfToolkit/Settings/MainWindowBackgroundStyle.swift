import AppKit
import SwiftUI

/// Shared backdrop for the dashboard, tools, and the preview column's "match main" option. The window
/// background is always liquid glass (SyncCloud parity); the hue and intensity come from `UserDefaults`.
/// An earlier `MainWindowBackgroundStyle` switch (system / paper white / soft neutral) was removed —
/// it had no Settings UI, yet a stored non-glass value painted a flat opaque fill that hid the glass.
struct MainWindowBackgroundLayer: View {
    var glassLevel: GlassLevel = .frosted
    var glassHue: LiquidGlassHue = LiquidGlass.defaultHue
    /// When `false`, liquid glass fills the view edge to edge (e.g. merge preview column). When `true`, the top safe area stays clear for window toolbars.
    var liquidGlassRespectsTopSafeArea: Bool = true

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassAppBackground(
                level: glassLevel,
                hue: glassHue,
                respectTopSafeArea: liquidGlassRespectsTopSafeArea
            )
    }
}

public struct DashboardBackground: View {
    public init() {}

    private let glass = GlassAppearance()

    public var body: some View {
        MainWindowBackgroundLayer(glassLevel: glass.level, glassHue: glass.hue)
            .ignoresSafeArea(edges: [.horizontal, .bottom])
    }
}
