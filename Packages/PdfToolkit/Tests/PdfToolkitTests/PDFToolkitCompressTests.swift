import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// Compress rebuilds every page as a bitmap wrapped in a new PDF — shrinking scans at the cost of
/// selectable text. Tests pin that the page count survives, that pages come out rasterized (text no
/// longer extractable, intrinsic rotation baked flat), and that extreme quality values are clamped
/// rather than crashing.
@Suite struct PDFToolkitCompressTests {

    @Test func preservesPageCount() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        try PDFToolkit.compress(inputURL: src, outputURL: out, quality: 0.5)

        #expect(try PDFFixtures.pageCount(at: out) == 3)
    }

    @Test func rasterizesPagesSoTextIsNoLongerSelectable() throws {
        // Each page becomes an image, so the marker text can't be extracted from the output.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)

        try PDFToolkit.compress(inputURL: src, outputURL: out, quality: 0.5)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(!texts[0].contains("MARKERPAGE1"))
    }

    @Test func bakesIntrinsicRotationFlatIntoTheBitmap() throws {
        // The renderer draws the page upright, then the new image page is stored at rotation 0 —
        // re-applying the source rotation would double it.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONLY"], rotations: [0: 90], to: src)

        try PDFToolkit.compress(inputURL: src, outputURL: out, quality: 0.5)

        #expect(try PDFFixtures.pageRotations(at: out) == [0])
    }

    @Test func clampsQualityBelowAndAboveTheValidRange() throws {
        // quality 0 and quality 5 are clamped into [0.05, 1]; both produce a valid output.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        let low = dir.url("low.pdf"), high = dir.url("high.pdf")
        try PDFToolkit.compress(inputURL: src, outputURL: low, quality: 0)
        try PDFToolkit.compress(inputURL: src, outputURL: high, quality: 5)

        #expect(try PDFFixtures.pageCount(at: low) == 2)
        #expect(try PDFFixtures.pageCount(at: high) == 2)
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.compress(inputURL: bad, outputURL: dir.url("out.pdf"), quality: 0.5)
        }?.kind == "couldNotOpen")
    }
}
