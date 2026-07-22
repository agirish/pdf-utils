import AppKit
import SwiftUI

/// Preview column backdrop from Settings (`MergePreviewBackgroundStyle`); shared by all tools with a preview column.
struct ToolPreviewPaneBackground: View {
    @AppStorage(SettingsKeys.mergePreviewBackground)
    private var mergeRaw: String = MergePreviewBackgroundStyle.matchMain.rawValue

    private let glass = GlassAppearance()

    private var mergeStyle: MergePreviewBackgroundStyle {
        MergePreviewBackgroundStyle(rawValue: mergeRaw) ?? .matchMain
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
                    glassLevel: glass.level,
                    glassHue: glass.hue,
                    liquidGlassRespectsTopSafeArea: false
                )
            }
        }
    }
}
