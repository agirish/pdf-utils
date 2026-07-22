import SwiftUI

/// One inline caption under a page-range field: an accent-tinted hint when the range is valid ("N
/// pages will remain") or a red error when it isn't ("Page 99 is not in this document"). Shared by
/// Extract, Delete, and Split's custom-ranges mode so the three read identically — the additive
/// counterpart to Merge's per-row warnings.
struct RangeFieldNote: View {
    let text: String
    var systemImage: String
    /// Red + warning triangle when true (a bad range); accent-tinted when false (a valid summary).
    var isError: Bool = false
    var accent: Color
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        // Error is signaled by red vs the accent; when the user has asked not to rely on color alone,
        // pin a warning triangle so the two states are told apart by shape, not just hue.
        let symbol = isError && differentiateWithoutColor ? "exclamationmark.triangle.fill" : systemImage
        // The valid summary paints the accent as small text; route it through the appearance-adjusted
        // accent so a light hue on a light card (or a dark hue on the dark base) clears WCAG AA.
        return Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(isError ? Color.red : Color.accentText(accent, on: scheme, contrast: contrast))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel((isError ? "Error: " : "") + text)
    }
}
