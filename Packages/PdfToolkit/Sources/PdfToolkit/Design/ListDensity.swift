import SwiftUI

/// How tightly the app's lists (Merge, Reorder) pack their rows — an appearance option mirroring
/// SyncCloud's `Design/ListDensity`. Comfortable is the standard look; Compact tightens rows so
/// more fits on screen. Stored via `ListDensity.defaultsKey`.
public enum ListDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    /// UserDefaults key for the selected density (raw value). Read via `@AppStorage` by the Settings
    /// Appearance tab and every list view that honors it.
    public static let defaultsKey = "pdfutils.listDensity"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// Vertical padding applied to a list row at this density.
    public var rowVerticalPadding: CGFloat {
        switch self {
        case .comfortable: return 4
        case .compact: return 1
        }
    }

    /// Vertical inset used in a row's `listRowInsets` at this density.
    public var rowInsetVertical: CGFloat {
        switch self {
        case .comfortable: return 6
        case .compact: return 2
        }
    }
}
