import SwiftUI

/// Reads the live glass appearance settings — material level, accent hue, surface tint — straight from
/// `UserDefaults`, resolving each stored raw value with the shared `LiquidGlass` default.
///
/// A `DynamicProperty`, so a view or view-modifier declares one `GlassAppearance` and re-renders when
/// any of the three change — instead of re-declaring the `@AppStorage` triad and its two resolve
/// computed properties, which every glass reader used to copy inline (and which let a seed and its
/// fallback drift). The Settings *editor* keeps its own `@AppStorage`: it writes these keys and needs
/// the two-way bindings. Everything that only *reads* the appearance shares this.
public struct GlassAppearance: DynamicProperty {
    @AppStorage(LiquidGlass.levelKey) private var levelRaw: String = LiquidGlass.defaultLevel.rawValue
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = LiquidGlass.defaultHue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var tintValue: Double = LiquidGlass.defaultTint

    public init() {}

    /// The glass material: clear / frosted / solid.
    public var level: GlassLevel { GlassLevel(rawValue: levelRaw) ?? LiquidGlass.defaultLevel }
    /// The accent hue washed over content surfaces and the window background.
    public var hue: LiquidGlassHue { LiquidGlassHue(rawValue: hueRaw) ?? LiquidGlass.defaultHue }
    /// Accent-tint strength applied to content surfaces (0…1).
    public var tint: Double { tintValue }
}
