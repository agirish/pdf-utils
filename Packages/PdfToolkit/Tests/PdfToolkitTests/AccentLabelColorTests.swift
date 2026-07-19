import Testing
import SwiftUI
@testable import PdfToolkit

/// The WCAG luminance math that decides whether a glyph drawn on an accent fill should be white or
/// near-black. A fixed white checkmark vanished on the lighter hues (amber/cyan) — these tests pin
/// the luminance formula and the light-fill → dark-ink decision that fixed it.
@Suite struct AccentLabelColorTests {

    private func close(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = 1e-9) -> Bool { abs(a - b) < tol }

    @Test func luminanceIsZeroForBlackAndOneForWhite() {
        #expect(close(AccentLabel.relativeLuminance(red: 0, green: 0, blue: 0), 0))
        #expect(close(AccentLabel.relativeLuminance(red: 1, green: 1, blue: 1), 1))
    }

    @Test func luminanceWeightsGreenAboveRedAboveBlue() {
        // Rec. 709 coefficients: green contributes most to perceived brightness, blue least.
        let green = AccentLabel.relativeLuminance(red: 0, green: 1, blue: 0)
        let red = AccentLabel.relativeLuminance(red: 1, green: 0, blue: 0)
        let blue = AccentLabel.relativeLuminance(red: 0, green: 0, blue: 1)
        #expect(green > red)
        #expect(red > blue)
    }

    @Test func prefersDarkTextOnLightFillsOnly() {
        #expect(AccentLabel.prefersDarkText(red: 1, green: 1, blue: 1))        // white → dark ink
        #expect(!AccentLabel.prefersDarkText(red: 0, green: 0, blue: 0))       // black → white ink
        #expect(AccentLabel.prefersDarkText(red: 0.95, green: 0.75, blue: 0.35))  // light amber → dark
        #expect(!AccentLabel.prefersDarkText(red: 0.05, green: 0.25, blue: 0.85)) // deep blue → white
    }

    @Test func onFillLabelPicksLegibleInkForTheFill() {
        // A light fill gets near-black ink; a dark fill gets white — resolved from the fill's own
        // luminance, which is the whole point (a fixed white glyph failed on light hues).
        let lightFill = Color(red: 0.95, green: 0.75, blue: 0.35)
        let darkFill = Color(red: 0.05, green: 0.25, blue: 0.85)
        #expect(Color.onFillLabel(lightFill) == Color.black.opacity(0.85))
        #expect(Color.onFillLabel(darkFill) == Color.white)
    }
}
