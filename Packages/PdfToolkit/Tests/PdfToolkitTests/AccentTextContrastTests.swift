import AppKit
import Testing
import SwiftUI
@testable import PdfToolkit

/// Finding 11 — the accent hues are tuned as *fills*, so painted directly as small text they fail
/// WCAG AA (amber ≈2.2:1, cyan ≈2.1:1 on a light card; the darker hues on the dark base).
/// `Color.accentText(_:on:contrast:)` derives an appearance-adjusted variant that clears the bar.
///
/// These tests re-implement the WCAG sRGB→relative-luminance + contrast-ratio math *independently*
/// (they do not lean on the production helpers to grade the production helper) and assert every
/// concrete hue clears the threshold against the representative surface it will be drawn on: a light
/// content card in light mode, a dark card over the deep base in dark mode.
@Suite struct AccentTextContrastTests {

    // MARK: - Independent WCAG math (the reference the helper is graded against)

    /// sRGB channel → linear light (WCAG 2.x definition).
    private func linear(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Relative luminance of an sRGB triple (Rec. 709 weights).
    private func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio between two sRGB triples, 1...21.
    private func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = luminance(a.0, a.1, a.2)
        let lb = luminance(b.0, b.1, b.2)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Resolve a SwiftUI `Color` (as the renderer would) to its sRGB components.
    private func srgb(_ color: Color) -> (Double, Double, Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    // The representative surfaces `Color.accentText` targets, spelled out here as sRGB so the test is
    // self-contained. A light content card, and — for dark mode — a dark card (the *lightest*, hence
    // hardest, surface accent text sits on there), not the near-black base behind it.
    private let lightCard: (Double, Double, Double) = (0.95, 0.95, 0.96)
    private let darkCard: (Double, Double, Double) = (0.17, 0.18, 0.20)

    /// Every hue whose accent is a fixed sRGB triad. `.none` defers to the dynamic system accent, so
    /// it has no stable value to grade.
    private var fixedHues: [LiquidGlassHue] {
        LiquidGlassHue.allCases.filter { $0 != .none }
    }

    // MARK: - Sanity: the test's own math agrees with the production luminance

    @Test func independentMathMatchesTheProductionLuminance() {
        for (r, g, b) in [(0.0, 0.0, 0.0), (1.0, 1.0, 1.0), (0.95, 0.6, 0.2), (0.25, 0.75, 1.0)] {
            let mine = luminance(r, g, b)
            let theirs = Double(AccentLabel.relativeLuminance(red: r, green: g, blue: b))
            #expect(abs(mine - theirs) < 1e-9)
        }
        // And the surfaces the helper references are the ones this test spells out.
        #expect(abs(luminance(lightCard.0, lightCard.1, lightCard.2)
                    - Double(AccentLabel.lightSurfaceLuminance)) < 1e-9)
        #expect(abs(luminance(darkCard.0, darkCard.1, darkCard.2)
                    - Double(AccentLabel.darkSurfaceLuminance)) < 1e-9)
    }

    // MARK: - The raw hues genuinely fail as text (the reason the helper exists)

    @Test func rawLightHuesFailAAAsTextOnALightCard() {
        // The two the audit called out by name, painted raw, are well under AA.
        for hue in [LiquidGlassHue.amber, .cyan] {
            let raw = contrast(srgb(hue.accentColor), lightCard)
            #expect(raw < 4.5, "raw \(hue.rawValue) should fail AA as text on a light card, was \(raw)")
        }
    }

    // MARK: - The helper clears AA for every hue, both appearances

    @Test func derivedAccentTextClearsAAInLightMode() {
        for hue in fixedHues {
            let derived = srgb(Color.accentText(hue.accentColor, on: .light))
            let ratio = contrast(derived, lightCard)
            // Binary-search boundary + sRGB round-trip: allow a hair of slack under 4.5.
            #expect(ratio >= 4.5 - 5e-3, "light \(hue.rawValue) text was \(ratio):1")
        }
    }

    @Test func derivedAccentTextClearsAAInDarkMode() {
        for hue in fixedHues {
            let derived = srgb(Color.accentText(hue.accentColor, on: .dark))
            let ratio = contrast(derived, darkCard)
            #expect(ratio >= 4.5 - 5e-3, "dark \(hue.rawValue) text was \(ratio):1")
        }
    }

    // MARK: - Increased-contrast raises the bar to ~7:1 (AAA)

    @Test func increasedContrastReachesAAA() {
        for hue in fixedHues {
            let light = contrast(srgb(Color.accentText(hue.accentColor, on: .light, contrast: .increased)), lightCard)
            let dark = contrast(srgb(Color.accentText(hue.accentColor, on: .dark, contrast: .increased)), darkCard)
            #expect(light >= 7.0 - 5e-3, "light \(hue.rawValue) at increased contrast was \(light):1")
            #expect(dark >= 7.0 - 5e-3, "dark \(hue.rawValue) at increased contrast was \(dark):1")
        }
    }

    // MARK: - A hue that already clears the bar is left untouched

    @Test func alreadyLegibleAccentIsReturnedUnchanged() {
        // Near-black already clears AA on a light card; the helper must not needlessly repaint it.
        let alreadyDark = Color(.sRGB, red: 0.1, green: 0.1, blue: 0.1, opacity: 1)
        let out = srgb(Color.accentText(alreadyDark, on: .light))
        #expect(abs(out.0 - 0.1) < 1e-6 && abs(out.1 - 0.1) < 1e-6 && abs(out.2 - 0.1) < 1e-6)
    }
}
