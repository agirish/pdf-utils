import CoreGraphics

/// A keyboard command a direct-manipulation editor (Crop, Fill & Sign, Redact) understands. Produced
/// from a raw key event by ``EditorKeyMapping`` so the mapping stays pure and unit-testable — the
/// AppKit `keyDown` only extracts key code / characters / modifiers and hands them here.
enum EditorKeyCommand: Equatable {
    case undo
    case redo
    /// Remove the selected item (Fill & Sign / Redact; Crop has no per-item delete).
    case delete
    /// Move the selection by this vector, expressed in **y-up screen** points (up is +y). Magnitude is
    /// the nudge step (1 pt, or 10 pt with Shift); the editor renormalizes it into a page-space delta.
    case nudge(dx: CGFloat, dy: CGFloat)
}

enum EditorKeyMapping {
    /// The single-press nudge, in page points.
    static let step: CGFloat = 1
    /// The Shift-held coarse nudge, in page points.
    static let coarseStep: CGFloat = 10

    // macOS virtual key codes — layout-independent for the arrows and delete keys.
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let downArrow: UInt16 = 125
    private static let upArrow: UInt16 = 126
    private static let delete: UInt16 = 51
    private static let forwardDelete: UInt16 = 117

    /// Classifies a key event into an editor command, or nil to let it fall through (so a focused text
    /// field's own ⌘Z, arrow navigation, and delete are never stolen).
    ///
    /// - Parameters:
    ///   - characters: `charactersIgnoringModifiers`, lowercased — used only for the ⌘Z / ⌘⇧Z test so
    ///     it tracks the actual 'z' key across layouts, not a physical key code.
    static func command(
        keyCode: UInt16,
        characters: String?,
        hasCommand: Bool,
        hasShift: Bool
    ) -> EditorKeyCommand? {
        if hasCommand {
            // ⌘Z undo, ⌘⇧Z redo. Only the 'z' key; every other ⌘-combo falls through untouched.
            guard characters == "z" else { return nil }
            return hasShift ? .redo : .undo
        }
        let d = hasShift ? coarseStep : step
        switch keyCode {
        case leftArrow: return .nudge(dx: -d, dy: 0)
        case rightArrow: return .nudge(dx: d, dy: 0)
        case upArrow: return .nudge(dx: 0, dy: d)
        case downArrow: return .nudge(dx: 0, dy: -d)
        case delete, forwardDelete: return .delete
        default: return nil
        }
    }
}
