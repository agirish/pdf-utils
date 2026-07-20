import SwiftUI

/// How the per-tool accent colors are chosen — a preset picked in Settings → Appearance. Orthogonal
/// to the liquid-glass hue: `multicolor` keeps each tool's own identity color, `single` makes every
/// tool wear the app's chosen accent hue, `monochrome` drops color entirely for a neutral look.
public enum AccentStyle: String, CaseIterable, Identifiable, Sendable {
    /// Each tool keeps its own color (Compress orange, Protect green, …). The default.
    case multicolor
    /// Every tool uses the one accent hue chosen above.
    case single
    /// Neutral — every tool's accent is a single restrained gray.
    case monochrome

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .multicolor: return "Multicolor"
        case .single: return "Single"
        case .monochrome: return "Monochrome"
        }
    }

    public var detail: String {
        switch self {
        case .multicolor:
            return "Each tool keeps its own accent color — orange for Compress, green for Protect, and so on."
        case .single:
            return "Every tool uses the accent color chosen above, for a calmer, uniform look."
        case .monochrome:
            return "No accent color — every tool uses a neutral gray."
        }
    }

    /// The restrained neutral used by `monochrome`; a cool mid-gray legible as an accent in both themes.
    static let monochromeAccent = Color(red: 0.52, green: 0.55, blue: 0.60)

    /// The effective accent for `tool` under this style and the chosen liquid-glass `hue`.
    public func accent(for tool: Tool, hue: LiquidGlassHue) -> Color {
        switch self {
        case .multicolor:
            return tool.accent
        case .single:
            // `.none` defers to the macOS system accent, matching how the hue behaves elsewhere.
            return hue == .none ? Color.accentColor : hue.accentColor
        case .monochrome:
            return Self.monochromeAccent
        }
    }
}
