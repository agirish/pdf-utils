import Testing
import Foundation
@testable import PdfToolkit

/// Settings-related value types and — critically — the exact UserDefaults key strings. A key is a
/// persisted contract: renaming one silently resets that preference for every existing user, so the
/// literals are pinned here as a tripwire.
@Suite struct SettingsValueTypesTests {

    // MARK: SettingsTab

    @Test func settingsTabHasStableRawValuesAndCopy() {
        #expect(SettingsTab.allCases == [.files, .appearance, .advanced])
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

        presenter.open(.advanced)
        #expect(presenter.isPresented)
        #expect(presenter.tab == .advanced)

        presenter.close()
        #expect(!presenter.isPresented)
        // Reopening without a tab keeps the last tab.
        presenter.open()
        #expect(presenter.tab == .advanced)
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

    // MARK: Export behavior value types

    @Test func afterExportActionHasStableRawValuesAndCopy() {
        #expect(Set(AfterExportAction.allCases.map(\.rawValue)) == ["doNothing", "revealInFinder", "openFile"])
        #expect(AfterExportAction.defaultAction == .revealInFinder)
        for action in AfterExportAction.allCases {
            #expect(action.id == action.rawValue)
            #expect(!action.displayName.isEmpty)
            #expect(!action.detail.isEmpty)
        }
    }

    @Test func afterExportActionCurrentReadsDefaultsWithFallback() {
        let defaults = Self.scratchDefaults()
        #expect(AfterExportAction.current(defaults) == .revealInFinder)
        defaults.set("openFile", forKey: SettingsKeys.afterExportAction)
        #expect(AfterExportAction.current(defaults) == .openFile)
        defaults.set("nonsense", forKey: SettingsKeys.afterExportAction)
        #expect(AfterExportAction.current(defaults) == .revealInFinder)
    }

    @Test func saveLocationHasStableRawValuesAndCopy() {
        #expect(Set(SaveLocation.allCases.map(\.rawValue)) == ["askEachTime", "besideOriginal"])
        #expect(SaveLocation.defaultLocation == .askEachTime)
        for location in SaveLocation.allCases {
            #expect(location.id == location.rawValue)
            #expect(!location.displayName.isEmpty)
            #expect(!location.detail.isEmpty)
        }
    }

    @Test func saveLocationCurrentReadsDefaultsWithFallback() {
        let defaults = Self.scratchDefaults()
        #expect(SaveLocation.current(defaults) == .askEachTime)
        defaults.set("besideOriginal", forKey: SettingsKeys.saveLocation)
        #expect(SaveLocation.current(defaults) == .besideOriginal)
        defaults.set("nonsense", forKey: SettingsKeys.saveLocation)
        #expect(SaveLocation.current(defaults) == .askEachTime)
    }

    // MARK: Export coordinator naming

    @Test func suggestedFilenameHonorsSuffixToggle() {
        let on = Self.scratchDefaults()
        on.set(true, forKey: SettingsKeys.appendFilenameSuffix)
        #expect(PDFExportCoordinator.suggestedFilename(stem: "Report", suffixWord: "compressed", defaults: on) == "Report-compressed.pdf")

        let off = Self.scratchDefaults()
        off.set(false, forKey: SettingsKeys.appendFilenameSuffix)
        #expect(PDFExportCoordinator.suggestedFilename(stem: "Report", suffixWord: "compressed", defaults: off) == "Report.pdf")

        // Unset defaults to ON (the app's default), so a fresh install still suffixes.
        let unset = Self.scratchDefaults()
        #expect(PDFExportCoordinator.suggestedFilename(stem: "Report", suffixWord: "compressed", defaults: unset) == "Report-compressed.pdf")
    }

    @Test func uniqueURLNumbersClashesInsteadOfOverwriting() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfutils-unique-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Nothing there yet → the plain name.
        let first = PDFExportCoordinator.uniqueURL(inDirectory: dir, filename: "Report-compressed.pdf")
        #expect(first.lastPathComponent == "Report-compressed.pdf")

        try Data().write(to: first)
        let second = PDFExportCoordinator.uniqueURL(inDirectory: dir, filename: "Report-compressed.pdf")
        #expect(second.lastPathComponent == "Report-compressed 2.pdf")

        try Data().write(to: second)
        let third = PDFExportCoordinator.uniqueURL(inDirectory: dir, filename: "Report-compressed.pdf")
        #expect(third.lastPathComponent == "Report-compressed 3.pdf")
    }

    /// A throwaway `UserDefaults` suite so tests don't read or mutate the real preferences domain.
    private static func scratchDefaults() -> UserDefaults {
        let suite = "pdfutils.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Persisted key contract

    @Test func settingsKeyStringsAreStable() {
        #expect(SettingsKeys.mainWindowBackground == "pdfutils.settings.mainWindowBackground")
        #expect(SettingsKeys.mergePreviewBackground == "pdfutils.settings.mergePreviewBackground")
        #expect(SettingsKeys.redactRasterLongEdge == "pdfutils.settings.redactRasterLongEdge")
        #expect(SettingsKeys.afterExportAction == "pdfutils.settings.afterExportAction")
        #expect(SettingsKeys.saveLocation == "pdfutils.settings.saveLocation")
        #expect(SettingsKeys.appendFilenameSuffix == "pdfutils.settings.appendFilenameSuffix")
        #expect(SettingsKeys.reopenLastTool == "pdfutils.settings.reopenLastTool")
        #expect(SettingsKeys.lastToolUsed == "pdfutils.settings.lastToolUsed")
        #expect(SettingsKeys.stripMetadataOnExport == "pdfutils.settings.stripMetadataOnExport")
        #expect(SettingsKeys.defaultCompressionQuality == "pdfutils.settings.defaultCompressionQuality")
    }

    @Test func liquidGlassKeyStringsAreStable() {
        #expect(LiquidGlass.hueKey == "pdfutils.liquidGlassHue")
        #expect(LiquidGlass.appearanceModeKey == "pdfutils.appearanceMode")
        #expect(LiquidGlass.levelKey == "pdfutils.glassLevel")
        #expect(LiquidGlass.surfaceStyleKey == "pdfutils.contentSurfaceStyle")
        #expect(LiquidGlass.tintKey == "pdfutils.contentSurfaceTint")
    }
}
