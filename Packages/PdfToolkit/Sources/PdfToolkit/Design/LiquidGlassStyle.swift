import SwiftUI

// MARK: - Liquid Glass (aligned with SyncCloud `Modules/Design`)

/// Hue options for the liquid glass background gradient.
public enum LiquidGlassHue: String, CaseIterable, Identifiable, Sendable {
    /// No accent wash — defer to the macOS system accent for controls, and paint no gradient.
    case none
    case blue
    case cyan
    case teal
    case green
    case amber
    case coral
    case rose
    case purple
    case indigo
    case slate
    /// A true neutral gray — the monochrome accent. Paired with the `single` tool-color style it makes
    /// every tool (and the window) read as graphite, with no color.
    case graphite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .teal: return "Teal"
        case .green: return "Green"
        case .amber: return "Amber"
        case .coral: return "Coral"
        case .rose: return "Rose"
        case .purple: return "Purple"
        case .indigo: return "Indigo"
        case .slate: return "Slate"
        case .graphite: return "Graphite"
        }
    }

    public var accentColor: Color {
        switch self {
        case .none: return Color.accentColor
        case .blue: return Color(red: 0.2, green: 0.5, blue: 1.0)
        case .cyan: return Color(red: 0.25, green: 0.75, blue: 1.0)
        case .teal: return Color(red: 0.2, green: 0.65, blue: 0.65)
        case .green: return Color(red: 0.2, green: 0.7, blue: 0.5)
        case .amber: return Color(red: 0.95, green: 0.6, blue: 0.2)
        case .coral: return Color(red: 1.0, green: 0.45, blue: 0.4)
        case .rose: return Color(red: 0.95, green: 0.4, blue: 0.55)
        case .purple: return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .indigo: return Color(red: 0.4, green: 0.35, blue: 0.9)
        case .slate: return Color(red: 0.4, green: 0.45, blue: 0.55)
        case .graphite: return Color(red: 0.53, green: 0.54, blue: 0.56)
        }
    }

    public var gradientColors: [Color] {
        switch self {
        case .none:
            return [.clear, .clear, .clear]
        case .blue:
            return [
                Color(red: 0.25, green: 0.75, blue: 1.0),
                Color(red: 0.15, green: 0.45, blue: 1.0),
                Color(red: 0.05, green: 0.25, blue: 0.85),
            ]
        case .cyan:
            return [
                Color(red: 0.35, green: 0.85, blue: 1.0),
                Color(red: 0.2, green: 0.7, blue: 0.95),
                Color(red: 0.1, green: 0.5, blue: 0.85),
            ]
        case .teal:
            return [
                Color(red: 0.25, green: 0.8, blue: 0.8),
                Color(red: 0.15, green: 0.6, blue: 0.65),
                Color(red: 0.08, green: 0.4, blue: 0.5),
            ]
        case .green:
            return [
                Color(red: 0.3, green: 0.85, blue: 0.6),
                Color(red: 0.2, green: 0.65, blue: 0.5),
                Color(red: 0.1, green: 0.45, blue: 0.4),
            ]
        case .amber:
            return [
                Color(red: 1.0, green: 0.75, blue: 0.35),
                Color(red: 0.95, green: 0.6, blue: 0.2),
                Color(red: 0.8, green: 0.45, blue: 0.1),
            ]
        case .coral:
            return [
                Color(red: 1.0, green: 0.55, blue: 0.5),
                Color(red: 0.95, green: 0.4, blue: 0.4),
                Color(red: 0.8, green: 0.25, blue: 0.35),
            ]
        case .rose:
            return [
                Color(red: 1.0, green: 0.5, blue: 0.65),
                Color(red: 0.9, green: 0.35, blue: 0.55),
                Color(red: 0.7, green: 0.2, blue: 0.5),
            ]
        case .purple:
            return [
                Color(red: 0.6, green: 0.45, blue: 1.0),
                Color(red: 0.45, green: 0.35, blue: 0.9),
                Color(red: 0.3, green: 0.2, blue: 0.75),
            ]
        case .indigo:
            return [
                Color(red: 0.45, green: 0.4, blue: 0.95),
                Color(red: 0.35, green: 0.3, blue: 0.85),
                Color(red: 0.2, green: 0.2, blue: 0.7),
            ]
        case .slate:
            return [
                Color(red: 0.5, green: 0.55, blue: 0.65),
                Color(red: 0.4, green: 0.45, blue: 0.55),
                Color(red: 0.25, green: 0.3, blue: 0.4),
            ]
        case .graphite:
            // A neutral gray triad — no hue, so `single + graphite` reads as a true monochrome window.
            return [
                Color(red: 0.60, green: 0.61, blue: 0.63),
                Color(red: 0.45, green: 0.46, blue: 0.48),
                Color(red: 0.29, green: 0.30, blue: 0.32),
            ]
        }
    }
}

