import Testing
import SwiftUI
@testable import PdfToolkit

/// The accent-style preset resolves a tool's effective accent three ways. Pin each so a future change
/// to the palette or the resolver can't silently break the Settings option.
@Suite struct AccentStyleTests {

    @Test func multicolorKeepsEachToolsOwnAccent() {
        for tool in Tool.allCases {
            #expect(AccentStyle.multicolor.accent(for: tool, hue: .blue) == tool.accent)
        }
    }

    @Test func singleUsesTheChosenHueForEveryTool() {
        // Under single-accent every tool resolves to the one chosen hue, regardless of its own color.
        for tool in Tool.allCases {
            #expect(AccentStyle.single.accent(for: tool, hue: .green) == LiquidGlassHue.green.accentColor)
        }
    }

    @Test func singleWithNoneDefersToTheSystemAccent() {
        #expect(AccentStyle.single.accent(for: .compress, hue: .none) == Color.accentColor)
    }

    @Test func monochromeIsOneNeutralForEveryTool() {
        for tool in Tool.allCases {
            #expect(AccentStyle.monochrome.accent(for: tool, hue: .blue) == AccentStyle.monochromeAccent)
        }
    }
}
