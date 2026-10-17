import Foundation
import PDFKit
import PDFToolkitCore
import Testing
@testable import PdfToolkit

/// Read/write behavior of the Clean Metadata operation: fields round-trip, blank fields disappear,
/// stripping produces a file with no identifying info, and encrypted files are refused whole.
@Suite struct PDFToolkitMetadataTests {

    /// Writes a 2-page fixture whose info dictionary is populated, returns its URL.
    ///
    /// Written to a *fresh* path — `PDFDocument.write(to:)` back onto the file the document lazily
    /// reads from is unreliable (it intermittently fails outright). And note PDFKit stamps its own
    /// Producer and both dates on every write, so those three carry system values here, not ours.
    private func writePopulatedFixture(in dir: FixtureDir) throws -> URL {
        let base = dir.url.appendingPathComponent("base.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: base)
        guard let doc = PDFDocument(url: base) else {
            throw PDFOperationError.couldNotOpen(base)
        }
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Q3 Review",
            PDFDocumentAttribute.authorAttribute: "A. Person",
            PDFDocumentAttribute.subjectAttribute: "Finance",
            PDFDocumentAttribute.keywordsAttribute: ["internal", "draft"],
            PDFDocumentAttribute.creatorAttribute: "Word 16.89",
        ]
        let url = dir.url.appendingPathComponent("populated.pdf")
        #expect(doc.write(to: url))
        return url
    }

    /// The same guarantee one level up, at the export hook the batch runner actually calls.
    @Test func exportCoordinatorMetadataStripKeepsBookmarks() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf")
        try PDFFixtures.writePDF(pageCount: 3, bookmarks: [("Intro", 0), ("End", 2)], to: base)

        let out = try #require(PDFDocument(data: PDFExportCoordinator.stripMetadata(try Data(contentsOf: base))))
        let indices: [Int] = (0..<(out.outlineRoot?.numberOfChildren ?? 0)).map { i in
            guard let page = out.outlineRoot?.child(at: i)?.destination?.page else { return -1 }
            let raw = out.index(for: page)
            return raw == NSNotFound ? -1 : raw
        }
        #expect(indices == [0, 2])
    }
}
