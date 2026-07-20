import SwiftUI

/// How tightly the Activity Log packs its rows — Comfortable shows a roomy multi-line entry (with the
/// file location); Compact collapses each entry to a single line so more history fits. Chosen from the
/// Activity Log window's toolbar (not Settings), and stored via `ListDensity.defaultsKey`.
public enum ListDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    /// UserDefaults key for the selected density (raw value). Read via `@AppStorage` by the Activity
    /// Log window, which both sets it and honors it.
    public static let defaultsKey = "pdfutils.listDensity"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// Vertical padding applied to an Activity Log row at this density.
    public var rowVerticalPadding: CGFloat {
        switch self {
        case .comfortable: return 4
        case .compact: return 1
        }
    }
}
