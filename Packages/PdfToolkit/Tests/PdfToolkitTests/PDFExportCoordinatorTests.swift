import Foundation
import PDFKit
import Testing
@testable import PdfToolkit

/// The metadata-stripping side of the shared export coordinator. Naming and unique-URL behavior are
/// covered in `SettingsValueTypesTests`; this exercises the PDF-touching path, including the guard
/// that keeps encrypted output intact.
@Suite struct PDFExportCoordinatorTests {

    @Test func stripMetadataClearsAuthorAndTitleButKeepsPages() throws {
        let base = try PDFFixtures.pdfData(markers: [PDFFixtures.marker(1), PDFFixtures.marker(2)])
        let doc = try #require(PDFDocument(data: base))
        doc.documentAttributes = [
            PDFDocumentAttribute.authorAttribute: "Alice",
            PDFDocumentAttribute.titleAttribute: "Quarterly Secrets",
        ]
        let withMetadata = try #require(doc.dataRepresentation())
        // Sanity: the info really is present before stripping.
        let before = try #require(PDFDocument(data: withMetadata))
        #expect(before.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Alice")

        let stripped = PDFExportCoordinator.stripMetadata(withMetadata)
        let after = try #require(PDFDocument(data: stripped))
        #expect(after.pageCount == 2)
        let attributes = after.documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attributes[PDFDocumentAttribute.titleAttribute] == nil)
    }

    @Test func stripMetadataLeavesEncryptedOutputUntouched() throws {
        let dir = FixtureDir()
        let source = dir.url("source.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: source)
        let encrypted = dir.url("encrypted.pdf")
        try PDFToolkit.encrypt(inputURL: source, outputURL: encrypted, password: "hunter2")
        let encryptedData = try Data(contentsOf: encrypted)

        let result = PDFExportCoordinator.stripMetadata(encryptedData)
        // Untouched byte-for-byte — re-serializing would strip the encryption.
        #expect(result == encryptedData)
        #expect(PDFDocument(data: result)?.isEncrypted == true)
    }

    @Test func stripMetadataReturnsInputForNonPDFData() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        #expect(PDFExportCoordinator.stripMetadata(garbage) == garbage)
    }
}
