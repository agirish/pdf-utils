import Testing
import Foundation
@testable import PdfToolkit

/// The Reorder tool's index math used to live inline in the SwiftUI view, where only the engine-level
/// `reorder(order:)` was tested — the view-layer transforms (drag-move with its off-by-one, remove,
/// restore, reset) had no coverage. They now live on `ReorderWorkingSet`, a pure value type, so these
/// pin each transform directly: a drag from any cell to any cell, delete-then-reorder using current
/// (not original) indices, restore, restore-all, and reset back to the untouched document.
@Suite struct ReorderWorkingSetTests {

    /// The kept pages' original 1-based numbers, in current output order.
    private func kept(_ ws: ReorderWorkingSet) -> [Int] { ws.items.map(\.pageNumber) }
    /// The removed pages' original 1-based numbers (held sorted by original index).
    private func removed(_ ws: ReorderWorkingSet) -> [Int] { ws.removed.map(\.pageNumber) }

    /// Reproduces exactly what a drag does at runtime: the grid drop delegate computes the
    /// `Array.move` destination via `gridReorderDestination`, then the view calls `moveItems`.
    private func drag(_ ws: inout ReorderWorkingSet, fromIndex from: Int, toCell to: Int) {
        ws.moveItems(fromOffsets: IndexSet(integer: from), toOffset: gridReorderDestination(from: from, to: to))
    }

    // MARK: - The drag off-by-one in isolation

    @Test func gridReorderDestinationAppliesTheDownwardPlusOne() {
        // Dragging onto a LOWER cell lands before it → destination is the cell index unchanged.
        #expect(gridReorderDestination(from: 3, to: 1) == 1)
        #expect(gridReorderDestination(from: 3, to: 0) == 0)
        // Dragging onto a HIGHER cell lands after it → destination is cell index + 1 (the off-by-one
        // the guardrail protects). Landing on the last cell (index 4 of 5) targets end-offset 5.
        #expect(gridReorderDestination(from: 1, to: 3) == 4)
        #expect(gridReorderDestination(from: 1, to: 4) == 5)
    }

    // MARK: - Drag reorder over the working set

    @Test func upDragLandsBeforeTheTargetCell() {
        var ws = ReorderWorkingSet(pageCount: 5)      // [1,2,3,4,5]
        drag(&ws, fromIndex: 3, toCell: 1)            // drag P4 onto P2's cell
        #expect(kept(ws) == [1, 4, 2, 3, 5])
    }

    @Test func downDragLandsAfterTheTargetCell() {
        var ws = ReorderWorkingSet(pageCount: 5)      // [1,2,3,4,5]
        drag(&ws, fromIndex: 1, toCell: 3)            // drag P2 onto P4's cell
        #expect(kept(ws) == [1, 3, 4, 2, 5])
    }

    @Test func dragToFirstCellMovesToTheFront() {
        var ws = ReorderWorkingSet(pageCount: 5)      // [1,2,3,4,5]
        drag(&ws, fromIndex: 3, toCell: 0)            // drag P4 to the very front
        #expect(kept(ws) == [4, 1, 2, 3, 5])
    }

    @Test func dragToLastCellMovesToTheEnd() {
        var ws = ReorderWorkingSet(pageCount: 5)      // [1,2,3,4,5]
        drag(&ws, fromIndex: 1, toCell: 4)            // drag P2 onto the last cell
        #expect(kept(ws) == [1, 3, 4, 5, 2])
    }

    @Test func draggingOntoItselfIsANoOp() {
        var ws = ReorderWorkingSet(pageCount: 3)
        drag(&ws, fromIndex: 1, toCell: 1)
        #expect(kept(ws) == [1, 2, 3])
    }

    // MARK: - Remove / restore

