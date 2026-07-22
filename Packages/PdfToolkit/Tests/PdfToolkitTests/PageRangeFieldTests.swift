import Testing
import Foundation
@testable import PdfToolkit

/// The live inline validator behind Extract/Delete/Split's "N pages will remain" hint. It must agree
/// exactly with what the export parse does (so the hint can't promise a run Save then rejects) while
/// staying quiet during the mid-type states a nagging validator would flag.
@Suite struct PageRangeFieldTests {

    @Test func blankFieldIsEmpty() {
        #expect(PageRangeField.evaluate("", pageCount: 10, preserveOrder: false) == .empty)
        #expect(PageRangeField.evaluate("   ", pageCount: 10, preserveOrder: false) == .empty)
    }

    @Test func trailingHyphenIsIncompleteNotAnError() {
        // "3-" is a half-typed range; the field stays silent until the second bound is typed.
        #expect(PageRangeField.evaluate("3-", pageCount: 10, preserveOrder: false) == .incomplete)
        #expect(PageRangeField.evaluate("1, 4-", pageCount: 10, preserveOrder: false) == .incomplete)
    }

    @Test func noDocumentStaysQuiet() {
        // Nothing to validate against before a file loads.
        #expect(PageRangeField.evaluate("1-3", pageCount: 0, preserveOrder: false) == .incomplete)
    }

    @Test func validRangeReportsZeroBasedIndices() {
        #expect(PageRangeField.evaluate("1, 3-5", pageCount: 10, preserveOrder: false) == .pages([0, 2, 3, 4]))
    }

    @Test func preserveOrderKeepsExtractSemantics() {
        // Extract counts every slot in order, duplicates included — the count the hint reports.
        #expect(PageRangeField.evaluate("5,1,1", pageCount: 10, preserveOrder: true) == .pages([4, 0, 0]))
        // The unique/sorted mode (Delete) collapses the same input.
        #expect(PageRangeField.evaluate("5,1,1", pageCount: 10, preserveOrder: false) == .pages([0, 4]))
    }

    @Test func outOfBoundsPageIsInvalidWithExportMessage() {
        guard case .invalid(let message) = PageRangeField.evaluate("1-99", pageCount: 10, preserveOrder: false) else {
            Issue.record("expected .invalid for an out-of-bounds range")
            return
        }
        // The message is the export error's own text, so inline and save-time wording match — and it
        // names the FIRST page past the end (11), where the parser actually stops, not the typed 99.
        #expect(message == PDFOperationError.pageOutOfBounds(11).localizedDescription)
    }

    @Test func garbageTokenIsInvalid() {
        guard case .invalid = PageRangeField.evaluate("abc", pageCount: 10, preserveOrder: false) else {
            Issue.record("expected .invalid for a non-numeric token")
            return
        }
    }
}
