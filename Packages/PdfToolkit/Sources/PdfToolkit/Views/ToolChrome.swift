import Foundation
import SwiftUI

extension String {
    /// Basename for SwiftUI `fileExporter` `defaultFilename` (strips the last path extension).
    var exportFilenameStem: String {
        (self as NSString).deletingPathExtension
    }
}

struct ToolFormContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

extension View {
    /// The surface behind a tool's control card. Uses the same glass material as the Settings card so
    /// tool panes read as liquid glass — tracking the Glass effect level and accent tint — rather than
    /// the near-opaque panel they used to draw, which hid the window's glass background everywhere but
    /// Settings.
    func formCard() -> some View {
        modifier(FormCardStyle())
    }

    /// Translucent bar behind a tool's primary action row. Mirrors `ToolScreenHeader`'s material top
    /// bar so the action reads as glass chrome — letting the window's liquid-glass background (its
    /// accent hue and tint) read through — instead of the opaque panel that used to hide it. Callers
    /// keep their own `Divider` above the bar.
    func toolActionBar() -> some View {
        self.background(.ultraThinMaterial)
    }
}

/// Reads the live appearance settings so every `formCard()` tracks the Glass effect level and accent
/// tint exactly the way the Settings overlay and the window background do — the single reason tool
/// panes now show liquid glass. Mirrors `RootView`'s Settings-card styling (`contentSurface` wash +
/// `glassSurface`) at the tools' 16-pt card radius, with a hairline border to define the edge.
private struct FormCardStyle: ViewModifier {
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var glassTint: Double = 0

    private var level: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var hue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .contentSurface(hue: hue, tint: glassTint)
            .clipShape(shape)
            .glassSurface(level, cornerRadius: 16)
            .overlay { shape.strokeBorder(.quaternary.opacity(0.6), lineWidth: 1) }
    }
}

struct RunActionButton: View {
    let title: String
    var busy: Bool = false
    /// When false, the button is disabled (e.g. no inputs yet).
    var canRun: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || !canRun)
    }
}
