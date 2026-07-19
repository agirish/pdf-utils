import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// Watermark stamps text onto every page while keeping the underlying page as vector content, so
/// its text stays selectable. Tests pin the required-text guard, page-count preservation, the
/// vector-preservation guarantee, both layout modes, and that an intrinsically rotated page is
/// emitted upright.
@Suite struct PDFToolkitWatermarkTests {

    private func options(_ text: String, tiled: Bool = false) -> WatermarkOptions {
        WatermarkOptions(
            text: text, fontSize: 48, opacity: 0.3, rotationDegrees: 45,
            red: 0.8, green: 0.1, blue: 0.1, tiled: tiled
        )
    }

    @Test func emptyOrWhitespaceTextThrowsWatermarkTextRequired() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        for text in ["", "   \n\t "] {
            #expect(#expect(throws: PDFOperationError.self) {
                try PDFToolkit.watermark(inputURL: src, outputURL: dir.url("out.pdf"), options: options(text))
            }?.kind == "watermarkTextRequired")
        }
    }

    @Test func preservesPageCount() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        #expect(try PDFFixtures.pageCount(at: out) == 3)
    }

    @Test func underlyingTextStaysSelectable() throws {
        // The page is copied as vector content (drawPDFPage), not rasterized — so the original
        // marker text is still extractable from the watermarked output.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("CONFIDENTIAL"))

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains("MARKERPAGE1"))
    }

    @Test func bothTiledAndCenteredLayoutsProduceOutput() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        let centered = dir.url("centered.pdf"), tiled = dir.url("tiled.pdf")
        try PDFToolkit.watermark(inputURL: src, outputURL: centered, options: options("X", tiled: false))
        try PDFToolkit.watermark(inputURL: src, outputURL: tiled, options: options("X", tiled: true))

        #expect(try PDFFixtures.pageCount(at: centered) == 1)
        #expect(try PDFFixtures.pageCount(at: tiled) == 1)
    }

    @Test func handlesAnIntrinsicallyRotatedPageInput() throws {
        // A page with baked-in 90° rotation exercises the watermark renderer's displayed-size /
        // drawing-transform branch. It must still produce a valid, openable single page with the
        // original text preserved (vector copy) — without crashing on the rotated geometry.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ROTATED"], rotations: [0: 90], to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 1)
        #expect(texts[0].contains("ROTATED"))
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.watermark(inputURL: bad, outputURL: dir.url("out.pdf"), options: options("DRAFT"))
        }?.kind == "couldNotOpen")
    }

    @Test func visibleAnnotationsSurviveWatermarking() throws {
        // The watermark rebuild replays only the content stream via `drawPDFPage`, so annotation
        // appearances (form values, signatures, notes) silently vanished. They are now flattened
        // into the emitted page.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        let annotationRect = CGRect(x: 300, y: 300, width: 80, height: 60)
        try PDFFixtures.writePDF(markers: ["ONLY"], greenSquareOnFirstPage: annotationRect, to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        let brightness = try PDFFixtures.brightnessSampler(at: out)
        #expect(brightness(340, 330) < 0.8)   // green square present, not blank white
    }

    @Test func keepsTheSourcePageSizeInsteadOfDefaultingToUSLetter() throws {
        // beginPDFPage's media-box value must be CFData wrapping the CGRect; the bridged CGRect it
        // was fed before is silently ignored, so EVERY watermarked page came out 612x792 — an A4's
        // top 50pt of content simply fell off the page.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        let a4 = CGSize(width: 595, height: 842)
        // Marker text sits at y = height/2 = 421; also prove the page is truly A4-sized.
        try PDFFixtures.writePDF(markers: ["ONLY"], size: a4, to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        #expect(try PDFFixtures.pageSize(at: out) == a4)
        let glyphs = PDFFixtures.darkestSample(
            try PDFFixtures.brightnessSampler(at: out),
            xRange: stride(from: 74, through: 160, by: 2), yValues: [425, 429, 433]
        )
        #expect(glyphs < 0.6)
    }

    @Test func aCroppedPageEmitsItsVisibleSize() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            markers: ["ONLY"],
            cropFirstPageTo: CGRect(x: 50, y: 50, width: 500, height: 600),
            greenSquareOnFirstPage: CGRect(x: 300, y: 300, width: 80, height: 60), to: src
        )

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 500, height: 600))
        let brightness = try PDFFixtures.brightnessSampler(at: out)
        #expect(brightness(310, 290) < 0.8)   // annotation shifted by the crop origin exactly once
    }
}
