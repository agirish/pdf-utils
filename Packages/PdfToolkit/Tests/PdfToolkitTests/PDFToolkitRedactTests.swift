import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import PdfToolkit

/// Redaction rasterizes each marked page and paints solid black over the marked regions, so their
/// content can't be recovered; unmarked pages are copied as-is (optionally stripped of annotations).
/// Tests pin that marked text truly disappears, unmarked text survives, the page count holds, and
/// the guard/annotation paths behave.
@Suite struct PDFToolkitRedactTests {

    /// A lower raster ceiling than the 4000px default keeps the bitmap work fast in tests.
    private let fastOptions = PDFRedactionExportOptions(
        stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 800
    )

    /// The full media box of a source page, so a mark is guaranteed to cover its text.
    private func fullPageRect(_ url: URL, page: Int) throws -> CGRect {
        let doc = try #require(PDFDocument(url: url))
        return try #require(doc.page(at: page)).bounds(for: .mediaBox)
    }

    @Test func noMarksThrowsNoRedactions() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.redact(inputURL: src, outputURL: dir.url("out.pdf"), marks: [], options: fastOptions)
        }?.kind == "noRedactions")
    }

    @Test func markOnAMissingPageThrowsPageOutOfBounds() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let mark = RedactionMark(pageIndex: 5, rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.redact(inputURL: src, outputURL: dir.url("out.pdf"), marks: [mark], options: fastOptions)
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }

    @Test func markedPageLosesItsTextWhileUnmarkedPagesKeepTheirs() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["SECRET1", "PUBLIC2", "PUBLIC3"], to: src)

        // Cover the whole first page.
        let mark = RedactionMark(pageIndex: 0, rect: try fullPageRect(src, page: 0))
        try PDFToolkit.redact(inputURL: src, outputURL: out, marks: [mark], options: fastOptions)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 3)
        #expect(!texts[0].contains("SECRET1"))   // rasterized away
        #expect(texts[1].contains("PUBLIC2"))     // untouched
        #expect(texts[2].contains("PUBLIC3"))
    }

    @Test func stripAnnotationsRemovesThemFromUnredactedPages() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("annotated.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: base)
        // Add a note to the *unredacted* second page, writing the annotated copy to a distinct path
        // (writing a PDFDocument back to the file it was opened from is unreliable).
        let doc = try #require(PDFDocument(url: base))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .freeText, withProperties: nil
        )
        annotation.contents = "hidden note"
        try #require(doc.page(at: 1)).addAnnotation(annotation)
        #expect(doc.write(to: src))

        let mark = RedactionMark(pageIndex: 0, rect: try fullPageRect(src, page: 0))

        // Kept when the option is off.
        let kept = dir.url("kept.pdf")
        try PDFToolkit.redact(inputURL: src, outputURL: kept, marks: [mark],
                              options: PDFRedactionExportOptions(stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 800))
        #expect(try #require(PDFDocument(url: kept)).page(at: 1)?.annotations.isEmpty == false)

        // Stripped when the option is on.
        let stripped = dir.url("stripped.pdf")
        try PDFToolkit.redact(inputURL: src, outputURL: stripped, marks: [mark],
                              options: PDFRedactionExportOptions(stripAnnotationsFromUnredactedPages: true, maxPixelDimension: 800))
        #expect(try #require(PDFDocument(url: stripped)).page(at: 1)?.annotations.isEmpty == true)
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        let mark = RedactionMark(pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.redact(inputURL: bad, outputURL: dir.url("out.pdf"), marks: [mark], options: fastOptions)
        }?.kind == "couldNotOpen")
    }
}
