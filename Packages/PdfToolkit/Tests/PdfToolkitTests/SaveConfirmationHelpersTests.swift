import CoreGraphics
import Foundation
import Testing
@testable import PdfToolkit

/// The pure helpers behind the tools' in-app save confirmations (Finding 5) and Watermark's Custom-range
/// run gate (Finding 6). The GUI can't be driven here, so the logic that decides *what a save says* and
/// *whether a run is allowed* is pulled out of the views and pinned directly.
@MainActor
@Suite struct SaveConfirmationHelpersTests {

    // MARK: - Redact receipt numbers (security-critical: "N regions across M pages")

    @Test func redactionCountsAreZeroForNoMarks() {
        let counts = RedactToolView.redactionCounts(for: [])
        #expect(counts.regions == 0)
        #expect(counts.pages == 0)
    }

    @Test func redactionCountsOneRegionOnePage() {
        let marks = [RedactionMark(pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10))]
        let counts = RedactToolView.redactionCounts(for: marks)
        #expect(counts.regions == 1)
        #expect(counts.pages == 1)
    }

    @Test func redactionCountsCollapseMultipleRegionsOnTheSamePage() {
        // Two regions burned on page 0 is "2 regions across 1 page", not across 2.
        let marks = [
            RedactionMark(pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
            RedactionMark(pageIndex: 0, rect: CGRect(x: 20, y: 20, width: 10, height: 10)),
        ]
        let counts = RedactToolView.redactionCounts(for: marks)
        #expect(counts.regions == 2)
        #expect(counts.pages == 1)
    }

    @Test func redactionCountsSpanDistinctPages() {
        // Four regions spread over pages 0, 2, and 2 again → 4 regions across 2 distinct pages.
        let marks = [
            RedactionMark(pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
            RedactionMark(pageIndex: 2, rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
            RedactionMark(pageIndex: 2, rect: CGRect(x: 30, y: 0, width: 10, height: 10)),
            RedactionMark(pageIndex: 5, rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
        ]
        let counts = RedactToolView.redactionCounts(for: marks)
        #expect(counts.regions == 4)
        #expect(counts.pages == 3)
    }

    // MARK: - Watermark Custom-range run gate (Finding 6)

    @Test func nonCustomScopesAreAlwaysRunnable() {
        // All pages / First page never gate on the range field — even a garbage customRange is ignored.
        #expect(WatermarkToolView.customRangeIsRunnable(scope: .all, customRange: "", pageCount: 10))
        #expect(WatermarkToolView.customRangeIsRunnable(scope: .all, customRange: "nonsense", pageCount: 10))
        #expect(WatermarkToolView.customRangeIsRunnable(scope: .first, customRange: "", pageCount: 10))
    }

    @Test func customScopeNeedsAValidInBoundsRange() {
        #expect(WatermarkToolView.customRangeIsRunnable(scope: .custom, customRange: "1, 3-5", pageCount: 10))
        #expect(WatermarkToolView.customRangeIsRunnable(scope: .custom, customRange: "10", pageCount: 10))
    }

    @Test func customScopeWithEmptyRangeIsNotRunnable() {
        // An empty Custom range disables Run rather than erroring on click.
        #expect(!WatermarkToolView.customRangeIsRunnable(scope: .custom, customRange: "", pageCount: 10))
        #expect(!WatermarkToolView.customRangeIsRunnable(scope: .custom, customRange: "   ", pageCount: 10))
    }

    @Test func customScopeWithOutOfBoundsRangeIsNotRunnable() {
        #expect(!WatermarkToolView.customRangeIsRunnable(scope: .custom, customRange: "1-99", pageCount: 10))
        #expect(!WatermarkToolView.customRangeIsRunnable(scope: .custom, customRange: "42", pageCount: 10))
    }

    @Test func customScopeIsNotRunnableBeforeAPageCountIsKnown() {
        // No loaded single file yet (pageCount 0): nothing to validate against, so keep Run disabled.
        #expect(!WatermarkToolView.customRangeIsRunnable(scope: .custom, customRange: "1-3", pageCount: 0))
    }

    // MARK: - Delete output suffix (Finding 8b)

    @Test func deleteOutputSuffixIsActionMatched() {
        // The old "-edited" was vague; it must match its siblings' verb-based suffixes.
        #expect(DeletePagesToolView.outputSuffix == "pages-removed")
    }
}
