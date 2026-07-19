import SwiftUI

/// Identifies a Settings tab. Raw values are the stored format of `selectedTabDefaultsKey`, so treat
/// them as stable. `CaseIterable` backs the segmented picker.
public enum SettingsTab: String, CaseIterable, Sendable, Identifiable {
    case general
    case appearance
    case advanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .advanced: return "Advanced"
        }
    }

    /// UserDefaults key holding the tab the Settings overlay opens on (a `SettingsTab` raw value).
    public static let selectedTabDefaultsKey = "pdfutils.settingsSelectedTab"
}

/// Host-owned presentation state for the in-window Settings overlay, mirroring SyncCloud's
/// `showSettings` + `settingsTab` on `ContentView`. Injected into the environment so the ⌘, command
/// and the toolbar gear buttons — which live in different views than the overlay — can all open it.
@MainActor
public final class SettingsPresenter: ObservableObject {
    @Published public var isPresented = false
    @Published public var tab: SettingsTab

    public init() {
        let stored = UserDefaults.standard.string(forKey: SettingsTab.selectedTabDefaultsKey)
        tab = SettingsTab(rawValue: stored ?? "") ?? .appearance
    }

    public func open(_ tab: SettingsTab? = nil) {
        if let tab { self.tab = tab }
        isPresented = true
    }

    public func close() {
        isPresented = false
    }
}
