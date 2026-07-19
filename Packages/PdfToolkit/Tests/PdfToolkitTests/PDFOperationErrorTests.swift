import Testing
import Foundation
@testable import PdfToolkit

/// Every error the toolkit throws surfaces to the user as an alert, so each case must carry a
/// non-empty, human-readable message, and the cases with a payload (a file, a page number, a bad
/// range) must fold that payload into the text — a bare "Invalid page range" helps no one.
@Suite struct PDFOperationErrorTests {

    /// One instance of every case, with representative payloads. The `kind` set assertion below
    /// fails if a new case is added to the enum but not to this list.
    private let all: [PDFOperationError] = [
        .couldNotOpen(URL(fileURLWithPath: "/tmp/in.pdf")),
        .couldNotWrite(URL(fileURLWithPath: "/tmp/out.pdf")),
        .outputMatchesInput(URL(fileURLWithPath: "/tmp/report.pdf")),
        .invalidPageRange("q-z"),
        .pageOutOfBounds(7),
        .pageRangeRequired,
        .cannotRemoveEveryPage,
        .fileAccessDenied(URL(fileURLWithPath: "/tmp/denied.pdf")),
        .noInputFiles,
        .noPagesSelected,
        .compressionFailed,
        .emptyPDF,
        .noRedactions,
        .redactionFailed,
        .watermarkTextRequired,
        .watermarkFailed,
        .noFillSignItems,
        .fillSignFailed,
        .passwordRequired,
        .incorrectPassword,
        .notEncrypted,
        .protectionFailed,
    ]

    @Test func listCoversEveryCase() {
        // 22 distinct kinds — guards against forgetting to describe a newly added case.
        #expect(Set(all.map(\.kind)).count == 22)
    }

    @Test func everyCaseHasANonEmptyDescription() {
        for error in all {
            let description = error.errorDescription
            #expect(description != nil, "\(error.kind) has no description")
            #expect(!(description ?? "").isEmpty, "\(error.kind) has an empty description")
        }
    }

    @Test func payloadCasesFoldTheirValueIntoTheMessage() {
        #expect(PDFOperationError.couldNotOpen(URL(fileURLWithPath: "/x/report.pdf"))
            .errorDescription?.contains("report.pdf") == true)
        #expect(PDFOperationError.couldNotWrite(URL(fileURLWithPath: "/x/final.pdf"))
            .errorDescription?.contains("final.pdf") == true)
        #expect(PDFOperationError.outputMatchesInput(URL(fileURLWithPath: "/x/original.pdf"))
            .errorDescription?.contains("original.pdf") == true)
        #expect(PDFOperationError.fileAccessDenied(URL(fileURLWithPath: "/x/locked.pdf"))
            .errorDescription?.contains("locked.pdf") == true)
        #expect(PDFOperationError.pageOutOfBounds(42).errorDescription?.contains("42") == true)
        #expect(PDFOperationError.invalidPageRange("8-2!").errorDescription?.contains("8-2!") == true)
    }
}