/// The material of the app's glass surfaces (aligned with SyncCloud `Design/GlassLevel`). Replaces
/// the old free `intensity` Double — that API only ever had two visible states. Stored via
/// `LiquidGlass.levelKey`.
public enum GlassLevel: String, CaseIterable, Identifiable, Sendable {
    /// Glass with no frost: the background reads straight through.
    case clear
    /// Standard Liquid Glass — translucent and blurred, legible on top.
    case frosted
    /// Opaque panels. The only case with no translucency at all.
    case solid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clear: return "Clear"
        case .frosted: return "Frosted"
        case .solid: return "Solid"
        }
    }

    /// One-line explanation shown under the Settings picker.
    public var detail: String {
        switch self {
        case .clear:
            return "Glass with no frost — the window's background reads through every surface."
        case .frosted:
            return "Standard Liquid Glass: translucent and blurred, with content on top staying legible."
        case .solid:
            return "Opaque panels for maximum readability, with no translucency."
        }
    }

    /// Overlay chrome (Settings, Help) floors `.clear` to `.frosted`: those panels sit over live app
    /// content, and clear glass over content is two layers competing.
    public var flooredForChrome: GlassLevel {
        self == .clear ? .frosted : self
    }

    /// Backdrop dimming behind an overlay. `.clear` deepens it so the app recedes further.
    public var overlayScrimOpacity: Double {
        self == .clear ? 0.55 : 0.35
    }

    /// Strength of the app background gradient/material, 0...1. `.frosted` keeps 0.65 — the old
    /// intensity slider's default — so migrating installs see an unchanged background.
    public var backgroundIntensity: Double {
        switch self {
        case .clear: return 0.0
        case .frosted: return 0.65
        case .solid: return 1.0
        }
    }
}

/// How content surfaces are *shaped* against the glass background — orthogonal to `GlassLevel`.
/// Stored via `LiquidGlass.surfaceStyleKey`.
public enum SurfaceStyle: String, CaseIterable, Identifiable {
    /// Surfaces read as one continuous plane on the background.
    case unified
    /// Each surface floats as a separate elevated card.
    case cards

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unified: return "Unified"
        case .cards: return "Cards"
        }
    }

    public var detail: String {
        switch self {
        case .unified:
            return "Tools and the dashboard read as one continuous surface on the background."
        case .cards:
            return "Each tool tile and panel floats as a separate card on the background."
        }
    }
}

public enum LiquidGlass {
    public static let cardCornerRadius: CGFloat = 14
    static let smallCornerRadius: CGFloat = 10

    /// pdf-utils–scoped keys (do not collide with SyncCloud defaults on the same Mac).
    /// Retired: read only by `migrateLegacyAppearance`, which maps it onto `levelKey`.
    static let intensityKey = "pdfutils.liquidGlassIntensity"
    public static let hueKey = "pdfutils.liquidGlassHue"
    /// Public: the Theme control is bound from the app target's `RootView` via `@AppStorage`.
    public static let appearanceModeKey = "pdfutils.appearanceMode"
    /// Glass material (`GlassLevel` raw value). Replaces the retired intensity Double.
    public static let levelKey = "pdfutils.glassLevel"
    /// Content surface shape (`SurfaceStyle` raw value).
    public static let surfaceStyleKey = "pdfutils.contentSurfaceStyle"
    /// Accent tint strength applied to surfaces (Double, 0...1).
    public static let tintKey = "pdfutils.contentSurfaceTint"
    /// How per-tool accent colors are chosen (`AccentStyle` raw value): multicolor / single / monochrome.
    public static let accentStyleKey = "pdfutils.toolAccentStyle"

    /// Default hue when nothing is stored (matches SyncCloud's default accent).
    public static let defaultHue = LiquidGlassHue.blue
    /// Default glass material when nothing is stored — `.frosted`, the old intensity slider's 0.65
    /// look, so a migrated install renders unchanged. The single source for every `@AppStorage`
    /// initializer and resolve fallback, so the seeded value and the fallback can never drift apart.
    public static let defaultLevel = GlassLevel.frosted
    /// Default content-surface accent tint when nothing is stored (0 = no wash).
    public static let defaultTint: Double = 0

