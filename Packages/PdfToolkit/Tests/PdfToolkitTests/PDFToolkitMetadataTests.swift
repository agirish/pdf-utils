import Foundation
import PDFKit
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

    @Test func readsEveryStandardField() throws {
        let dir = FixtureDir()
        let url = try writePopulatedFixture(in: dir)

        let fields = try PDFToolkit.readMetadata(inputURL: url)
        #expect(fields.title == "Q3 Review")
        #expect(fields.author == "A. Person")
        #expect(fields.subject == "Finance")
        #expect(fields.keywords == "internal, draft")
        #expect(fields.creator == "Word 16.89")
        // PDFKit stamped these three on the fixture's own write.
        #expect(fields.producer.contains("Quartz"))
        #expect(fields.creationDate != nil)
        #expect(fields.modificationDate != nil)
        #expect(!fields.isCleared)
    }

    @Test func readsStringKeywordsFromLegacyProducers() throws {
        let dir = FixtureDir()
        let base = dir.url.appendingPathComponent("base.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: base)
        let doc = try #require(PDFDocument(url: base))
        // Some producers store keywords as one string rather than an array.
        doc.documentAttributes = [PDFDocumentAttribute.keywordsAttribute: "alpha, beta"]
        let url = dir.url.appendingPathComponent("legacy.pdf")
        #expect(doc.write(to: url))

        let fields = try PDFToolkit.readMetadata(inputURL: url)
        #expect(fields.keywords == "alpha, beta")
    }

    @Test func editedFieldsRoundTrip() throws {
        let dir = FixtureDir()
        let url = try writePopulatedFixture(in: dir)
        let out = dir.url.appendingPathComponent("edited.pdf")

        var fields = try PDFToolkit.readMetadata(inputURL: url)
        fields.title = "Renamed"
        fields.author = ""            // cleared → must vanish, not become ""
        fields.keywords = "one, two , three,"
        try PDFToolkit.writeMetadata(inputURL: url, outputURL: out, fields: fields)

        let reread = try PDFToolkit.readMetadata(inputURL: out)
        #expect(reread.title == "Renamed")
        #expect(reread.author.isEmpty)
        #expect(reread.keywords == "one, two, three")
        #expect(reread.creator == "Word 16.89")

        // The cleared author must be *absent* from the attributes, not present-but-empty.
        let attrs = try #require(PDFDocument(url: out)?.documentAttributes)
        #expect(attrs[PDFDocumentAttribute.authorAttribute] == nil)

        // Pages are untouched.
        #expect(try PDFFixtures.pageCount(at: out) == 2)
        #expect(try PDFFixtures.pageTexts(at: out) == PDFFixtures.pageTexts(at: url))
    }

    @Test func strippingClearsEveryIdentifyingField() throws {
        let dir = FixtureDir()
        let url = try writePopulatedFixture(in: dir)
        let out = dir.url.appendingPathComponent("stripped.pdf")

        try PDFToolkit.writeMetadata(inputURL: url, outputURL: out, fields: .cleared)

        let reread = try PDFToolkit.readMetadata(inputURL: out)
        #expect(reread.title.isEmpty)
        #expect(reread.author.isEmpty)
        #expect(reread.subject.isEmpty)
        #expect(reread.keywords.isEmpty)
        #expect(reread.creator.isEmpty)
        #expect(reread.isCleared)
        // The editable fields must be *absent*, not present-but-empty.
        let attrs = try #require(PDFDocument(url: out)?.documentAttributes)
        #expect(attrs[PDFDocumentAttribute.titleAttribute] == nil)
        #expect(attrs[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attrs[PDFDocumentAttribute.keywordsAttribute] == nil)
        // Producer and dates are PDFKit's own neutral write-time stamps — system values, so the
        // original tool name and timestamps are gone even though the keys exist.
        #expect(reread.producer.contains("Quartz"))
        #expect(reread.creationDate != nil)
    }

    @Test func refusesEncryptedInputWhole() throws {
        let dir = FixtureDir()
        let url = dir.url.appendingPathComponent("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: url)
        let locked = dir.url.appendingPathComponent("locked.pdf")
        try PDFToolkit.encrypt(inputURL: url, outputURL: locked, password: "pw")

        let readError = #expect(throws: PDFOperationError.self) {
            _ = try PDFToolkit.readMetadata(inputURL: locked)
        }
        #expect(readError?.kind == "metadataEncrypted")

        let writeError = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.writeMetadata(
                inputURL: locked,
                outputURL: dir.url.appendingPathComponent("out.pdf"),
                fields: .cleared
            )
        }
        #expect(writeError?.kind == "metadataEncrypted")
    }

    @Test func refusesWritingOverTheInput() throws {
        let dir = FixtureDir()
        let url = try writePopulatedFixture(in: dir)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.writeMetadata(inputURL: url, outputURL: url, fields: .cleared)
        }
        #expect(error?.kind == "outputMatchesInput")
    }
}
