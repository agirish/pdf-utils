import SwiftUI

/// How the per-tool accent colors are chosen — a preset picked in Settings → Appearance. `multicolor`
/// keeps each tool's own identity color; `single` makes every tool wear the one accent color chosen in
/// the "Accent color" row above (choose Graphite there for a monochrome, no-color look).
public enum AccentStyle: String, CaseIterable, Identifiable, Sendable {
    /// Each tool keeps its own color (Compress orange, Protect green, …). The default.
    case multicolor
    /// Every tool uses the one accent color chosen above (Graphite for monochrome).
    case single

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .multicolor: return "Multicolor"
        case .single: return "Single"
        }
    }

    public var detail: String {
        switch self {
        case .multicolor:
            return "Each tool keeps its own accent color — orange for Compress, green for Protect, and so on."
        case .single:
            return "Every tool uses the accent color chosen above. Pick Graphite there for a monochrome look."
        }
    }

    /// The effective accent for `tool` under this style and the chosen liquid-glass `hue`.
    public func accent(for tool: Tool, hue: LiquidGlassHue) -> Color {
        switch self {
        case .multicolor:
            return tool.accent
        case .single:
            // `.none` defers to the macOS system accent, matching how the hue behaves elsewhere.
            return hue == .none ? Color.accentColor : hue.accentColor
        }
    }
}
