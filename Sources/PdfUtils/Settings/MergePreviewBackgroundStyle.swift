import Foundation

/// Background for the merge tool’s right-hand preview column.
enum MergePreviewBackgroundStyle: String, CaseIterable, Identifiable {
    case white
    case systemWindow
    case matchMain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "White"
        case .systemWindow: return "System window"
        case .matchMain: return "Match main background"
        }
    }

    var detail: String {
        switch self {
        case .white: return "Clean white canvas behind thumbnails."
        case .systemWindow: return "Same flat color as standard window chrome."
        case .matchMain: return "Mirrors the main window mode (including liquid glass)."
        }
    }
}
