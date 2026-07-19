import Testing
import Foundation
@testable import PdfToolkit

/// Settings-related value types and — critically — the exact UserDefaults key strings. A key is a
/// persisted contract: renaming one silently resets that preference for every existing user, so the
/// literals are pinned here as a tripwire.
@Suite struct SettingsValueTypesTests {

    // MARK: SettingsTab

    @Test func settingsTabHasStableRawValuesAndCopy() {
        #expect(SettingsTab.allCases == [.general, .appearance, .advanced])
        for tab in SettingsTab.allCases {
            #expect(tab.id == tab.rawValue)
            #expect(!tab.displayName.isEmpty)
        }
        #expect(SettingsTab.selectedTabDefaultsKey == "pdfutils.settingsSelectedTab")
    }

    @MainActor
    @Test func settingsPresenterOpensAndCloses() {
        let presenter = SettingsPresenter()
        presenter.close()
        #expect(!presenter.isPresented)

        presenter.open(.general)
        #expect(presenter.isPresented)
        #expect(presenter.tab == .general)

        presenter.close()
        #expect(!presenter.isPresented)
        // Reopening without a tab keeps the last tab.
        presenter.open()
        #expect(presenter.tab == .general)
    }

    @MainActor
    @Test func settingsPresenterFallsBackToAppearanceOnAnUnknownStoredTab() {
        let key = SettingsTab.selectedTabDefaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set("not-a-tab", forKey: key)
        #expect(SettingsPresenter().tab == .appearance)
    }

    // MARK: ListDensity

    @Test func listDensityPaddingValuesArePinned() {
        #expect(ListDensity.allCases == [.comfortable, .compact])
        #expect(ListDensity.comfortable.rowVerticalPadding == 4)
        #expect(ListDensity.compact.rowVerticalPadding == 1)
        #expect(ListDensity.comfortable.rowInsetVertical == 6)
        #expect(ListDensity.compact.rowInsetVertical == 2)
        for density in ListDensity.allCases {
            #expect(density.id == density.rawValue)
            #expect(!density.displayName.isEmpty)
        }
        #expect(ListDensity.defaultsKey == "pdfutils.listDensity")
    }

    // MARK: Background styles

    @Test func mainWindowBackgroundStylesHaveCopyAndStableRawValues() {
        #expect(Set(MainWindowBackgroundStyle.allCases.map(\.rawValue))
            == ["liquidGlass", "systemWindow", "paperWhite", "softNeutral"])
        for style in MainWindowBackgroundStyle.allCases {
            #expect(style.id == style.rawValue)
            #expect(!style.title.isEmpty)
            #expect(!style.detail.isEmpty)
        }
    }

    @Test func mergePreviewBackgroundStylesHaveCopyAndStableRawValues() {
        #expect(Set(MergePreviewBackgroundStyle.allCases.map(\.rawValue))
            == ["white", "systemWindow", "matchMain"])
        for style in MergePreviewBackgroundStyle.allCases {
            #expect(style.id == style.rawValue)
            #expect(!style.title.isEmpty)
            #expect(!style.detail.isEmpty)
        }
    }

    // MARK: Persisted key contract

    @Test func settingsKeyStringsAreStable() {
        #expect(SettingsKeys.mainWindowBackground == "pdfutils.settings.mainWindowBackground")
        #expect(SettingsKeys.mergePreviewBackground == "pdfutils.settings.mergePreviewBackground")
        #expect(SettingsKeys.redactRasterLongEdge == "pdfutils.settings.redactRasterLongEdge")
    }

    @Test func liquidGlassKeyStringsAreStable() {
        #expect(LiquidGlass.hueKey == "pdfutils.liquidGlassHue")
        #expect(LiquidGlass.appearanceModeKey == "pdfutils.appearanceMode")
        #expect(LiquidGlass.levelKey == "pdfutils.glassLevel")
        #expect(LiquidGlass.surfaceStyleKey == "pdfutils.contentSurfaceStyle")
        #expect(LiquidGlass.tintKey == "pdfutils.contentSurfaceTint")
    }
}
