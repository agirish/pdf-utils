import AppKit
import Foundation
import PDFKit
import Testing
@testable import PdfToolkit

/// The page-for-page rebuild operations (Watermark, OCR, Fill & Sign, Compress, Redact) emit their
/// result through a `CGPDFContext`, which knows only about pages — so everything on the PDF catalog
/// used to be lost: a source with 3 bookmarks came back with 0, the Title/Author were gone, and
/// every hyperlink was dead. These pin the catalog across each rebuild.
struct PDFToolkitCatalogRestoreTests {
    private static let bookmarkLabels = ["Chapter 1", "Chapter 2", "Chapter 3"]

    /// A 3-page PDF carrying 3 bookmarks, a Title/Author, an external link on page 1 and an
    /// internal link on page 2 pointing at page 3.
    private func richPDF(in dir: FixtureDir) throws -> URL {
        // Built from a plain fixture and written to a DIFFERENT path: a `PDFDocument` reads its
        // pages lazily, so writing back over its own source file fails (the same hazard
        // `requireDistinctOutput` exists to catch in production).
        let plain = dir.url("plain-source.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: plain)
        let url = dir.url("rich.pdf")
        let doc = try #require(PDFDocument(url: plain))

        let root = PDFOutline()
        for (i, label) in Self.bookmarkLabels.enumerated() {
            let child = PDFOutline()
            child.label = label
            child.destination = PDFDestination(page: try #require(doc.page(at: i)), at: CGPoint(x: 0, y: 700))
            root.insertChild(child, at: root.numberOfChildren)
        }
        doc.outlineRoot = root
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Quarterly Report",
            PDFDocumentAttribute.authorAttribute: "Finance",
        ]

        let external = PDFAnnotation(bounds: CGRect(x: 72, y: 300, width: 200, height: 20),
                                     forType: .link, withProperties: nil)
        external.url = URL(string: "https://example.com/report")
        doc.page(at: 0)?.addAnnotation(external)

        let internalLink = PDFAnnotation(bounds: CGRect(x: 72, y: 250, width: 160, height: 20),
                                         forType: .link, withProperties: nil)
        internalLink.action = PDFActionGoTo(
            destination: PDFDestination(page: try #require(doc.page(at: 2)), at: CGPoint(x: 0, y: 500))
        )
        doc.page(at: 1)?.addAnnotation(internalLink)

        try #require(doc.write(to: url))
        return url
    }

    private func bookmarkLabels(_ doc: PDFDocument) -> [String] {
        guard let root = doc.outlineRoot else { return [] }
        return (0..<root.numberOfChildren).compactMap { root.child(at: $0)?.label }
    }

    private func linkCount(_ doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { total, i in
            total + (doc.page(at: i)?.annotations.filter { $0.type == "Link" }.count ?? 0)
        }
    }

    // MARK: Bookmarks + info dictionary survive every rebuild

    @Test(arguments: ["watermark", "compress", "ocr", "fillsign", "redact"])
    func rebuildKeepsBookmarksAndTitle(_ operation: String) throws {
        let dir = FixtureDir()
        let url = try richPDF(in: dir)

        let data: Data
        switch operation {
        case "watermark":
            var options = WatermarkOptions(text: "DRAFT", fontSize: 40, opacity: 0.3,
                                           rotationDegrees: 45, red: 1, green: 0, blue: 0, tiled: false)
            options.pageScope = .all
            data = try PDFToolkit.watermarkData(inputURL: url, options: options)
        case "compress":
            data = try PDFToolkit.compressData(inputURL: url, quality: 0.7)
        case "ocr":
            data = try PDFToolkit.ocrData(inputURL: url, options: OCROptions()).0
        case "fillsign":
            let item = FillSignItem(
                pageIndex: 0, rect: CGRect(x: 100, y: 100, width: 120, height: 30),
                content: .text(FillSignText(string: "signed", fontSize: 14, red: 0, green: 0, blue: 0))
            )
            data = try PDFToolkit.fillAndSignData(inputURL: url, items: [item])
        default:
            data = try PDFToolkit.redactData(
                inputURL: url,
                marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 60, y: 380, width: 300, height: 50))]
            )
        }

