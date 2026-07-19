import SwiftUI

/// The app's blank-panel template: a large hierarchical icon, a title, an optional message, and up
/// to two actions. Ported (trimmed) from SyncCloud's `Design/EmptyStateView` so an empty panel
/// always looks intentional and offers the next step. Layout is hard-coded here; all copy is passed
/// in by the caller.
public struct EmptyStateView: View {
    /// One button an empty state offers. `primary` renders prominent/filled (the obvious next step);
    /// `secondary` renders as a regular bordered button (a quieter companion action).
    public struct Action {
        public let title: String
        public let systemImage: String?
        public let handler: () -> Void

        public init(_ title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.handler = handler
        }
    }

    private let icon: String
    private let tint: Color
    private let title: String
    private let message: String?
    private let primary: Action?
    private let secondary: Action?

    public init(
        icon: String,
        tint: Color = .secondary,
        title: String,
        message: String? = nil,
        primary: Action? = nil,
        secondary: Action? = nil
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if primary != nil || secondary != nil {
                HStack(spacing: 10) {
                    if let primary {
                        Button(action: primary.handler) { label(for: primary) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    if let secondary {
                        Button(action: secondary.handler) { label(for: secondary) }
                            .controlSize(.regular)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func label(for action: Action) -> some View {
        if let systemImage = action.systemImage {
            Label(action.title, systemImage: systemImage)
        } else {
            Text(action.title)
        }
    }
}
