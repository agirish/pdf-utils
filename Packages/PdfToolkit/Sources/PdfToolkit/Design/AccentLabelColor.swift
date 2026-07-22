import AppKit
import SwiftUI

// MARK: - Legible labels on accent fills (aligned with SyncCloud `Modules/Design/AccentLabelColor`)

/// Picks a legible glyph/text color for content drawn on top of an accent fill.
public enum AccentLabel {
    /// WCAG relative luminance (Rec. 709 linearization) of an sRGB color.
    static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two relative luminances (order-independent), 1...21.
    static func contrastRatio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// True when white text on this fill would fall below ~3:1 (crosses near L = 0.30) — i.e. the
    /// fill is light enough that a near-black glyph reads better than white.
    static func prefersDarkText(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        relativeLuminance(red: red, green: green, blue: blue) > 0.30
    }

    // MARK: Accent-as-text (Finding 11)

    /// Representative content-surface luminances the accent-as-text derivation targets. The accent
    /// hues are tuned as *fills*; painted as small text they must clear WCAG AA against the surface
    /// they sit on. In **light** mode that surface is a near-white content card; in **dark** mode we
    /// deliberately reference a *dark card* (the lightest surface accent text realistically sits on —
    /// a `formCard` over the deep base), not the raw near-black base, so the derived color stays
    /// legible on the card *and*, being the harder target, on everything darker behind it.
    static let lightSurfaceLuminance = relativeLuminance(red: 0.95, green: 0.95, blue: 0.96)
    static let darkSurfaceLuminance = relativeLuminance(red: 0.17, green: 0.18, blue: 0.20)

    /// Least-modified variant of `accent` (as sRGB components) that clears `target`:1 against
    /// `surface`. Light appearances darken the hue toward black; dark appearances lighten it toward
    /// white. Both moves are monotonic in the blend factor, so a binary search finds the smallest
    /// nudge that meets the bar — keeping the hue as vivid as legibility allows. Returns the input
    /// unchanged when it already clears the bar.
    static func accentText(
        red: CGFloat, green: CGFloat, blue: CGFloat,
        surface: CGFloat, darken: Bool, target: CGFloat
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        func blend(_ f: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            darken
                ? (red * (1 - f), green * (1 - f), blue * (1 - f))          // toward black
                : (red + (1 - red) * f, green + (1 - green) * f, blue + (1 - blue) * f) // toward white
        }
        func ratio(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
            contrastRatio(relativeLuminance(red: rgb.0, green: rgb.1, blue: rgb.2), surface)
        }
        if ratio((red, green, blue)) >= target { return (red, green, blue) }
        // f = 0 is the original color; f = 1 is pure black/white (maximum contrast). Contrast rises
        // monotonically with f, so binary-search the smallest f that clears the target.
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if ratio(blend(mid)) >= target { hi = mid } else { lo = mid }
        }
        return blend(hi)
    }
}

public extension Color {
    /// Glyph/label color for content drawn on a **static** fill (an accent swatch, a tinted chip).
    /// Resolves the fill's own luminance: near-black on light fills, white on dark ones. White on
    /// Amber is ~2.1:1 and on Cyan ~2.5:1 — both under the 3:1 large-text floor — so a fixed white
    /// checkmark disappears on the lighter hues; this fixes that. Do not pass a dynamic color: it
    /// would collapse to whatever the current appearance resolves it to.
    static func onFillLabel(_ fill: Color) -> Color {
        let resolved = NSColor(fill).usingColorSpace(.sRGB)
        guard let resolved else { return .white }
        let prefersDark = AccentLabel.prefersDarkText(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent
        )
        return prefersDark ? Color.black.opacity(0.85) : .white
    }

    /// Appearance-adjusted variant of an accent hue for use as **small text / foreground** — a
    /// caption, a label, or a text button — on a typical content surface. The accent hues are tuned
    /// as *fills* and tint washes (where a fixed white/near-black glyph rides on top, see
    /// `onFillLabel`); painted directly as text they fail WCAG AA (amber ≈2.2:1, cyan ≈2.1:1 on a
    /// light card; the darker hues on the dark base). This darkens a too-light hue in light mode and
    /// lightens a too-dark hue in dark mode until it clears ~4.5:1 (≈7:1 at increased contrast)
    /// against the representative surface, holding the hue as vivid as legibility allows. A hue that
    /// already clears the bar is returned unchanged.
    ///
    /// Pure function of `(accent, scheme, contrast)` — unit-tested against the WCAG contrast math.
    /// Do **not** pass a dynamic color: like `onFillLabel` it would collapse to whatever the current
    /// appearance resolves it to. Use it only for accent-as-*text*; leave accent fills, tint washes,
    /// and the primary `.tint(accent)` CTAs alone.
    static func accentText(
        _ accent: Color,
        on scheme: ColorScheme,
        contrast: ColorSchemeContrast = .standard
    ) -> Color {
        guard let resolved = NSColor(accent).usingColorSpace(.sRGB) else { return accent }
        let dark = scheme == .dark
        let target: CGFloat = contrast == .increased ? 7.0 : 4.5
        let surface = dark ? AccentLabel.darkSurfaceLuminance : AccentLabel.lightSurfaceLuminance
        let out = AccentLabel.accentText(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            surface: surface,
            darken: !dark,
            target: target
        )
        return Color(.sRGB, red: Double(out.red), green: Double(out.green), blue: Double(out.blue), opacity: 1)
    }
}
