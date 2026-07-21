import Testing
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
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

    // MARK: - Page scope

    /// The darkest sample over a grid straddling the page center (306, 396 on US Letter), where a
    /// centered watermark lands but the left-edge fixture marker never reaches — so it tells a
    /// stamped page apart from an untouched (white-center) one.
    private func centerDarkest(_ sampler: (CGFloat, CGFloat) -> CGFloat) -> CGFloat {
        PDFFixtures.darkestSample(
            sampler,
            xRange: stride(from: 262, through: 350, by: 4),
            yValues: [372, 384, 396, 408, 420]
        )
    }

    /// An opaque, near-black, horizontal mark — its center pixels read clearly dark (< 0.5), so a
    /// scope test can assert stamped-vs-untouched without the faint default (30% red) confusing the
    /// threshold.
    private func opaqueOptions(_ text: String) -> WatermarkOptions {
        WatermarkOptions(
            text: text, fontSize: 60, opacity: 1.0, rotationDegrees: 0,
            red: 0.05, green: 0.05, blue: 0.05, tiled: false
        )
    }

    @Test func firstPageOnlyStampsOnlyTheFirstPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        var opts = opaqueOptions("DRAFT")
        opts.pageScope = .firstPageOnly
        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: opts)

        #expect(try PDFFixtures.pageCount(at: out) == 2)                 // every page still emitted
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 0)) < 0.5)   // stamped
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 1)) > 0.95)  // untouched
    }

    @Test func customRangeStampsOnlyListedPages() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        var opts = opaqueOptions("DRAFT")
        opts.pageScope = .custom("2")   // one-based → page index 1 only
        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: opts)

        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 0)) > 0.95)  // untouched
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 1)) < 0.5)   // stamped
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 2)) > 0.95)  // untouched
    }

    @Test func customRangeEmptyThrowsPageRangeRequired() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        var opts = options("DRAFT")
        opts.pageScope = .custom("   ")
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.watermark(inputURL: src, outputURL: dir.url("out.pdf"), options: opts)
        }?.kind == "pageRangeRequired")
    }

    @Test func customRangeBeyondTheDocumentThrowsPageOutOfBounds() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        var opts = options("DRAFT")
        opts.pageScope = .custom("5")
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.watermark(inputURL: src, outputURL: dir.url("out.pdf"), options: opts)
        }?.kind == "pageOutOfBounds")
    }

    // MARK: - Font

    @Test func watermarkFontResolvesAChosenFamilyAndFallsBackSafely() {
        #expect(PDFToolkit.watermarkFont(named: nil, size: 20).pointSize == 20)                 // default
        #expect(PDFToolkit.watermarkFont(named: "Helvetica", size: 20).familyName == "Helvetica")
        // An unknown family must not vanish the stamp — it falls back to a valid font.
        #expect(PDFToolkit.watermarkFont(named: "NoSuchFontFamily__42", size: 20).pointSize == 20)
    }

    @Test func aChosenFontStillProducesAValidWatermarkedPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)
        var opts = opaqueOptions("DRAFT")
        opts.fontName = "Times New Roman"
        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: opts)
        #expect(try PDFFixtures.pageTexts(at: out)[0].contains("MARKERPAGE1"))   // underlying text intact
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out)) < 0.5) // stamp rendered
    }

    // MARK: - Image watermark

    /// Builds `WatermarkOptions` for the image branch (no text) with the given placement.
    private func imageOptions(
        _ image: WatermarkImage, opacity: CGFloat, scale: CGFloat, rotation: CGFloat = 0, tiled: Bool = false
    ) -> WatermarkOptions {
        WatermarkOptions(
            text: "", fontSize: 48, opacity: opacity, rotationDegrees: rotation,
            red: 0, green: 0, blue: 0, tiled: tiled,
            content: .image, image: image, imageScale: scale
        )
    }

    /// Writes a square PNG whose left half is opaque red and right half fully transparent — so a
    /// stamped copy can prove both that the logo lands AND that its transparency composites (the
    /// transparent half must let the page show through, not paint an opaque box).
    private func writeHalfTransparentPNG(to url: URL, side: Int = 100) throws {
        let ctx = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))   // left half opaque, right stays clear
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func missingImageThrowsWatermarkImageRequired() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        var opts = options("ignored")
        opts.content = .image
        opts.image = nil
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.watermark(inputURL: src, outputURL: dir.url("out.pdf"), options: opts)
        }?.kind == "watermarkImageRequired")
    }

    @Test func imageWatermarkStampsAndKeepsPNGTransparency() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf"), logo = dir.url("logo.png")
        try PDFFixtures.writePDF(pageCount: 1, to: src)   // white US-Letter page
        try writeHalfTransparentPNG(to: logo)

        let decoded = try #require(PDFToolkit.watermarkImageSource(at: logo))
        // The decode preserved an alpha channel (the whole point of the transparency support).
        let alpha = decoded.cgImage.alphaInfo
        #expect(alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: imageOptions(decoded, opacity: 1, scale: 0.5))

        // Centered 100×100 logo scaled ×3.06 → ~306pt square about (306, 396): red half ~x∈[153,306],
        // transparent half ~x∈[306,459].
        let b = try PDFFixtures.brightnessSampler(at: out)
        #expect(b(280, 396) < 0.8)   // opaque red half stamped
        #expect(b(400, 396) > 0.9)   // transparent half let the white page through
    }

    @Test func imageWatermarkRespectsOpacity() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), logo = dir.url("logo.png")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        try writeHalfTransparentPNG(to: logo)
        let decoded = try #require(PDFToolkit.watermarkImageSource(at: logo))

        let full = dir.url("full.pdf"), faint = dir.url("faint.pdf")
        try PDFToolkit.watermark(inputURL: src, outputURL: full, options: imageOptions(decoded, opacity: 1.0, scale: 0.5))
        try PDFToolkit.watermark(inputURL: src, outputURL: faint, options: imageOptions(decoded, opacity: 0.3, scale: 0.5))

        let solid = try PDFFixtures.brightnessSampler(at: full)(280, 396)
        let lighter = try PDFFixtures.brightnessSampler(at: faint)(280, 396)
        #expect(lighter > solid)   // lower opacity over white reads lighter
    }

    @Test func imageWatermarkOnlyMarksPagesInScope() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf"), logo = dir.url("logo.png")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        try writeHalfTransparentPNG(to: logo)
        let decoded = try #require(PDFToolkit.watermarkImageSource(at: logo))

        var opts = imageOptions(decoded, opacity: 1, scale: 0.5)
        opts.pageScope = .firstPageOnly
        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: opts)

        #expect(try PDFFixtures.brightnessSampler(at: out, page: 0)(280, 396) < 0.8)   // stamped
        #expect(try PDFFixtures.brightnessSampler(at: out, page: 1)(280, 396) > 0.95)  // untouched
    }
}
