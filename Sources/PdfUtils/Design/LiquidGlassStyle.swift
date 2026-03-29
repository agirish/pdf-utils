import SwiftUI

// MARK: - Liquid Glass (aligned with SyncCloud `Modules/Design`)

/// Hue options for the liquid glass background gradient.
enum LiquidGlassHue: String, CaseIterable, Identifiable {
    case blue
    case cyan
    case teal
    case green
    case amber
    case coral
    case rose
    case purple
    case indigo
    case slate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .teal: return "Teal"
        case .green: return "Green"
        case .amber: return "Amber"
        case .coral: return "Coral"
        case .rose: return "Rose"
        case .purple: return "Purple"
        case .indigo: return "Indigo"
        case .slate: return "Slate"
        }
    }

    var accentColor: Color {
        switch self {
        case .blue: return Color(red: 0.2, green: 0.5, blue: 1.0)
        case .cyan: return Color(red: 0.25, green: 0.75, blue: 1.0)
        case .teal: return Color(red: 0.2, green: 0.65, blue: 0.65)
        case .green: return Color(red: 0.2, green: 0.7, blue: 0.5)
        case .amber: return Color(red: 0.95, green: 0.6, blue: 0.2)
        case .coral: return Color(red: 1.0, green: 0.45, blue: 0.4)
        case .rose: return Color(red: 0.95, green: 0.4, blue: 0.55)
        case .purple: return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .indigo: return Color(red: 0.4, green: 0.35, blue: 0.9)
        case .slate: return Color(red: 0.4, green: 0.45, blue: 0.55)
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .blue:
            return [
                Color(red: 0.25, green: 0.75, blue: 1.0),
                Color(red: 0.15, green: 0.45, blue: 1.0),
                Color(red: 0.05, green: 0.25, blue: 0.85),
            ]
        case .cyan:
            return [
                Color(red: 0.35, green: 0.85, blue: 1.0),
                Color(red: 0.2, green: 0.7, blue: 0.95),
                Color(red: 0.1, green: 0.5, blue: 0.85),
            ]
        case .teal:
            return [
                Color(red: 0.25, green: 0.8, blue: 0.8),
                Color(red: 0.15, green: 0.6, blue: 0.65),
                Color(red: 0.08, green: 0.4, blue: 0.5),
            ]
        case .green:
            return [
                Color(red: 0.3, green: 0.85, blue: 0.6),
                Color(red: 0.2, green: 0.65, blue: 0.5),
                Color(red: 0.1, green: 0.45, blue: 0.4),
            ]
        case .amber:
            return [
                Color(red: 1.0, green: 0.75, blue: 0.35),
                Color(red: 0.95, green: 0.6, blue: 0.2),
                Color(red: 0.8, green: 0.45, blue: 0.1),
            ]
        case .coral:
            return [
                Color(red: 1.0, green: 0.55, blue: 0.5),
                Color(red: 0.95, green: 0.4, blue: 0.4),
                Color(red: 0.8, green: 0.25, blue: 0.35),
            ]
        case .rose:
            return [
                Color(red: 1.0, green: 0.5, blue: 0.65),
                Color(red: 0.9, green: 0.35, blue: 0.55),
                Color(red: 0.7, green: 0.2, blue: 0.5),
            ]
        case .purple:
            return [
                Color(red: 0.6, green: 0.45, blue: 1.0),
                Color(red: 0.45, green: 0.35, blue: 0.9),
                Color(red: 0.3, green: 0.2, blue: 0.75),
            ]
        case .indigo:
            return [
                Color(red: 0.45, green: 0.4, blue: 0.95),
                Color(red: 0.35, green: 0.3, blue: 0.85),
                Color(red: 0.2, green: 0.2, blue: 0.7),
            ]
        case .slate:
            return [
                Color(red: 0.5, green: 0.55, blue: 0.65),
                Color(red: 0.4, green: 0.45, blue: 0.55),
                Color(red: 0.25, green: 0.3, blue: 0.4),
            ]
        }
    }
}

enum LiquidGlass {
    static let cardCornerRadius: CGFloat = 14
    static let smallCornerRadius: CGFloat = 10

    static let cardShadow = (color: Color.black.opacity(0.06), radius: CGFloat(12), x: CGFloat(0), y: CGFloat(4))

    /// pdf-utils–scoped keys (do not collide with SyncCloud defaults on the same Mac).
    static let intensityKey = "pdfutils.liquidGlassIntensity"
    static let hueKey = "pdfutils.liquidGlassHue"
}

extension View {
    /// App-level liquid glass backdrop (SyncCloud-style): colored gradient + thin material.
    @ViewBuilder
    func liquidGlassAppBackground(intensity: Double, hue: LiquidGlassHue = .purple) -> some View {
        let t = max(0.0, min(1.0, intensity))
        let colors = hue.gradientColors
        let opacities: [Double] = [0.06 + 0.16 * t, 0.05 + 0.14 * t, 0.04 + 0.10 * t]
        let gradientStops = zip(colors, opacities).map { $0.0.opacity($0.1) }

        background {
            ZStack {
                LinearGradient(
                    colors: gradientStops,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Color.clear
                    .background(.thinMaterial.opacity(0.45 + 0.20 * t))
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    func glassCardStyle(material: Material = .regularMaterial, intensity: Double = 0.65) -> some View {
        let t = max(0.0, min(1.0, intensity))
        if #available(macOS 26.0, *) {
            self
                .glassEffect(t > 0.33 ? .regular : .clear, in: .rect(cornerRadius: LiquidGlass.cardCornerRadius))
        } else {
            self
                .background(material.opacity(0.55 + 0.35 * t))
                .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous))
                .shadow(
                    color: LiquidGlass.cardShadow.color,
                    radius: LiquidGlass.cardShadow.radius,
                    x: LiquidGlass.cardShadow.x,
                    y: LiquidGlass.cardShadow.y
                )
        }
    }

    @ViewBuilder
    func glassBarStyle(intensity: Double = 0.65) -> some View {
        let t = max(0.0, min(1.0, intensity))
        if #available(macOS 26.0, *) {
            self
                .glassEffect(t > 0.33 ? .regular : .clear, in: .rect(cornerRadius: LiquidGlass.smallCornerRadius))
        } else {
            self
                .background(.ultraThinMaterial.opacity(0.55 + 0.35 * t))
                .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.smallCornerRadius, style: .continuous))
        }
    }
}
