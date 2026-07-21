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

/// The two sidebar widths a tool's control column can take. `standard` fits the thumbnail/list tools;
/// `compact` is for the editor tools (Redact, Fill & Sign) whose right pane wants more room. Named so
/// widths stop drifting to 440/480/520/540/560 one tool at a time.
enum ToolSidebarWidth {
    case standard
    case compact

    var minWidth: CGFloat { self == .standard ? 280 : 300 }
    var idealWidth: CGFloat { self == .standard ? 340 : 360 }
    var maxWidth: CGFloat { self == .standard ? 520 : 440 }
}

extension View {
    /// Frames a tool's sidebar column at one of the two shared widths.
    func toolSidebarWidth(_ width: ToolSidebarWidth = .standard) -> some View {
        frame(minWidth: width.minWidth, idealWidth: width.idealWidth, maxWidth: width.maxWidth)
    }

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

    /// The app's standard error alert: the error string under the app name with a single OK button,
    /// cleared on dismiss. Every tool view carried a byte-identical hand-rolled copy of this block;
    /// they now share one call. A non-nil `message` presents the alert.
    func toolErrorAlert(_ message: Binding<String?>) -> some View {
        alert(AppBrand.displayName, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
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
    @Environment(\.colorScheme) private var scheme

    private var level: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var hue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue }

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        // Dark gets a top-lit specular hairline and a drop shadow so the card lifts off the ground;
        // light keeps the original quaternary hairline with no shadow (unchanged).
        let border: AnyShapeStyle = dark
            ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.07)],
                                           startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(.quaternary.opacity(0.6))
        content
            .contentSurface(hue: hue, tint: glassTint)
            .clipShape(shape)
            .glassSurface(level, cornerRadius: 16)
            .overlay { shape.strokeBorder(border, lineWidth: 1) }
            .shadow(color: .black.opacity(dark ? 0.48 : 0), radius: dark ? 16 : 0, y: dark ? 8 : 0)
    }
}

/// The active tool's accent, injected by ``ToolDetailView`` so shared chrome (the primary action
/// button) can color itself per tool without every call site threading the color through. Defaults
/// to the system accent when there's no tool context (e.g. previews).
private struct ToolAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var toolAccent: Color {
        get { self[ToolAccentKey.self] }
        set { self[ToolAccentKey.self] = newValue }
    }
}

/// A numbered index badge for a list row — Merge's file order and Reorder's page order. One shared
/// size (30×30, radius 8) so the two lists' badges match instead of drifting to 40 vs 30.
struct RowIndexBadge: View {
    let number: Int
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.14))
                .frame(width: 30, height: 30)
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(accent)
        }
        .accessibilityHidden(true)
    }
}

struct RunActionButton: View {
    let title: String
    var busy: Bool = false
    /// When false, the button is disabled (e.g. no inputs yet).
    var canRun: Bool = true
    let action: () -> Void

    // The primary CTA wears the tool's own accent (orange for Compress, green for Protect, …) so each
    // screen reads as that tool. Read from the environment rather than a parameter so every tool
    // view inherits it for free; falls back to the system accent outside a tool context.
    @Environment(\.toolAccent) private var accent

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
        .tint(accent)
        .disabled(busy || !canRun)
    }
}
