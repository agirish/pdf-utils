import AppKit
import SwiftUI

// MARK: - Theme (aligned with SyncCloud `Modules/Design/AppearanceMode`)

/// Light / dark / follow-macOS theme choice.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    /// Follow the macOS appearance and keep following it if the system flips mid-session.
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var detail: String {
        switch self {
        case .system: return "Match macOS and follow it when the system appearance changes."
        case .light: return "Always use the light appearance."
        case .dark: return "Always use the dark appearance."
        }
    }

    public var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// `nil` means "inherit the system appearance" — load-bearing for `.system`, the only case
    /// that tracks a mid-session system flip.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies the chosen theme to `NSApplication`, not just the SwiftUI tree.
///
/// `View.preferredColorScheme` only reaches the SwiftUI views of one scene. The theme must also
/// cover AppKit surfaces that inherit from `NSApp`: the unified title-bar band, `NSOpenPanel` /
/// `NSSavePanel`, `NSAlert`, and the separate Settings window. Setting `NSApp.appearance` (and
/// stamping every existing window) is what makes the whole app track the choice — the per-window
/// pass exists because the macOS 26 glass title-bar keeps drawing with a window's creation
/// appearance until the window is told otherwise.
@MainActor
public enum AppAppearance {
    public static func resolved(_ defaults: UserDefaults = .standard) -> AppearanceMode {
        AppearanceMode(rawValue: defaults.string(forKey: LiquidGlass.appearanceModeKey) ?? "") ?? .system
    }

    public static func apply(_ mode: AppearanceMode) {
        let appearance = mode.nsAppearance
        NSApplication.shared.appearance = appearance
        for window in NSApplication.shared.windows {
            window.appearance = appearance
        }
    }

    public static func applyPersisted(_ defaults: UserDefaults = .standard) {
        apply(resolved(defaults))
    }
}
