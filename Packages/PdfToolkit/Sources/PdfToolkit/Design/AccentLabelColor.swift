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

    /// True when white text on this fill would fall below ~3:1 (crosses near L = 0.30) — i.e. the
    /// fill is light enough that a near-black glyph reads better than white.
    static func prefersDarkText(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        relativeLuminance(red: red, green: green, blue: blue) > 0.30
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
}
