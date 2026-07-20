import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PdfToolkit

/// End-to-end behavior of the OCR operation against real Vision recognition: a rasterized (image-
/// only) page becomes searchable, the text layer lands where the printed words are, pages with
/// live text are skipped, and progress/cancellation plumbing works.
@Suite struct PDFToolkitOCRTests {

    /// A scanned-style fixture: real text rendered to a page, then rebuilt as an image-only PDF via
    /// the compress path — after which PDFKit extracts no text from it.
    private func writeScannedFixture(marker: String, in dir: FixtureDir) throws -> URL {
        let vector = dir.url("vector.pdf")
        try PDFFixtures.writePDF(markers: [marker], to: vector)
        let scanned = dir.url("scanned.pdf")
        try PDFToolkit.compress(inputURL: vector, outputURL: scanned, quality: 1.0)
        #expect(try PDFFixtures.pageTexts(at: scanned) == [""], "fixture must start with no text layer")
        return scanned
    }

    @Test func rasterizedPageBecomesSearchable() throws {
        let dir = FixtureDir()
        let scanned = try writeScannedFixture(marker: "MARKERPAGE1", in: dir)
        let out = dir.url("searchable.pdf")

        let summary = try PDFToolkit.ocr(
            inputURL: scanned,
            outputURL: out,
            options: OCROptions(accurate: true, skipPagesWithText: true)
        )

        #expect(summary.recognizedPages == 1)
        #expect(summary.skippedPages == 0)
        let text = try PDFFixtures.pageTexts(at: out).joined(separator: " ").uppercased()
        #expect(text.contains("MARKERPAGE1"), "recognized text must extract from the output, got: \(text)")
    }

    @Test func textLayerLandsWhereThePrintedWordsAre() throws {
        let dir = FixtureDir()
        // The fixture draws its marker at x=72 with baseline at mid-page (y=396) in 24 pt type.
        let scanned = try writeScannedFixture(marker: "MARKERPAGE1", in: dir)
        let out = dir.url("searchable.pdf")

        _ = try PDFToolkit.ocr(inputURL: scanned, outputURL: out, options: OCROptions())

        let doc = try #require(PDFDocument(url: out))
        let selections = doc.findString("MARKERPAGE1", withOptions: .caseInsensitive)
        let selection = try #require(selections.first, "the invisible layer must be findable")
        let page = try #require(selection.pages.first)
        let bounds = selection.bounds(for: page)
        // The compress rebuild keeps page geometry (612×792), so the recognized line must sit at
        // the drawn text's position — generous tolerances absorb raster/recognition wobble.
        #expect(abs(bounds.minX - 72) < 30, "x position off: \(bounds)")
        #expect(abs(bounds.midY - 404) < 30, "y position off: \(bounds)")
        #expect(bounds.width > 80, "selection should span the word: \(bounds)")
    }

    @Test func pagesWithLiveTextAreSkippedUntouched() throws {
        let dir = FixtureDir()
        let vector = dir.url("vector.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: vector)
        let out = dir.url("out.pdf")

        let summary = try PDFToolkit.ocr(
            inputURL: vector,
            outputURL: out,
            options: OCROptions(accurate: false, skipPagesWithText: true)
        )

        #expect(summary.recognizedPages == 0)
        #expect(summary.skippedPages == 2)
        // The vector text still extracts after the rebuild.
        #expect(try PDFFixtures.pageTexts(at: out) == ["MARKERPAGE1", "MARKERPAGE2"])
    }

    @Test func progressReportsEveryPageInOrder() throws {
        let dir = FixtureDir()
        let vector = dir.url("vector.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: vector)
        let out = dir.url("out.pdf")

        final class Progress: @unchecked Sendable {
            var pages: [Int] = []
            var totals: Set<Int> = []
        }
        let seen = Progress()
        _ = try PDFToolkit.ocr(
            inputURL: vector,
            outputURL: out,
            options: OCROptions(skipPagesWithText: true),
            progress: { page, total in
                seen.pages.append(page)
                seen.totals.insert(total)
            }
        )
        #expect(seen.pages == [1, 2, 3])
        #expect(seen.totals == [3])
    }

    @Test func cancellationAbortsBetweenPages() throws {
        let dir = FixtureDir()
        let vector = dir.url("vector.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: vector)

        #expect(throws: CancellationError.self) {
            _ = try PDFToolkit.ocr(
                inputURL: vector,
                outputURL: dir.url("out.pdf"),
                options: OCROptions(),
                isCancelled: { true }
            )
        }
    }

    @Test func corruptInputThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)

        let error = #expect(throws: PDFOperationError.self) {
            _ = try PDFToolkit.ocr(inputURL: bad, outputURL: dir.url("out.pdf"), options: OCROptions())
        }
        #expect(error?.kind == "couldNotOpen")
    }
}
