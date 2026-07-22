import Testing
import CoreGraphics
@testable import PdfToolkit

/// The shared undo/redo history behind the three direct editors' ⌘Z, plus the pure key-mapping and
/// nudge geometry the arrow keys drive.
@Suite struct UndoHistoryTests {

    @Test func startsEmpty() {
        let h = UndoHistory(0)
        #expect(!h.canUndo)
        #expect(!h.canRedo)
        #expect(h.current == 0)
    }

    @Test func commitRecordsAndEnablesUndo() {
        var h = UndoHistory(0)
        h.commit(1)
        #expect(h.current == 1)
        #expect(h.canUndo)
        #expect(!h.canRedo)
    }

    @Test func committingTheSameValueIsANoOp() {
        // This is what makes the host's post-undo onChange re-commit harmless.
        var h = UndoHistory(0)
        h.commit(0)
        #expect(!h.canUndo)
    }

    @Test func undoThenRedoRoundTrips() {
        var h = UndoHistory(0)
        h.commit(1)
        h.commit(2)
        #expect(h.undo() == 1)
        #expect(h.current == 1)
        #expect(h.canRedo)
        #expect(h.redo() == 2)
        #expect(h.current == 2)
    }

    @Test func reCommittingTheRestoredValueAfterUndoDoesNotCorruptTheStack() {
        // Simulates the host: undo() leaves current == restored, then onChange re-commits that same
        // value — which must be a no-op so redo still works and no phantom step is pushed.
        var h = UndoHistory(0)
        h.commit(1)
        h.commit(2)
        let restored = h.undo()          // -> 1, current == 1
        h.commit(restored!)              // onChange re-commit of the applied value
        #expect(h.current == 1)
        #expect(h.redo() == 2)           // redo branch survived
    }

    @Test func aNewEditClearsTheRedoBranch() {
        var h = UndoHistory(0)
        h.commit(1)
        h.commit(2)
        _ = h.undo()                     // current == 1, future has [2]
        h.commit(9)                      // diverge
        #expect(!h.canRedo)
        #expect(h.current == 9)
    }

    @Test func historyIsBounded() {
        var h = UndoHistory(0, limit: 3)
        for v in 1...10 { h.commit(v) }
        // Only the last `limit` prior states are retained; undo can step back exactly that many.
        var steps = 0
        while h.undo() != nil { steps += 1 }
        #expect(steps == 3)
    }

    @Test func resetDropsHistoryForANewDocument() {
        var h = UndoHistory(0)
        h.commit(1)
        h.commit(2)
        h.reset(0)
        #expect(!h.canUndo)
        #expect(!h.canRedo)
        #expect(h.current == 0)
    }
}

@Suite struct EditorKeyMappingTests {

    @Test func commandZIsUndoAndShiftCommandZIsRedo() {
        #expect(EditorKeyMapping.command(keyCode: 6, characters: "z", hasCommand: true, hasShift: false) == .undo)
        #expect(EditorKeyMapping.command(keyCode: 6, characters: "z", hasCommand: true, hasShift: true) == .redo)
    }

    @Test func otherCommandCombosFallThrough() {
        // ⌘C, ⌘A, etc. must not be swallowed by the editor.
        #expect(EditorKeyMapping.command(keyCode: 8, characters: "c", hasCommand: true, hasShift: false) == nil)
    }

    @Test func arrowsNudgeInYUpScreenSpace() {
        #expect(EditorKeyMapping.command(keyCode: 126, characters: nil, hasCommand: false, hasShift: false) == .nudge(dx: 0, dy: 1))   // up
        #expect(EditorKeyMapping.command(keyCode: 125, characters: nil, hasCommand: false, hasShift: false) == .nudge(dx: 0, dy: -1))  // down
        #expect(EditorKeyMapping.command(keyCode: 123, characters: nil, hasCommand: false, hasShift: false) == .nudge(dx: -1, dy: 0))  // left
        #expect(EditorKeyMapping.command(keyCode: 124, characters: nil, hasCommand: false, hasShift: false) == .nudge(dx: 1, dy: 0))   // right
    }

    @Test func shiftMakesTheNudgeCoarse() {
        #expect(EditorKeyMapping.command(keyCode: 124, characters: nil, hasCommand: false, hasShift: true) == .nudge(dx: 10, dy: 0))
    }

    @Test func deleteKeysRemoveTheSelection() {
        #expect(EditorKeyMapping.command(keyCode: 51, characters: nil, hasCommand: false, hasShift: false) == .delete)
        #expect(EditorKeyMapping.command(keyCode: 117, characters: nil, hasCommand: false, hasShift: false) == .delete)
    }

    @Test func unmappedKeysFallThrough() {
        #expect(EditorKeyMapping.command(keyCode: 49, characters: " ", hasCommand: false, hasShift: false) == nil)   // space
    }
}

@Suite struct EditorNudgeTests {

    @Test func scaledPreservesDirectionAndSetsMagnitude() {
        // A raw page-space vector (here 3-4-5) rescaled to length 10 keeps its direction.
        let out = EditorNudge.scaled(CGSize(width: 3, height: 4), to: 10)
        #expect(abs(out.width - 6) < 1e-9)
        #expect(abs(out.height - 8) < 1e-9)
    }

    @Test func scaledIsZoomIndependent() {
        // Same direction at two "zooms" (different raw lengths) yields the same page-space nudge.
        let atZoom1 = EditorNudge.scaled(CGSize(width: 0, height: 1), to: 5)
        let atZoom4 = EditorNudge.scaled(CGSize(width: 0, height: 0.25), to: 5)
        #expect(atZoom1 == atZoom4)
        #expect(atZoom1.height == 5)
    }

    @Test func scaledZeroStaysZero() {
        #expect(EditorNudge.scaled(.zero, to: 10) == .zero)
    }

    private let box = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func moveInsideTheBoxJustOffsets() {
        let r = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(EditorNudge.moved(r, by: CGSize(width: 5, height: -3), within: box) == CGRect(x: 15, y: 7, width: 20, height: 20))
    }

    @Test func moveClampsAtTheEdgeWithoutResizing() {
        let r = CGRect(x: 90, y: 90, width: 20, height: 20)
        // Pushed up-and-right past the corner → pinned flush, same size.
        #expect(EditorNudge.moved(r, by: CGSize(width: 50, height: 50), within: box) == CGRect(x: 80, y: 80, width: 20, height: 20))
    }
}