    @Test func removeParksThePageAndReorderUsesCurrentIndices() {
        var ws = ReorderWorkingSet(pageCount: 4)      // [1,2,3,4]
        ws.remove(originalPageNumber: 2)              // kept [1,3,4], removed [2]
        #expect(kept(ws) == [1, 3, 4])
        #expect(removed(ws) == [2])

        // P4 now sits at index 2 (not its original 3): a drag-to-front must key off the CURRENT
        // index, so the result is [4,1,3] — the delete-then-reorder case.
        drag(&ws, fromIndex: 2, toCell: 0)
        #expect(kept(ws) == [4, 1, 3])
        #expect(removed(ws) == [2])                   // removal survives the reorder
    }

    @Test func removeKeepsTheRemovedListSortedByOriginalIndex() {
        var ws = ReorderWorkingSet(pageCount: 5)
        ws.remove(originalPageNumber: 4)
        ws.remove(originalPageNumber: 2)
        ws.remove(originalPageNumber: 5)
        // Regardless of removal order, "Removed" reads in original-page order.
        #expect(removed(ws) == [2, 4, 5])
        #expect(kept(ws) == [1, 3])
    }

    @Test func removeByOriginalPageNumberIgnoresAPageNotCurrentlyKept() {
        var ws = ReorderWorkingSet(pageCount: 3)
        ws.remove(originalPageNumber: 2)
        ws.remove(originalPageNumber: 2)              // already removed — no-op, no crash
        #expect(kept(ws) == [1, 3])
        #expect(removed(ws) == [2])
    }

    @Test func restoreBringsAPageBackAtTheEndOfTheKeptOrder() {
        var ws = ReorderWorkingSet(pageCount: 4)      // [1,2,3,4]
        ws.remove(originalPageNumber: 2)              // kept [1,3,4], removed [2]
        ws.restore(ws.removed[0])                     // restore P2
        #expect(kept(ws) == [1, 3, 4, 2])             // appended, not slotted back into place
        #expect(ws.removed.isEmpty)
    }

    @Test func restoreAllAppendsEveryRemovedPageInOriginalOrder() {
        var ws = ReorderWorkingSet(pageCount: 4)      // [1,2,3,4]
        ws.remove(originalPageNumber: 3)
        ws.remove(originalPageNumber: 2)              // kept [1,4], removed [2,3]
        ws.restoreAll()
        #expect(kept(ws) == [1, 4, 2, 3])             // kept order preserved, removed appended ascending
        #expect(ws.removed.isEmpty)
    }

    // MARK: - Reset

    @Test func resetReturnsToTheUntouchedDocument() {
        var ws = ReorderWorkingSet(pageCount: 5)      // [1,2,3,4,5]
        drag(&ws, fromIndex: 4, toCell: 0)            // shuffle
        ws.remove(originalPageNumber: 3)              // and drop a page
        #expect(kept(ws) != [1, 2, 3, 4, 5])

        ws.reset()
        #expect(kept(ws) == [1, 2, 3, 4, 5])          // every page, original order
        #expect(ws.removed.isEmpty)
    }

    // MARK: - Derived flags

    @Test func isModifiedTracksReorderAndRemoval() {
        var ws = ReorderWorkingSet(pageCount: 3)
        #expect(!ws.isModified)                       // fresh load reads as untouched

        drag(&ws, fromIndex: 0, toCell: 2)
        #expect(ws.isModified)                        // a reorder counts

        ws.reset()
        #expect(!ws.isModified)

        ws.remove(originalPageNumber: 2)
        #expect(ws.isModified)                        // a removal counts even with kept order intact
    }

    @Test func allPagesRemovedOnlyOnceEveryPageIsGone() {
        var ws = ReorderWorkingSet(pageCount: 2)
        #expect(!ws.allPagesRemoved)
        ws.remove(originalPageNumber: 1)
        #expect(!ws.allPagesRemoved)                  // still one page kept — saving stays allowed
        ws.remove(originalPageNumber: 2)
        #expect(ws.allPagesRemoved)                   // nothing left to write — the empty-PDF guard
        #expect(ws.items.isEmpty)
    }
}
