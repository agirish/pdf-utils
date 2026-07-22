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

    // MARK: - Crop receipt page count (mode- and drag-scope-dependent)

    @Test func cropAutoAndCustomAlwaysCountEveryPage() {
        // Auto and Custom trim the whole document; the drag scope flag is irrelevant to them.
        #expect(CropToolView.croppedCount(mode: .auto, dragAllPages: true, totalPages: 8) == 8)
        #expect(CropToolView.croppedCount(mode: .auto, dragAllPages: false, totalPages: 8) == 8)
        #expect(CropToolView.croppedCount(mode: .custom, dragAllPages: false, totalPages: 8) == 8)
    }

    @Test func cropDragCountsAllPagesOrJustOne() {
        // Drag mode: "same crop on every page" trims all; "this page only" trims exactly one.
        #expect(CropToolView.croppedCount(mode: .drag, dragAllPages: true, totalPages: 8) == 8)
        #expect(CropToolView.croppedCount(mode: .drag, dragAllPages: false, totalPages: 8) == 1)
    }

    @Test func cropCountIsZeroForAnEmptyDocument() {
        // No pages loaded yet: every mode reports 0 so the receipt can fall back to "Cropped & saved".
        #expect(CropToolView.croppedCount(mode: .auto, dragAllPages: true, totalPages: 0) == 0)
        // Drag "this page only" still claims 1 even with 0 pages; the run guards on inputURL before this
        // ever runs, so the caller never asks with a zero-page drag — this just pins the pure arithmetic.
        #expect(CropToolView.croppedCount(mode: .drag, dragAllPages: false, totalPages: 0) == 1)
    }

    // MARK: - Watermark receipt page count (scope-dependent, with a parse fallback)

    @Test func watermarkAllScopeStampsEveryPage() {
        #expect(WatermarkToolView.stampedCount(scope: .all, customRange: "", pageCount: 10) == 10)
    }

    @Test func watermarkFirstScopeStampsOnePageOrNoneWhenEmpty() {
        #expect(WatermarkToolView.stampedCount(scope: .first, customRange: "", pageCount: 10) == 1)
        // No pages loaded: First stamps nothing, not one phantom page.
        #expect(WatermarkToolView.stampedCount(scope: .first, customRange: "", pageCount: 0) == 0)
    }

    @Test func watermarkCustomScopeCountsTheParsedRange() {
        // "1, 3-5" → pages 1,3,4,5 → 4 pages.
        #expect(WatermarkToolView.stampedCount(scope: .custom, customRange: "1, 3-5", pageCount: 10) == 4)
    }

    @Test func watermarkCustomScopeFallsBackToTheWholeDocumentWhenTheRangeWontParse() {
        // Empty, malformed, and out-of-bounds ranges all fail to parse; the count falls back to the full
        // page count rather than showing 0 (the run's own gate keeps a truly bad range from saving).
        #expect(WatermarkToolView.stampedCount(scope: .custom, customRange: "", pageCount: 10) == 10)
        #expect(WatermarkToolView.stampedCount(scope: .custom, customRange: "nonsense", pageCount: 10) == 10)
        #expect(WatermarkToolView.stampedCount(scope: .custom, customRange: "1-99", pageCount: 10) == 10)
    }

    @Test func watermarkCustomScopeWithNoPagesFallsBackToZero() {
        // pageCount 0: the parse fails (nothing is in bounds), so the fallback is 0, not a phantom count.
        #expect(WatermarkToolView.stampedCount(scope: .custom, customRange: "1-3", pageCount: 0) == 0)
    }

    // MARK: - Delete output suffix (Finding 8b)

    @Test func deleteOutputSuffixIsActionMatched() {
        // The old "-edited" was vague; it must match its siblings' verb-based suffixes.
        #expect(DeletePagesToolView.outputSuffix == "pages-removed")
    }
}
