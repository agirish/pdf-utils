import Testing
import Foundation
@testable import PdfToolkit

struct VisualPageSelectionTests {
    // MARK: rangeString(from:)

    @Test func collapsesConsecutivePagesIntoRuns() {
        #expect(VisualPageSelection.rangeString(from: [1, 2, 3, 5, 9, 10]) == "1-3, 5, 9-10")
    }

    @Test func singlePageAndPairRenderCanonically() {
        #expect(VisualPageSelection.rangeString(from: [7]) == "7")
        // A run of exactly two still renders as a range, not two singles.
        #expect(VisualPageSelection.rangeString(from: [5, 6]) == "5-6")
    }

    @Test func emptySelectionIsEmptyString() {
        #expect(VisualPageSelection.rangeString(from: []).isEmpty)
    }

    @Test func sortsRegardlessOfInsertionOrderAndDropsNonPositive() {
        // A Set is unordered; the output is always ascending. Zero/negative pages are dropped.
        #expect(VisualPageSelection.rangeString(from: [3, 1, 2, 0, -4]) == "1-3")
    }

    // MARK: pages(from:pageCount:)

    @Test func parsesRangeTextIntoOneBasedPageSet() {
        #expect(VisualPageSelection.pages(from: "1-3, 5", pageCount: 10) == [1, 2, 3, 5])
    }

    @Test func emptyOrInvalidTextHighlightsNothing() {
        // Empty means "all" to the exporter, but visually we highlight nothing so a click builds an
        // explicit set rather than starting from every page selected.
        #expect(VisualPageSelection.pages(from: "", pageCount: 10).isEmpty)
        #expect(VisualPageSelection.pages(from: "   ", pageCount: 10).isEmpty)
        // Mid-type / malformed input never throws its way onto the thumbnails.
        #expect(VisualPageSelection.pages(from: "1-", pageCount: 10).isEmpty)
        #expect(VisualPageSelection.pages(from: "abc", pageCount: 10).isEmpty)
        // No pages at all: nothing to highlight.
        #expect(VisualPageSelection.pages(from: "1-3", pageCount: 0).isEmpty)
    }

    @Test func customOrderAndOverlapCollapseToTheCoveredSet() {
        // The set can't preserve order or duplicates; it captures which pages are covered.
        #expect(VisualPageSelection.pages(from: "5,1,2", pageCount: 10) == [1, 2, 5])
        #expect(VisualPageSelection.pages(from: "1-3, 2-4", pageCount: 10) == [1, 2, 3, 4])
    }

    @Test func blankFieldHighlightsAllPagesWhenTheToolExportsAll() {
        // Extract's blank field exports every page, so its highlight layer passes
        // emptyMeansAllPages: true and a blank field must select everything — the highlight and
        // the export can never disagree. Split keeps the default: blank means nothing yet.
        #expect(VisualPageSelection.pages(from: "", pageCount: 4, emptyMeansAllPages: true) == [1, 2, 3, 4])
        #expect(VisualPageSelection.pages(from: "   ", pageCount: 4, emptyMeansAllPages: true) == [1, 2, 3, 4])
        #expect(VisualPageSelection.pages(from: "", pageCount: 4) == [])
    }

    @Test func toggleRoundTripThroughTheTextField() {
        // The behavior the views rely on: read the set from the text, flip one page, write it back.
        let pageCount = 10
        var text = "1-3"
        var pages = VisualPageSelection.pages(from: text, pageCount: pageCount)
        pages.insert(5)
        text = VisualPageSelection.rangeString(from: pages)
        #expect(text == "1-3, 5")

        pages = VisualPageSelection.pages(from: text, pageCount: pageCount)
        pages.remove(2)
        text = VisualPageSelection.rangeString(from: pages)
        #expect(text == "1, 3, 5")
    }
}
