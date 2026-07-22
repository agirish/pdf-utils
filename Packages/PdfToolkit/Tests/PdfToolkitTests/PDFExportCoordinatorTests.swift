import Foundation
import PDFKit
import Testing
@testable import PdfToolkit

/// The metadata-stripping side of the shared export coordinator. Naming and unique-URL behavior are
/// covered in `SettingsValueTypesTests`; this exercises the PDF-touching path, including the guard
/// that keeps encrypted output intact.
@Suite struct PDFExportCoordinatorTests {

    @Test func stripMetadataClearsAuthorAndTitleButKeepsPages() throws {
        let base = try PDFFixtures.pdfData(markers: [PDFFixtures.marker(1), PDFFixtures.marker(2)])
        let doc = try #require(PDFDocument(data: base))
        doc.documentAttributes = [
            PDFDocumentAttribute.authorAttribute: "Alice",
            PDFDocumentAttribute.titleAttribute: "Quarterly Secrets",
        ]
        let withMetadata = try #require(doc.dataRepresentation())
        // Sanity: the info really is present before stripping.
        let before = try #require(PDFDocument(data: withMetadata))
        #expect(before.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Alice")

        let stripped = PDFExportCoordinator.stripMetadata(withMetadata)
        let after = try #require(PDFDocument(data: stripped))
        #expect(after.pageCount == 2)
        let attributes = after.documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attributes[PDFDocumentAttribute.titleAttribute] == nil)
    }

    @Test func stripMetadataLeavesEncryptedOutputUntouched() throws {
        let dir = FixtureDir()
        let source = dir.url("source.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: source)
        let encrypted = dir.url("encrypted.pdf")
        try PDFToolkit.encrypt(inputURL: source, outputURL: encrypted, password: "hunter2")
        let encryptedData = try Data(contentsOf: encrypted)

        let result = PDFExportCoordinator.stripMetadata(encryptedData)
        // Untouched byte-for-byte — re-serializing would strip the encryption.
        #expect(result == encryptedData)
        #expect(PDFDocument(data: result)?.isEncrypted == true)
    }

    @Test func stripMetadataReturnsInputForNonPDFData() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        #expect(PDFExportCoordinator.stripMetadata(garbage) == garbage)
    }

    /// Pins the Clean Metadata opt-out end to end: with the global strip setting ON, the default
    /// route still strips, and `applyMetadataStrip: false` preserves the fields the user typed —
    /// a finalization-order refactor that reintroduced stripping there would erase them silently.
    @MainActor
    @Test func routeHonorsTheApplyMetadataStripFlag() async throws {
        // A scratch defaults suite, not .standard — the batch-runner strip test owns that key in
        // the global domain and the suites run in parallel.
        let suiteName = "PDFExportCoordinatorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SettingsKeys.stripMetadataOnExport)

        let base = try PDFFixtures.pdfData(markers: [PDFFixtures.marker(1)])
        let doc = try #require(PDFDocument(data: base))
        doc.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Alice"]
        let withMetadata = try #require(doc.dataRepresentation())

        func author(of outcome: PDFExportCoordinator.Outcome) throws -> String? {
            guard case .present(let document, _) = outcome else {
                Issue.record("expected .present (source: nil never saves beside)")
                return nil
            }
            return PDFDocument(data: document.data)?
                .documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        }

        let stripped = try await PDFExportCoordinator.route(
            data: withMetadata, source: nil, toolTitle: "T", defaultStem: "t", suffixWord: "s",
            defaults: defaults
        )
        #expect(try author(of: stripped) == nil)

        let kept = try await PDFExportCoordinator.route(
            data: withMetadata, source: nil, toolTitle: "T", defaultStem: "t", suffixWord: "s",
            applyMetadataStrip: false, defaults: defaults
        )
        #expect(try author(of: kept) == "Alice")
    }

    // MARK: - Save-beside-original branch

    /// Polls the shared log's mirror (drained onto the main queue asynchronously) for an entry whose
    /// message begins with `prefix`. `route` records into `ActivityLog.shared`, so a per-test-unique
    /// tool title is used as the prefix to isolate this run's save record from every other suite's.
    @MainActor
    private func waitForSharedEntry(prefix: String) async -> LogEntry? {
        for _ in 0..<300 {
            if let entry = ActivityLog.shared.entries.last(where: { $0.message.hasPrefix(prefix) }) {
                return entry
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// The whole "Save beside original" branch end to end — the path every existing route test skips by
    /// passing `source: nil`. With a real source and that location set, `route` writes the finalized PDF
    /// into the source's own folder under the suffixed name, records the save, runs the after-export
    /// action, and returns `.savedBeside(url)`. Driven entirely through a scratch defaults suite so the
    /// global domain (and parallel suites) stay untouched.
    @MainActor
    @Test func routeSavesBesideOriginalUnderTheSuffixedName() async throws {
        let suiteName = "PDFExportCoordinatorTests-beside-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(SaveLocation.besideOriginal.rawValue, forKey: SettingsKeys.saveLocation)
        defaults.set(true, forKey: SettingsKeys.appendFilenameSuffix)
        // A no-op after-export action keeps the run from stealing Finder focus. Reaching `.savedBeside`
        // (returned only AFTER `AfterExportAction.perform`) is itself the evidence the action fired.
        defaults.set(AfterExportAction.doNothing.rawValue, forKey: SettingsKeys.afterExportAction)

        let dir = FixtureDir()
        let source = dir.url("Report.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: source)   // the original, must survive intact
        let produced = try PDFFixtures.pdfData(markers: [PDFFixtures.marker(1), PDFFixtures.marker(2), PDFFixtures.marker(3)])
        let toolTitle = "RouteBesideTest-\(UUID().uuidString)"

        let outcome = try await PDFExportCoordinator.route(
            data: produced, source: source, toolTitle: toolTitle, defaultStem: "unused",
            suffixWord: "rotated", defaults: defaults
        )

        // Landed beside the source under the suffixed name, not handed back for a save dialog.
        guard case .savedBeside(let url) = outcome else {
            Issue.record("expected .savedBeside, got \(outcome)")
            return
        }
        let expected = dir.url("Report-rotated.pdf")
        #expect(url == expected)
        #expect(FileManager.default.fileExists(atPath: expected.path))
        // A valid, openable PDF carrying the produced data's three pages — not the 1-page source.
        #expect(try PDFFixtures.pageCount(at: expected) == 3)
        #expect(try PDFFixtures.pageCount(at: source) == 1)   // original untouched beside it

        // The save was recorded as one INFO line carrying the destination path and this tool's title.
        let entry = try #require(await waitForSharedEntry(prefix: toolTitle), "no log record for the beside-original save")
        #expect(entry.level == .info)
        #expect(entry.path == expected.path)
    }

    /// The no-suffix face of the same branch: with the filename-suffix setting off, the output name
    /// equals the source's own name, so `uniqueURL` numbers it rather than overwriting the original.
    @MainActor
    @Test func routeSavesBesideOriginalNumbersTheOutputWhenSuffixIsOff() async throws {
        let suiteName = "PDFExportCoordinatorTests-beside-nosuffix-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(SaveLocation.besideOriginal.rawValue, forKey: SettingsKeys.saveLocation)
        defaults.set(false, forKey: SettingsKeys.appendFilenameSuffix)
        defaults.set(AfterExportAction.doNothing.rawValue, forKey: SettingsKeys.afterExportAction)

        let dir = FixtureDir()
        let source = dir.url("Report.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: source)
        let produced = try PDFFixtures.pdfData(markers: [PDFFixtures.marker(1), PDFFixtures.marker(2)])
        let toolTitle = "RouteBesideNoSuffix-\(UUID().uuidString)"

        let outcome = try await PDFExportCoordinator.route(
            data: produced, source: source, toolTitle: toolTitle, defaultStem: "unused",
            suffixWord: "rotated", defaults: defaults
        )

        // No suffix → the bare name clashes with the source, so it's numbered, never overwriting it.
        guard case .savedBeside(let url) = outcome else {
            Issue.record("expected .savedBeside, got \(outcome)")
            return
        }
        let expected = dir.url("Report 2.pdf")
        #expect(url == expected)
        #expect(try PDFFixtures.pageCount(at: expected) == 2)
        #expect(try PDFFixtures.pageCount(at: source) == 1)   // original preserved

        let entry = try #require(await waitForSharedEntry(prefix: toolTitle))
        #expect(entry.level == .info)
        #expect(entry.path == expected.path)
    }
}
