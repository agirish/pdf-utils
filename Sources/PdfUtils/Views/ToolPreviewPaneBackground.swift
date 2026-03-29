import AppKit
import SwiftUI

/// Preview column backdrop from Settings (`MergePreviewBackgroundStyle`); shared by Merge, Compress, and Rotate.
struct ToolPreviewPaneBackground: View {
    @AppStorage(SettingsKeys.mergePreviewBackground)
    private var mergeRaw: String = MergePreviewBackgroundStyle.white.rawValue

    @AppStorage(SettingsKeys.mainWindowBackground)
    private var mainRaw: String = MainWindowBackgroundStyle.liquidGlass.rawValue

    @AppStorage(LiquidGlass.intensityKey)
    private var glassIntensity: Double = 0.65

    @AppStorage(LiquidGlass.hueKey)
    private var glassHueRaw: String = LiquidGlassHue.purple.rawValue

    private var mergeStyle: MergePreviewBackgroundStyle {
        MergePreviewBackgroundStyle(rawValue: mergeRaw) ?? .white
    }

    private var mainStyle: MainWindowBackgroundStyle {
        if mainRaw == "accentGradient" { return .liquidGlass }
        return MainWindowBackgroundStyle(rawValue: mainRaw) ?? .liquidGlass
    }

    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .purple
    }

    var body: some View {
        Group {
            switch mergeStyle {
            case .white:
                Color.white
            case .systemWindow:
                Color(nsColor: .windowBackgroundColor)
            case .matchMain:
                MainWindowBackgroundLayer(
                    style: mainStyle,
                    glassIntensity: glassIntensity,
                    glassHue: glassHue,
                    liquidGlassRespectsTopSafeArea: false
                )
            }
        }
    }
}
