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

    @AppStorage(LiquidGlass.levelKey)
    private var glassLevelRaw: String = GlassLevel.frosted.rawValue

    @AppStorage(LiquidGlass.hueKey)
    private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue

    private var glassLevel: GlassLevel {
        GlassLevel(rawValue: glassLevelRaw) ?? .frosted
    }

    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue
    }

    public var body: some View {
        MainWindowBackgroundLayer(glassLevel: glassLevel, glassHue: glassHue)
            .ignoresSafeArea(edges: [.horizontal, .bottom])
    }
}
