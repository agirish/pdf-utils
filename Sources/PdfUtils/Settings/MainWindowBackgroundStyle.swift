import AppKit
import SwiftUI

/// High-level window background mode. `liquidGlass` uses hue + intensity from `UserDefaults` (SyncCloud-style).
enum MainWindowBackgroundStyle: String, CaseIterable, Identifiable {
    case liquidGlass
    case systemWindow
    case paperWhite
    case softNeutral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: return "Liquid glass"
        case .systemWindow: return "System window"
        case .paperWhite: return "Paper white"
        case .softNeutral: return "Soft neutral"
        }
    }

    var detail: String {
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
    var glassHue: LiquidGlassHue = .purple

    var body: some View {
        ZStack {
            switch style {
            case .liquidGlass:
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .liquidGlassAppBackground(intensity: glassIntensity, hue: glassHue)
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

struct DashboardBackground: View {
    @AppStorage(SettingsKeys.mainWindowBackground)
    private var mainWindowBackgroundRaw: String = MainWindowBackgroundStyle.liquidGlass.rawValue

    @AppStorage(LiquidGlass.intensityKey)
    private var glassIntensity: Double = 0.65

    @AppStorage(LiquidGlass.hueKey)
    private var glassHueRaw: String = LiquidGlassHue.purple.rawValue

    private var style: MainWindowBackgroundStyle {
        if mainWindowBackgroundRaw == "accentGradient" { return .liquidGlass }
        return MainWindowBackgroundStyle(rawValue: mainWindowBackgroundRaw) ?? .liquidGlass
    }

    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .purple
    }

    var body: some View {
        MainWindowBackgroundLayer(style: style, glassIntensity: glassIntensity, glassHue: glassHue)
            .ignoresSafeArea()
    }
}
