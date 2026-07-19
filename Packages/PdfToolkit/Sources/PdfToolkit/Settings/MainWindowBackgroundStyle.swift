import AppKit
import SwiftUI

/// High-level window background mode. `liquidGlass` uses hue + intensity from `UserDefaults` (SyncCloud-style).
public enum MainWindowBackgroundStyle: String, CaseIterable, Identifiable {
    case liquidGlass
    case systemWindow
    case paperWhite
    case softNeutral

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .liquidGlass: return "Liquid glass"
        case .systemWindow: return "System window"
        case .paperWhite: return "Paper white"
        case .softNeutral: return "Soft neutral"
        }
    }

    public var detail: String {
        switch self {
        case .liquidGlass:
            return "Tinted gradient and material; customize hue and strength in Settings."
        case .systemWindow:
            return "Standard macOS window background only."
        case .paperWhite:
            return "Flat white canvas."
        case .softNeutral:
            return "Flat system neutral (no gradient)."
        }
    }
}

/// Shared backdrop for dashboard, tools, and merge “match main”.
struct MainWindowBackgroundLayer: View {
    let style: MainWindowBackgroundStyle
    var glassLevel: GlassLevel = .frosted
    var glassHue: LiquidGlassHue = LiquidGlass.defaultHue
    /// When `false`, liquid glass fills the view edge to edge (e.g. merge preview column). When `true`, the top safe area stays clear for window toolbars.
    var liquidGlassRespectsTopSafeArea: Bool = true

    var body: some View {
        ZStack {
            switch style {
            case .liquidGlass:
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .liquidGlassAppBackground(
                        level: glassLevel,
                        hue: glassHue,
                        respectTopSafeArea: liquidGlassRespectsTopSafeArea
                    )
            case .systemWindow:
                Color(nsColor: .windowBackgroundColor)
            case .paperWhite:
                Color.white
            case .softNeutral:
                Color(nsColor: .underPageBackgroundColor)
            }
        }
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
        // Always liquid glass (SyncCloud parity). The old `mainWindowBackground` style switch is gone
        // from the render path: it had no Settings UI, yet a stored non-glass value (e.g. paper white)
        // silently painted a flat opaque fill over the whole window — which is exactly what hid the
        // glass and the behind-window translucency.
        MainWindowBackgroundLayer(style: .liquidGlass, glassLevel: glassLevel, glassHue: glassHue)
            .ignoresSafeArea(edges: [.horizontal, .bottom])
    }
}
