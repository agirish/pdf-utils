import Foundation
import Testing
@testable import PdfToolkit

/// Covers the test-support cleanup itself. Without these, a regression in `wipeDefaultsSuite` is
/// invisible — the suite still tears down correctly, it just quietly leaves a plist behind, which
/// is exactly the failure that accumulated ~7,900 files in `~/Library/Preferences`.
struct ScratchDefaultsTests {
    private func plistURL(_ suite: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(suite).plist")
    }

    @Test func wipingASuiteUnlinksItsPlistNotJustItsKeys() throws {
        let suite = scratchSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("value", forKey: "probe")
        CFPreferencesAppSynchronize(suite as CFString)
        #expect(FileManager.default.fileExists(atPath: plistURL(suite).path),
                "precondition: writing a key should create the backing plist")

        wipeDefaultsSuite(suite)

        // The point of the helper. `removePersistentDomain` alone empties the domain but leaves a
        // 42-byte plist on disk, which is what leaked.
        #expect(!FileManager.default.fileExists(atPath: plistURL(suite).path))
    }

    @Test func wipingIsSafeToRepeat() {
        let suite = scratchSuiteName()
        wipeDefaultsSuite(suite)   // never created
        wipeDefaultsSuite(suite)
        #expect(!FileManager.default.fileExists(atPath: plistURL(suite).path))
    }

    @Test func scratchDefaultsWipesItselfWhenTheLastReferenceGoesAway() {
        var suite = ""
        do {
            let defaults = ScratchDefaults()
            suite = defaults.suiteName
            defaults.set("value", forKey: "probe")
            CFPreferencesAppSynchronize(suite as CFString)
            #expect(FileManager.default.fileExists(atPath: plistURL(suite).path),
                    "precondition: the suite should exist while it is referenced")
        }
        // Cleanup rides on deinit for the factory sites that have nowhere to hang a `defer`.
        #expect(!FileManager.default.fileExists(atPath: plistURL(suite).path))
    }

    @Test func onlyThisTargetsScratchPrefixesAreEligibleForDeletion() {
        #expect(isScratchSuiteName(scratchSuiteName()))
        #expect(isScratchSuiteName("PDFExportCoordinatorTests-\(UUID().uuidString)"))

        // The real app domain, the helper's, and anything else must never be wipeable.
        #expect(!isScratchSuiteName("com.abhishekgirish.PdfUtils"))
        #expect(!isScratchSuiteName("com.abhishekgirish.PdfUtils.Helper"))
        #expect(!isScratchSuiteName(".GlobalPreferences"))
        #expect(!isScratchSuiteName(""))
        // A separator would let a name escape ~/Library/Preferences.
        #expect(!isScratchSuiteName("pdfutils.tests./../../com.apple.finder"))
        #expect(!isScratchSuiteName("pdfutils.tests...%2Fescape"))
    }
}
