import SwiftUI

/// The one dismiss affordance (aligned with SyncCloud `Design/CloseButton`): a plain secondary
/// xmark, semibold at 11pt, with a comfortable 26×26 hit target. Callers attach their own `.help`,
/// `.accessibilityLabel`, and `.keyboardShortcut`.
public struct CloseButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public extension View {
    /// The one search-field chrome: a radius-8 continuous rect washed quaternary at 0.6.
    func searchFieldSurface() -> some View {
        background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