    /// Moves a pre-`GlassLevel` install onto the new model. Idempotent: once `levelKey` is set this
    /// is a no-op, so it can run on every launch. Any stored intensity maps to `.frosted` (the old
    /// slider's 0.65 default, and what installs actually rendered), and the retired key is cleared.
    public static func migrateLegacyAppearance(_ defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: levelKey) == nil else { return }
        defaults.set(defaultLevel.rawValue, forKey: levelKey)
        defaults.removeObject(forKey: intensityKey)
    }
}

public extension View {
    /// App-level liquid glass backdrop, matching SyncCloud `Design/liquidGlassAppBackground`. At
    /// `.clear` a behind-window vibrancy layer lets the desktop read through the (non-opaque) window;
    /// at `.frosted`/`.solid` the window stays opaque and this paints the accent gradient over a
    /// `.thinMaterial` base. `BehindWindowGlass` toggles the window's opacity itself — nothing else
    /// touches it. The accent *tint* washes content surfaces (see `contentSurface`), not the window
    /// background, exactly as in SyncCloud.
    /// Dark mode routes through `LiquidGlassBackground` so it can read `@Environment(\.colorScheme)`:
    /// the shared light-tuned constants collapse to a flat gray slab on a dark appearance, so dark
    /// gets a deep graded base under the material and a soft accent glow over it. Light is unchanged.
    func liquidGlassAppBackground(
        level: GlassLevel,
        hue: LiquidGlassHue = LiquidGlass.defaultHue,
        respectTopSafeArea: Bool = true
    ) -> some View {
        modifier(LiquidGlassBackground(level: level, hue: hue, respectTopSafeArea: respectTopSafeArea))
    }

    /// The material fill for one content surface — the single place the level → appearance decision
    /// is made (SyncCloud `Design/glassSurface`).
    @ViewBuilder
    func glassSurface(_ level: GlassLevel, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch level {
        case .solid:
            self.background(Color(nsColor: .controlBackgroundColor), in: shape)
        case .clear, .frosted:
            if #available(macOS 26.0, *) {
                self.glassEffect(level == .frosted ? .regular : .clear, in: .rect(cornerRadius: cornerRadius))
            } else {
                self.background(level == .frosted ? Material.thinMaterial : Material.ultraThinMaterial, in: shape)
            }
        }
    }

    /// Frosted glass card style for floating overlay chrome (the Settings overlay). Applies
    /// `flooredForChrome` so a `.clear` app never produces an unreadable panel over live content.
    @ViewBuilder
    func glassCardStyle(level: GlassLevel) -> some View {
        let resolved = level.flooredForChrome
        let shape = RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
        self
            .clipShape(shape)
            .glassSurface(resolved, cornerRadius: LiquidGlass.cardCornerRadius)
    }

    /// Lighter glass style for bars and inline panels; takes the level verbatim (no floor). Dark adds
    /// a top-lit specular hairline (via `GlassBarStyle`) so the bar reads as distinct glass chrome
    /// against the dark background; light is unchanged.
    func glassBarStyle(level: GlassLevel) -> some View {
        modifier(GlassBarStyle(level: level))
    }

    /// Border + drop shadow for a floating overlay card (the Settings overlay, the ⌘K palette) sitting
    /// over a dimmed backdrop. Dark gets a top-lit specular hairline and a deeper, larger shadow so the
    /// card lifts off the scrim — the light-tuned `black 0.3` shadow is nearly invisible on a dark
    /// backdrop. Light keeps the original `.quaternary` hairline + shadow, unchanged.
    func overlayCardChrome(cornerRadius: CGFloat = LiquidGlass.cardCornerRadius) -> some View {
        modifier(OverlayCardChrome(cornerRadius: cornerRadius))
    }

    /// The full glass treatment shared by the in-window overlay cards — Settings, the ⌘K palette, and
    /// Help — bundling the accent wash, the glass card material, and the overlay chrome. Reads the live
    /// appearance itself (via `GlassAppearance`), so all three cards track the Glass level / hue / tint
    /// together and no longer each re-spell `contentSurface(…).glassCardStyle(…).overlayCardChrome()`.
    func overlayGlassCard() -> some View {
        modifier(OverlayGlassCardStyle())
    }

    /// The accent-color wash driven by the Tint slider (`tint`, 0...1). Apply ONCE per region.
    /// `.none` gets no wash at any tint (its accentColor is the system accent, which would repaint).
    @ViewBuilder
    func contentSurface(hue: LiquidGlassHue = LiquidGlass.defaultHue, tint: Double = 0) -> some View {
        let wash = hue == .none ? Color.clear : hue.accentColor.opacity(max(0.0, min(1.0, tint)) * 0.32)
        self.background(wash)
    }
}