        let out = try #require(PDFDocument(data: data))
        #expect(out.pageCount == 3)
        #expect(bookmarkLabels(out) == Self.bookmarkLabels, "\(operation) lost the outline")
        #expect(out.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Quarterly Report",
                "\(operation) lost the document title")
    }

    /// Each restored bookmark must still resolve to its own page, not collapse onto page 1.
    @Test func restoredBookmarksPointAtTheRightPages() throws {
        let dir = FixtureDir()
        let url = try richPDF(in: dir)
        var options = WatermarkOptions(text: "DRAFT", fontSize: 40, opacity: 0.3,
                                       rotationDegrees: 0, red: 1, green: 0, blue: 0, tiled: false)
        options.pageScope = .all
        let out = try #require(PDFDocument(data: try PDFToolkit.watermarkData(inputURL: url, options: options)))
        let root = try #require(out.outlineRoot)
        for i in 0..<root.numberOfChildren {
            let page = try #require(root.child(at: i)?.destination?.page)
            #expect(out.index(for: page) == i)
        }
    }

    // MARK: Links

    @Test(arguments: ["watermark", "compress", "ocr", "fillsign"])
    func rebuildKeepsWorkingLinks(_ operation: String) throws {
        let dir = FixtureDir()
        let url = try richPDF(in: dir)

        let data: Data
        switch operation {
        case "watermark":
            var options = WatermarkOptions(text: "DRAFT", fontSize: 40, opacity: 0.3,
                                           rotationDegrees: 0, red: 1, green: 0, blue: 0, tiled: false)
            options.pageScope = .all
            data = try PDFToolkit.watermarkData(inputURL: url, options: options)
        case "compress":
            data = try PDFToolkit.compressData(inputURL: url, quality: 0.7)
        case "ocr":
            data = try PDFToolkit.ocrData(inputURL: url, options: OCROptions()).0
        default:
            let item = FillSignItem(
                pageIndex: 0, rect: CGRect(x: 100, y: 100, width: 120, height: 30),
                content: .text(FillSignText(string: "signed", fontSize: 14, red: 0, green: 0, blue: 0))
            )
            data = try PDFToolkit.fillAndSignData(inputURL: url, items: [item])
        }

        let out = try #require(PDFDocument(data: data))
        #expect(linkCount(out) == 2, "\(operation) lost link annotations")

        let external = try #require(out.page(at: 0)?.annotations.first { $0.type == "Link" })
        #expect(external.url?.absoluteString == "https://example.com/report")

        let internalLink = try #require(out.page(at: 1)?.annotations.first { $0.type == "Link" })
        let target = internalLink.destination ?? (internalLink.action as? PDFActionGoTo)?.destination
        #expect(out.index(for: try #require(target?.page)) == 2)
    }

    /// Redaction is the exception: no link is *restored* onto a rasterized page, because a link's URL
    /// can itself disclose the value the user painted over and a live hotspot over a burned-in black
    /// box is recoverable content. Pages with no marks are plain page copies, so they legitimately
    /// keep their own links — nothing was redacted there. Bookmarks survive either way.
    @Test func redactionDropsLinksOnRedactedPagesOnly() throws {
        let dir = FixtureDir()
        let url = try richPDF(in: dir)
        let out = try #require(PDFDocument(data: try PDFToolkit.redactData(
            inputURL: url,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 60, y: 380, width: 300, height: 50))]
        )))
        // Page 1 was rasterized: its external link is gone and is not put back.
        #expect(out.page(at: 0)?.annotations.filter { $0.type == "Link" }.isEmpty == true)
        // Page 2 carried no marks, so it is copied whole — its internal link is untouched.
        #expect(out.page(at: 1)?.annotations.filter { $0.type == "Link" }.count == 1)
        #expect(bookmarkLabels(out) == Self.bookmarkLabels)
        // And the redaction itself still did its job.
        #expect((out.page(at: 0)?.string ?? "").contains(PDFFixtures.marker(1)) == false)
        #expect(out.page(at: 1)?.string?.contains(PDFFixtures.marker(2)) == true)
    }

    // MARK: Fast path

    /// A plain document with nothing on its catalog must skip the restore pass entirely — the
    /// Compress target sweep pays this once per quality rung.
    @Test func plainDocumentSkipsTheRestorePass() throws {
        let dir = FixtureDir()
        let url = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: url)
        let source = try #require(PDFDocument(url: url))
        let produced = try PDFToolkit.compressData(inputURL: url, quality: 0.7)
        #expect(PDFToolkit.restoringCatalog(produced, from: source, restoreLinks: true) == produced)
    }

    /// A rebuild whose page count doesn't match the source is left alone rather than mangled.
    @Test func mismatchedPageCountLeavesTheOutputUntouched() throws {
        let dir = FixtureDir()
        let source = try #require(PDFDocument(url: try richPDF(in: dir)))
        let other = dir.url("other.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: other)
        let produced = try Data(contentsOf: other)
        #expect(PDFToolkit.restoringCatalog(produced, from: source, restoreLinks: true) == produced)
    }
}
