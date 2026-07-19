import SwiftUI

/// Host-owned presentation state for the in-window ⌘K "Quick Actions" palette — the direct sibling of
/// `SettingsPresenter`. Injected into the environment so the ⌘K command (which lives in the App's
/// `.commands`, a different view tree than the overlay) can raise and dismiss the palette, and so any
/// toolbar affordance could open it. `toggle()` backs the single ⌘K shortcut: press to open, press
/// again to close.
@MainActor
public final class QuickActionsPresenter: ObservableObject {
    @Published public var isPresented = false

    public init() {}

    public func open() { isPresented = true }
    public func close() { isPresented = false }
    public func toggle() { isPresented.toggle() }
}
