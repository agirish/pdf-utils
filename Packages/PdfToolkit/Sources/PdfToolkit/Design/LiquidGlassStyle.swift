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
        }
    }
}

/// The material of the app's glass surfaces (aligned with SyncCloud `Design/GlassLevel`). Replaces
/// the old free `intensity` Double — that API only ever had two visible states. Stored via
/// `LiquidGlass.levelKey`.
public enum GlassLevel: String, CaseIterable, Identifiable {
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

    static let cardShadow = (color: Color.black.opacity(0.06), radius: CGFloat(12), x: CGFloat(0), y: CGFloat(4))

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

    /// Default hue when nothing is stored (matches SyncCloud's default accent).
    public static let defaultHue = LiquidGlassHue.blue

    /// Moves a pre-`GlassLevel` install onto the new model. Idempotent: once `levelKey` is set this
    /// is a no-op, so it can run on every launch. Any stored intensity maps to `.frosted` (the old
    /// slider's 0.65 default, and what installs actually rendered), and the retired key is cleared.
    public static func migrateLegacyAppearance(_ defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: levelKey) == nil else { return }
        defaults.set(GlassLevel.frosted.rawValue, forKey: levelKey)
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
    @ViewBuilder
    func liquidGlassAppBackground(
        level: GlassLevel,
        hue: LiquidGlassHue = LiquidGlass.defaultHue,
        respectTopSafeArea: Bool = true
    ) -> some View {
        let t = level.backgroundIntensity
        let colors = hue.gradientColors
        let opacities: [Double] = [0.06 + 0.16 * t, 0.05 + 0.14 * t, 0.04 + 0.10 * t]
        let gradientColors = zip(colors, opacities).map { $0.0.opacity($0.1) }
        // Only `.clear` goes see-through — the thinMaterial base is opaque enough to hide the
        // desktop, so the two are mutually exclusive (SyncCloud parity).
        let seeThrough = level == .clear
        let safeEdges: Edge.Set = respectTopSafeArea ? [.horizontal, .bottom] : .all

        background {
            ZStack {
                // Behind-window vibrancy: shows the desktop through the window at `.clear`, inert
                // otherwise (it also hands the window its opacity back). Always ignores every safe
                // area so the title-bar band is glass too at `.clear`, not a clear hole.
                BehindWindowGlass(isEnabled: seeThrough)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea(edges: safeEdges)

                if !seeThrough {
                    // Base material so content stays readable in light/dark — SyncCloud's non-clear base.
                    Color.clear
                        .background(.thinMaterial.opacity(0.45 + 0.20 * t))
                        .ignoresSafeArea(edges: safeEdges)
                }
            }
        }
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

    /// Lighter glass style for bars and inline panels; takes the level verbatim (no floor).
    @ViewBuilder
    func glassBarStyle(level: GlassLevel) -> some View {
        self.glassSurface(level, cornerRadius: LiquidGlass.smallCornerRadius)
    }

    /// The accent-color wash driven by the Tint slider (`tint`, 0...1). Apply ONCE per region.
    /// `.none` gets no wash at any tint (its accentColor is the system accent, which would repaint).
    @ViewBuilder
    func contentSurface(hue: LiquidGlassHue = LiquidGlass.defaultHue, tint: Double = 0) -> some View {
        let wash = hue == .none ? Color.clear : hue.accentColor.opacity(max(0.0, min(1.0, tint)) * 0.32)
        self.background(wash)
    }
}
