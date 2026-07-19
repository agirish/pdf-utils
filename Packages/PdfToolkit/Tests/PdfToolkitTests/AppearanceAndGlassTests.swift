import Testing
import AppKit
import SwiftUI
import Foundation
@testable import PdfToolkit

/// The appearance value types (aligned with SyncCloud's Design module) and the one-time legacy
/// migration. These drive Settings pickers and the window backdrop, so the tests pin the fixed
/// numeric constants, the raw-value contracts, and the migration's idempotence.
@Suite struct AppearanceAndGlassTests {

    // MARK: LiquidGlassHue

    @Test func everyHueHasCompleteUniqueDisplayCopy() {
        for hue in LiquidGlassHue.allCases {
            #expect(!hue.displayName.isEmpty)
            #expect(LiquidGlassHue(rawValue: hue.rawValue) == hue)   // raw values are stable/round-trip
        }
        let names = LiquidGlassHue.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test func everyHueGradientHasThreeStops() {
        // The backdrop expects a top/mid/bottom triad from every hue.
        for hue in LiquidGlassHue.allCases {
            #expect(hue.gradientColors.count == 3, "\(hue) gradient")
        }
    }

    @Test func noneHuePaintsAClearGradient() {
        // `.none` means "no accent wash" — every stop is clear so the background reads neutral.
        #expect(LiquidGlassHue.none.gradientColors == [.clear, .clear, .clear])
    }

    // MARK: GlassLevel

    @Test func glassLevelBackgroundIntensityIsPinned() {
        // Frosted keeps the old slider's 0.65 so migrated installs render unchanged.
        #expect(GlassLevel.clear.backgroundIntensity == 0.0)
        #expect(GlassLevel.frosted.backgroundIntensity == 0.65)
        #expect(GlassLevel.solid.backgroundIntensity == 1.0)
    }

    @Test func clearGlassIsFlooredToFrostedForOverlayChrome() {
        // Clear glass over live app content would be two competing layers, so chrome floors it.
        #expect(GlassLevel.clear.flooredForChrome == .frosted)
        #expect(GlassLevel.frosted.flooredForChrome == .frosted)
        #expect(GlassLevel.solid.flooredForChrome == .solid)
    }

    @Test func clearGlassDeepensTheOverlayScrim() {
        #expect(GlassLevel.clear.overlayScrimOpacity == 0.55)
        #expect(GlassLevel.frosted.overlayScrimOpacity == 0.35)
        #expect(GlassLevel.solid.overlayScrimOpacity == 0.35)
    }

    @Test func glassLevelAndSurfaceStyleHaveCompleteCopy() {
        for level in GlassLevel.allCases {
            #expect(!level.displayName.isEmpty)
            #expect(!level.detail.isEmpty)
        }
        for style in SurfaceStyle.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.detail.isEmpty)
        }
    }

    // MARK: Legacy migration

    /// A throwaway defaults domain so migration tests never touch the real app or each other.
    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "pdfutils.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func migrationSeedsFrostedAndClearsTheRetiredIntensityKey() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        // A pre-GlassLevel install: an intensity value stored, no level yet.
        defaults.set(0.4, forKey: LiquidGlass.intensityKey)

        LiquidGlass.migrateLegacyAppearance(defaults)

        #expect(defaults.string(forKey: LiquidGlass.levelKey) == GlassLevel.frosted.rawValue)
        #expect(defaults.object(forKey: LiquidGlass.intensityKey) == nil)
    }

    @Test func migrationIsANoOpOnceLevelIsSet() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(GlassLevel.solid.rawValue, forKey: LiquidGlass.levelKey)

        LiquidGlass.migrateLegacyAppearance(defaults)   // idempotent — safe to run every launch

        #expect(defaults.string(forKey: LiquidGlass.levelKey) == GlassLevel.solid.rawValue)
    }

    // MARK: AppearanceMode

    @Test func appearanceModeCopyAndSymbolsResolve() {
        for mode in AppearanceMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.detail.isEmpty)
            #expect(NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(mode.symbolName)")
        }
    }

    @Test func appearanceModeMapsToTheRightNSAppearance() {
        // `.system` MUST be nil — that's what lets it track a mid-session system flip.
        #expect(AppearanceMode.system.nsAppearance == nil)
        #expect(AppearanceMode.light.nsAppearance?.name == .aqua)
        #expect(AppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }

    @MainActor
    @Test func resolvedAppearanceReadsTheKeyAndFallsBackToSystem() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(AppAppearance.resolved(defaults) == .system)               // unset → system
        defaults.set("dark", forKey: LiquidGlass.appearanceModeKey)
        #expect(AppAppearance.resolved(defaults) == .dark)
        defaults.set("bogus", forKey: LiquidGlass.appearanceModeKey)
        #expect(AppAppearance.resolved(defaults) == .system)               // unknown → system
    }
}
