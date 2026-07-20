import SwiftUI

/// Host-owned presentation state for the in-window Help overlay, the exact sibling of
/// `SettingsPresenter` and `QuickActionsPresenter`. Injected into the environment so the ⌘? command,
/// the dashboard "?" button, and every tool's "?" button — which live in different views than the
/// overlay — can all open the Help book, optionally navigated to a specific topic.
@MainActor
public final class HelpPresenter: ObservableObject {
    @Published public var isPresented = false

    /// The topic the overlay should open on. `nil` lands on the first topic. `HelpView` seeds its
    /// selection from this when it appears; because the overlay is created fresh on each open (it's
    /// conditionally rendered from `isPresented`), setting this before `open()` is enough to navigate.
    @Published public var initialTopicID: String?

    public init() {}

    /// Raise the Help book. Pass a topic id to open straight to that article.
    public func open(topicID: String? = nil) {
        initialTopicID = topicID
        isPresented = true
    }

    /// Open the Help book to the dashboard's landing article — the "?" on the home screen.
    public func openHome() {
        open(topicID: "welcome")
    }

    /// Open the Help book to a specific tool's article — the "?" inside a tool screen.
    public func openTool(_ tool: Tool) {
        open(topicID: HelpBook.topicID(for: tool))
    }

    public func close() {
        isPresented = false
    }
}
