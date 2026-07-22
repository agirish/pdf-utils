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

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(isError ? Color.red : accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel((isError ? "Error: " : "") + text)
    }
}
