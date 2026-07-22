import SwiftUI

/// The Undo / Redo control pair shown above the direct editors (Crop, Fill & Sign, Redact). It is the
/// mouse path to the very same history that ⌘Z / ⌘⇧Z reach from the canvas, and — being always
/// visible — the feature's discoverability.
///
/// Deliberately carries **no** `keyboardShortcut`: ⌘Z is handled on the canvas only while it holds
/// focus, so a focused text field (Redact's search, Fill & Sign's text entry) keeps its own native
/// undo instead of this stealing it app-wide.
struct EditorUndoButtons: View {
    let canUndo: Bool
    let canRedo: Bool
    var accent: Color
    let undo: () -> Void
    let redo: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            Button(action: undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!canUndo)
            .help("Undo the last change")
            .accessibilityLabel("Undo")

            Button(action: redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!canRedo)
            .help("Redo")
            .accessibilityLabel("Redo")
        }
        .buttonStyle(.borderless)
        .font(.body.weight(.medium))
        .foregroundStyle(Color.accentText(accent, on: scheme, contrast: contrast))
    }
}
