import Foundation

/// A bounded undo/redo history over whole-state snapshots — the crop insets, the Fill & Sign items,
/// the redaction marks. Snapshot-based rather than command-based on purpose: these states are small
/// value types, so snapshotting the whole thing is simpler and safer than describing every gesture as
/// an invertible command.
///
/// The host drives it from `.onChange(of: state)`: a settled edit calls ``commit(_:)``, and undo/redo
/// hand back the state to apply. The key property that keeps that wiring race-free is that
/// ``commit(_:)`` is a **no-op when the value equals ``current``** — so the `onChange` that fires when
/// undo/redo reassigns the state (leaving `current` already equal to the restored value) records
/// nothing, and no "am I applying history right now?" flag is needed.
struct UndoHistory<State: Equatable> {
    /// The last committed snapshot — what a fresh edit is measured against and what undo restores past.
    private(set) var current: State
    private(set) var past: [State] = []
    private(set) var future: [State] = []
    private let limit: Int

    init(_ initial: State, limit: Int = 100) {
        self.current = initial
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Records a settled edit. A change equal to ``current`` is ignored — this both keeps identical
    /// re-commits off the stack and makes the post-undo `onChange` re-commit a no-op. Any genuine new
    /// edit clears the redo branch.
    mutating func commit(_ newState: State) {
        guard newState != current else { return }
        past.append(current)
        if past.count > limit { past.removeFirst() }
        current = newState
        future.removeAll()
    }

    /// Steps back one snapshot, returning the state the host should apply (nil if nothing to undo).
    mutating func undo() -> State? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        current = previous
        return previous
    }

    /// Steps forward one snapshot, returning the state the host should apply (nil if nothing to redo).
    mutating func redo() -> State? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        current = next
        return next
    }

    /// Re-seeds the history for a new document, dropping all undo/redo so ⌘Z can't cross the file
    /// boundary back into the previous document's edits.
    mutating func reset(_ initial: State) {
        past.removeAll()
        future.removeAll()
        current = initial
    }
}
