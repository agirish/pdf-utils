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
    var glassIntensity: Double = 0.65
    var glassHue: LiquidGlassHue = LiquidGlass.defaultHue
    var glassTint: Double = 0
    /// When `false`, liquid glass fills the view edge to edge (e.g. merge preview column). When `true`, the top safe area stays clear for window toolbars.
    var liquidGlassRespectsTopSafeArea: Bool = true

    var body: some View {
        ZStack {
            switch style {
            case .liquidGlass:
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .liquidGlassAppBackground(
                        intensity: glassIntensity,
                        hue: glassHue,
                        tint: glassTint,
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
    @AppStorage(SettingsKeys.mainWindowBackground)
    private var mainWindowBackgroundRaw: String = MainWindowBackgroundStyle.liquidGlass.rawValue

    @AppStorage(LiquidGlass.levelKey)
    private var glassLevelRaw: String = GlassLevel.frosted.rawValue

    @AppStorage(LiquidGlass.tintKey)
    private var glassTint: Double = 0

    @AppStorage(LiquidGlass.hueKey)
    private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue

    private var style: MainWindowBackgroundStyle {
        if mainWindowBackgroundRaw == "accentGradient" { return .liquidGlass }
        return MainWindowBackgroundStyle(rawValue: mainWindowBackgroundRaw) ?? .liquidGlass
    }

    private var glassIntensity: Double {
        (GlassLevel(rawValue: glassLevelRaw) ?? .frosted).backgroundIntensity
    }

    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue
    }

    public var body: some View {
        MainWindowBackgroundLayer(style: style, glassIntensity: glassIntensity, glassHue: glassHue, glassTint: glassTint)
            // Keep the top safe area clear so the unified title bar, toolbar, and menu-driven controls stay visible.
            .ignoresSafeArea(edges: [.horizontal, .bottom])
    }
}
