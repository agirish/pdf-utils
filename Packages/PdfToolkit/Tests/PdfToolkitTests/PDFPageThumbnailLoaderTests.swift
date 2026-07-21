import Testing
import Foundation
import PDFKit
@testable import PdfToolkit

/// Pins the preview-grid sizing math — pure, feeds every thumbnail grid in the app, and its
/// rotation handling shipped (twice) without a test. Empirically, `thumbnail(of:for:)` renders the
/// DISPLAYED orientation and aspect-fits: sized from the raw media box, a /Rotate 90 US Letter came
/// out ~309×238 (soft); sized from the displayed orientation it fills the intended 400 pt.
@Suite struct PDFPageThumbnailLoaderTests {

    /// The caller creates and holds the `FixtureDir` for the test body: a dir local to this helper
    /// deinits (deleting the backing file) the moment it returns, and the render tests then drew a
    /// document whose file was already unlinked — passing only via POSIX open-file semantics.
    private func makePage(in dir: FixtureDir, size: CGSize, rotation: Int) throws -> PDFPage {
        let url = dir.url("thumb.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], size: size, rotations: rotation == 0 ? [:] : [0: rotation], to: url)
        let doc = try #require(PDFDocument(url: url))
        return try #require(doc.page(at: 0))
    }

    @Test func unrotatedPortraitBoxKeepsAspectWithLongEdge400() throws {
        let dir = FixtureDir()
        let page = try makePage(in: dir, size: CGSize(width: 612, height: 792), rotation: 0)
        let box = PDFPageThumbnailLoader.thumbnailBox(for: page)
        #expect(abs(box.height - 400) < 1)
        #expect(abs(box.width - 612.0 / 792.0 * 400) < 1)
    }

    @Test func rotated90BoxIsLandscapeWithLongEdge400() throws {
        // The displayed page is landscape; the box must be too, or the render aspect-fits down to
        // the short side and the whole grid goes soft for scanned (rotated) documents.
        let dir = FixtureDir()
        let page = try makePage(in: dir, size: CGSize(width: 612, height: 792), rotation: 90)
        let box = PDFPageThumbnailLoader.thumbnailBox(for: page)
        #expect(box.width > box.height)
        #expect(abs(box.width - 400) < 1)
        // And the actual render fills that box's long edge instead of letterboxing inside it.
        let image = page.thumbnail(of: box, for: .mediaBox)
        #expect(image.size.width >= 395)
    }

    @Test func rotated270AndNegativeRotationsNormalize() throws {
        let dir = FixtureDir()
        let page = try makePage(in: dir, size: CGSize(width: 612, height: 792), rotation: 270)
        let box = PDFPageThumbnailLoader.thumbnailBox(for: page)
        #expect(box.width > box.height)

        page.rotation = -90   // normalizes to 270
        let negBox = PDFPageThumbnailLoader.thumbnailBox(for: page)
        #expect(negBox == box)
    }

    @Test func smallPagesAreNeverUpscaled() throws {
        let dir = FixtureDir()
        let page = try makePage(in: dir, size: CGSize(width: 200, height: 100), rotation: 0)
        let box = PDFPageThumbnailLoader.thumbnailBox(for: page)
        #expect(box == NSSize(width: 200, height: 100))
    }

    @Test func demandLoaderRefusesALockedDocument() async throws {
        // The gate lives in the loader itself — a locked document reports a real page count and
        // renders blanks, and three review rounds found call sites that missed a caller-side
        // check. Every preview grid inherits this refusal through `pageCount(of:)`, the entry
        // point each grid calls before any cell exists.
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf"), locked = dir.url("locked.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        try PDFToolkit.encrypt(inputURL: plain, outputURL: locked, password: "secret")

        let error = await #expect(throws: PDFOperationError.self) {
            _ = try await PDFPageThumbnailLoader.pageCount(of: locked)
        }
        #expect(error?.kind == "encryptedInput")
        // And an owner-restricted (encrypted but NOT locked) document still previews fine —
        // counting and demand-rendering its pages both pass the gate.
        let restricted = dir.url("restricted.pdf")
        try PDFFixtures.writeOwnerRestrictedPDF(markers: ["MARKERPAGE1"], to: restricted)
        let count = try await PDFPageThumbnailLoader.pageCount(of: restricted)
        #expect(count == 1)
        let thumb = try await PDFPageThumbnailLoader.loadPage(from: restricted, pageIndex: 0)
        #expect(thumb != nil)
    }
}
