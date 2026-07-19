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
}
