import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PdfToolkit

/// Geometry of the Crop operation: displayed-edge insets land on the correct stored edges under
/// every intrinsic rotation, existing (non-zero-origin) crop boxes compose, auto-detect wraps the
/// rendered content, and degenerate crops are refused.
@Suite struct PDFToolkitCropTests {

    private func cropBox(at url: URL, page index: Int = 0) throws -> CGRect {
        let doc = try #require(PDFDocument(url: url))
        return try #require(doc.page(at: index)).bounds(for: .cropBox)
    }

    // MARK: insetRect geometry (pure)

    @Test func insetsMapToStoredEdgesUnderEveryRotation() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 400)
        let insets = CropInsets(top: 1, left: 2, bottom: 3, right: 4)

        // rotation 0: what you see is what is stored.
        #expect(PDFToolkit.insetRect(rect, rotation: 0, by: insets)
                == CGRect(x: 12, y: 23, width: 294, height: 396))
        // rotation 90 (stored left edge shows on top): top→minX, right→maxY, bottom→maxX, left→minY.
        #expect(PDFToolkit.insetRect(rect, rotation: 90, by: insets)
                == CGRect(x: 11, y: 22, width: 296, height: 394))
        // rotation 180 (upside down): top→minY, right→minX, bottom→maxY, left→maxX.
        #expect(PDFToolkit.insetRect(rect, rotation: 180, by: insets)
                == CGRect(x: 14, y: 21, width: 294, height: 396))
        // rotation 270 (stored right edge shows on top): top→maxX, right→minY, bottom→minX, left→maxY.
        #expect(PDFToolkit.insetRect(rect, rotation: 270, by: insets)
                == CGRect(x: 13, y: 24, width: 296, height: 394))
        // Negative rotations normalize (-90 ≡ 270).
        #expect(PDFToolkit.insetRect(rect, rotation: -90, by: insets)
                == PDFToolkit.insetRect(rect, rotation: 270, by: insets))
    }

    // MARK: crop()

    @Test func cropInsetsEveryPagesBox() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        let out = dir.url("out.pdf")

        try PDFToolkit.crop(
            inputURL: src,
            outputURL: out,
            insets: CropInsets(top: 10, left: 20, bottom: 30, right: 40)
        )

        // Letter is 612×792 with origin 0,0.
        let expected = CGRect(x: 20, y: 30, width: 612 - 20 - 40, height: 792 - 10 - 30)
        #expect(try cropBox(at: out, page: 0) == expected)
        #expect(try cropBox(at: out, page: 1) == expected)
        #expect(try PDFFixtures.pageTexts(at: out) == PDFFixtures.pageTexts(at: src))
    }

    @Test func cropComposesWithAnExistingNonZeroOriginCropBox() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        // First page already cropped to a box that does not start at the origin.
        try PDFFixtures.writePDF(
            markers: [PDFFixtures.marker(1)],
            cropFirstPageTo: CGRect(x: 50, y: 60, width: 400, height: 500),
            to: src
        )
        let out = dir.url("out.pdf")

        try PDFToolkit.crop(
            inputURL: src,
            outputURL: out,
            insets: CropInsets(top: 5, left: 6, bottom: 7, right: 8)
        )

        // Insets apply to the *current* crop box, not the media box.
        #expect(try cropBox(at: out) == CGRect(x: 56, y: 67, width: 400 - 6 - 8, height: 500 - 5 - 7))
    }

    @Test func cropHonorsIntrinsicRotationOnStoredEdges() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        // One page rotated 90°: the viewer's "top" is the stored minX edge.
        try PDFFixtures.writePDF(markers: [PDFFixtures.marker(1)], rotations: [0: 90], to: src)
        let out = dir.url("out.pdf")

        try PDFToolkit.crop(inputURL: src, outputURL: out, insets: CropInsets(top: 50))

        #expect(try cropBox(at: out) == CGRect(x: 50, y: 0, width: 612 - 50, height: 792))
        // And the rotation itself survives the copy.
        let doc = try #require(PDFDocument(url: out))
        #expect(try #require(doc.page(at: 0)).rotation == 90)
    }

    @Test func degenerateCropThrowsWithThePageNumber() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.crop(
                inputURL: src,
                outputURL: dir.url("out.pdf"),
                insets: CropInsets(top: 400, bottom: 400)
            )
        }
        #expect(error?.kind == "cropTooSmall")
        if case .cropTooSmall(let page) = error { #expect(page == 1) }
    }

    // MARK: autoCrop()

    @Test func autoCropWrapsTheRenderedContent() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        // One marker line drawn at x=72, baseline y=396, ~24 pt glyphs on a 612×792 page.
        try PDFFixtures.writePDF(markers: [PDFFixtures.marker(1)], to: src)
        let out = dir.url("out.pdf")

        try PDFToolkit.autoCrop(inputURL: src, outputURL: out, padding: 10, unified: false)

        let box = try cropBox(at: out)
        // The box must contain the text region…
        #expect(box.minX <= 72)
        #expect(box.minY <= 396)
        #expect(box.maxY >= 396 + 17)   // cap height of 24 pt system font
        // …and be a dramatic tightening of the full page, top and bottom margins gone.
        #expect(box.height < 120)
        #expect(box.width < 400)
        // The marker text still extracts from the cropped file.
        #expect(try PDFFixtures.pageTexts(at: out) == [PDFFixtures.marker(1)])
    }

    @Test func unifiedAutoCropAppliesOneTrimEverywhere() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: [PDFFixtures.marker(1), PDFFixtures.marker(2)], to: src)
        let out = dir.url("out.pdf")

        try PDFToolkit.autoCrop(inputURL: src, outputURL: out, padding: 10, unified: true)

        let first = try cropBox(at: out, page: 0)
        let second = try cropBox(at: out, page: 1)
        #expect(first == second)
        #expect(first.height < 120)
    }

    @Test func autoCropRefusesToWriteOverTheInput() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.autoCrop(inputURL: src, outputURL: src, padding: 10, unified: true)
        }
        #expect(error?.kind == "outputMatchesInput")
    }
}
