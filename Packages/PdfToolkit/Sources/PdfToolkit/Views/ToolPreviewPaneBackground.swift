import AppKit
import SwiftUI

/// Preview column backdrop from Settings (`MergePreviewBackgroundStyle`); shared by all tools with a preview column.
struct ToolPreviewPaneBackground: View {
    @AppStorage(SettingsKeys.mergePreviewBackground)
    private var mergeRaw: String = MergePreviewBackgroundStyle.matchMain.rawValue

    @AppStorage(LiquidGlass.levelKey)
    private var glassLevelRaw: String = LiquidGlass.defaultLevel.rawValue

    @AppStorage(LiquidGlass.hueKey)
    private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue

    private var mergeStyle: MergePreviewBackgroundStyle {
        MergePreviewBackgroundStyle(rawValue: mergeRaw) ?? .matchMain
    }

    private var glassLevel: GlassLevel {
        GlassLevel(rawValue: glassLevelRaw) ?? LiquidGlass.defaultLevel
    }

    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue
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
                    glassLevel: glassLevel,
                    glassHue: glassHue,
                    liquidGlassRespectsTopSafeArea: false
                )
            }
        }
    }
}