/// Backs `overlayGlassCard()`. Reads the live glass appearance so the overlay cards wash + frost +
/// chrome themselves without their host re-declaring the appearance triad.
private struct OverlayGlassCardStyle: ViewModifier {
    private let glass = GlassAppearance()

    func body(content: Content) -> some View {
        content
            .contentSurface(hue: glass.hue, tint: glass.tint)
            .glassCardStyle(level: glass.level)
            .overlayCardChrome()
    }
}

// MARK: - Appearance-aware background (the dark-mode re-tune)

/// The app background, split into a `ViewModifier` so it can read `@Environment(\.colorScheme)` —
/// the original free function could not, which is why every constant was one light-tuned value.
///
/// **Light** reproduces the original background exactly: the accent diagonal gradient over a
/// `.thinMaterial` base at `0.45 + 0.20·t`. **Dark** adds two things the flat gray slab was missing —
/// a deep, faintly-cool near-black gradient *under* the material so the ground grades with depth, and
/// a soft pool of the accent hue at the top edge *over* the material so the chosen accent actually
/// reads. The accent diagonal also lifts its opacity in dark to survive the darker base. `.clear`
/// (see-through) still skips the material entirely; only its diagonal wash strengthens.
private struct LiquidGlassBackground: ViewModifier {
    let level: GlassLevel
    let hue: LiquidGlassHue
    let respectTopSafeArea: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let t = level.backgroundIntensity
        // Only `.clear` goes see-through — the material base hides the desktop otherwise (SyncCloud parity).
        let seeThrough = level == .clear
        let safeEdges: Edge.Set = respectTopSafeArea ? [.horizontal, .bottom] : .all

        let colors = hue.gradientColors
        let opacities: [Double] = dark
            ? [0.19 + 0.28 * t, 0.15 + 0.23 * t, 0.10 + 0.16 * t]
            : [0.06 + 0.16 * t, 0.05 + 0.14 * t, 0.04 + 0.10 * t]
        let gradientColors = zip(colors, opacities).map { $0.0.opacity($0.1) }

        content.background {
            ZStack {
                // Behind-window vibrancy: shows the desktop at `.clear`, inert otherwise (it also hands
                // the window its opacity back). Always ignores every safe area so the title-bar band is
                // glass too at `.clear`, not a clear hole.
                BehindWindowGlass(isEnabled: seeThrough)
                    .ignoresSafeArea()

                // Dark-only deep base: a near-black, faintly-cool gradient beneath the material so the
                // ground reads as graded depth rather than one muddy plane.
                if !seeThrough && dark {
                    LinearGradient(
                        colors: [Color(red: 0.065, green: 0.082, blue: 0.115),
                                 Color(red: 0.02, green: 0.027, blue: 0.043)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: safeEdges)
                }

                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea(edges: safeEdges)

                if !seeThrough {
                    // Base material so content stays readable. Dark thins it a touch so the deep base
                    // reads through instead of flattening back to system gray.
                    Color.clear
                        .background(.thinMaterial.opacity((dark ? 0.27 : 0.45) + 0.20 * t))
                        .ignoresSafeArea(edges: safeEdges)
                }

                // Dark-only accent glow: a soft pool of the hue at the top, over the material so the
                // accent reads. `.none` opts out (it defers to the system accent).
                if !seeThrough && dark && hue != .none {
                    RadialGradient(
                        colors: [hue.accentColor.opacity(0.26 + 0.10 * t), .clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: 700
                    )
                    .blendMode(.plusLighter)
                    .ignoresSafeArea(edges: safeEdges)
                }
            }
        }
    }
}

// MARK: - Appearance-aware chrome (dark-mode re-tune for overlay cards & bars)

/// Border + shadow for a floating overlay card (Settings, ⌘K palette). See `View.overlayCardChrome`.
private struct OverlayCardChrome: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let border: AnyShapeStyle = dark
            ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06)],
                                           startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(.quaternary)
        content
            .overlay(shape.strokeBorder(border, lineWidth: dark ? 1 : 0.5))
            .shadow(color: .black.opacity(dark ? 0.55 : 0.3), radius: dark ? 34 : 30, y: dark ? 12 : 8)
    }
}

/// Bar/panel glass with a dark-only top-lit specular hairline. See `View.glassBarStyle`.
private struct GlassBarStyle: ViewModifier {
    let level: GlassLevel
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LiquidGlass.smallCornerRadius, style: .continuous)
        content
            .glassSurface(level, cornerRadius: LiquidGlass.smallCornerRadius)
            .overlay {
                if scheme == .dark {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                }
            }
    }
}
