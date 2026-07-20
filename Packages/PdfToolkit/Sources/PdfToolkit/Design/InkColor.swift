import SwiftUI

/// A named ink color shared by the Watermark and Fill & Sign tools, so the two present one palette
/// with identical values and swatch sizing instead of each hardcoding its own drifting list.
///
/// Components are stored as `CGFloat` (not a resolved `Color`) so a placed Fill & Sign item stays
/// `Sendable` for the background export queue — its `FillSignItem` carries the same `red/green/blue`.
struct InkColor: Identifiable, Hashable {
    let id: String
    let name: String
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var color: Color { Color(red: Double(red), green: Double(green), blue: Double(blue)) }

    /// The canonical palette. One set of values so Watermark and Fill & Sign never diverge.
    static let palette: [InkColor] = [
        InkColor(id: "black", name: "Black", red: 0.11, green: 0.11, blue: 0.12),
        InkColor(id: "gray",  name: "Gray",  red: 0.50, green: 0.50, blue: 0.52),
        InkColor(id: "red",   name: "Red",   red: 0.78, green: 0.12, blue: 0.14),
        InkColor(id: "blue",  name: "Blue",  red: 0.14, green: 0.30, blue: 0.78),
    ]

    /// Swatch diameter for the palette row, shared so both tools size their swatches identically.
    static let swatchDiameter: CGFloat = 24

    /// The palette entry for a stored id, falling back to the first (Black) for an unknown id.
    static func with(id: String) -> InkColor {
        palette.first { $0.id == id } ?? palette[0]
    }
}
