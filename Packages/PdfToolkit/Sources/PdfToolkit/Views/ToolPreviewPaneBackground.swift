import AppKit
import SwiftUI

/// Preview column backdrop from Settings (`MergePreviewBackgroundStyle`); shared by all tools with a preview column.
struct ToolPreviewPaneBackground: View {
    @AppStorage(SettingsKeys.mergePreviewBackground)
    private var mergeRaw: String = MergePreviewBackgroundStyle.matchMain.rawValue

    @AppStorage(SettingsKeys.mainWindowBackground)
    private var mainRaw: String = MainWindowBackgroundStyle.liquidGlass.rawValue

    @AppStorage(LiquidGlass.levelKey)
    private var glassLevelRaw: String = GlassLevel.frosted.rawValue

    @AppStorage(LiquidGlass.hueKey)
    private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue

    private var mergeStyle: MergePreviewBackgroundStyle {
        MergePreviewBackgroundStyle(rawValue: mergeRaw) ?? .matchMain
    }

    // The main-window background is always liquid glass now (see DashboardBackground), so "Match main
    // background" mirrors the glass rather than a since-removed window-background style.
    private var mainStyle: MainWindowBackgroundStyle { .liquidGlass }

    private var glassLevel: GlassLevel {
        GlassLevel(rawValue: glassLevelRaw) ?? .frosted
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
                    style: mainStyle,
                    glassLevel: glassLevel,
                    glassHue: glassHue,
                    liquidGlassRespectsTopSafeArea: false
                )
            }
        }
    }
}
