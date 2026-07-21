import Testing
import Foundation
@testable import PdfToolkit

/// The cut-point ↔ segments math behind Split's visual grid. Cuts are what a gap click toggles; the
/// segments they derive are exactly what `PDFToolkit.split` writes, so these pin that the grid, the
/// live "Creates N files" count, and the export can never disagree — including the every-N reflection
/// that must match `PageRangeParser.everyNPagesSegments` page-for-page.
@Suite struct SplitCutsTests {

    // MARK: - Segments from cuts

    @Test func noCutsIsOneWholeFile() {
        #expect(SplitCuts.segments(pageCount: 8, cuts: []) == [[0, 1, 2, 3, 4, 5, 6, 7]])
    }

    @Test func cutsPartitionIntoConsecutiveGroups() {
        // Cuts after pages 3 and 6 → 1-3, 4-6, 7-8 (zero-based).
        #expect(SplitCuts.segments(pageCount: 8, cuts: [3, 6]) == [[0, 1, 2], [3, 4, 5], [6, 7]])
    }

    @Test func cutAfterEveryPageMakesSinglePageFiles() {
        #expect(SplitCuts.segments(pageCount: 3, cuts: [1, 2]) == [[0], [1], [2]])
    }

    @Test func cutOrderInTheSetDoesNotMatter() {
        // A Set has no order; the boundaries must still come out sorted.
        #expect(SplitCuts.segments(pageCount: 6, cuts: [4, 2]) == [[0, 1], [2, 3], [4, 5]])
    }

    @Test func staleCutsPastTheDocumentAreIgnored() {
        // A cut left over from a longer document (page 9 of a 4-page file) collapses away rather than
        // producing an empty trailing group.
        #expect(SplitCuts.segments(pageCount: 4, cuts: [2, 9]) == [[0, 1], [2, 3]])
    }

    @Test func cutAtOrBeyondTheLastPageNeverMakesAnEmptyGroup() {
        // "Cut after page 4" of a 4-page document would start an empty file — dropped.
        #expect(SplitCuts.segments(pageCount: 4, cuts: [4]) == [[0, 1, 2, 3]])
    }

    @Test func zeroPageDocumentYieldsNoSegments() {
        #expect(SplitCuts.segments(pageCount: 0, cuts: [1]).isEmpty)
    }

    @Test func fileCountIsAlwaysCutsPlusOne() {
        // The invariant the "Creates N files" label leans on, for any in-range cut set.
        for cuts in [Set<Int>(), [3], [1, 2, 3], [2, 5, 7]] {
            let inRange = cuts.filter { $0 >= 1 && $0 < 8 }
            #expect(SplitCuts.segments(pageCount: 8, cuts: cuts).count == inRange.count + 1)
        }
    }

    // MARK: - Every-N reflection

    @Test func everyNCutsMatchPageRangeParserSegments() {
        // The visual reflection of "Every N pages" must divide the document identically to the export.
        for pageCount in [1, 5, 8, 10, 13] {
            for chunk in 1...pageCount {
                let viaCuts = SplitCuts.segments(
                    pageCount: pageCount,
                    cuts: SplitCuts.everyNCuts(pageCount: pageCount, chunkSize: chunk)
                )
                let viaParser = PageRangeParser.everyNPagesSegments(pageCount: pageCount, chunkSize: chunk)
                #expect(viaCuts == viaParser, "every-\(chunk) of \(pageCount) pages diverged")
            }
        }
    }

    @Test func everyNCutsFloorsAtOne() {
        // A zero/negative chunk can't wedge the loop or over-cut; it behaves like "every 1 page".
        #expect(SplitCuts.everyNCuts(pageCount: 4, chunkSize: 0) == [1, 2, 3])
        #expect(SplitCuts.everyNCuts(pageCount: 4, chunkSize: -3) == [1, 2, 3])
    }

    @Test func everyNChunkLargerThanDocumentIsOneFile() {
        #expect(SplitCuts.everyNCuts(pageCount: 4, chunkSize: 10).isEmpty)
        #expect(SplitCuts.segments(pageCount: 4, cuts: SplitCuts.everyNCuts(pageCount: 4, chunkSize: 10))
            == [[0, 1, 2, 3]])
    }
}
