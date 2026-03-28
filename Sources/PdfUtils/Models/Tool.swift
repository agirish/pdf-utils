import SwiftUI

enum Tool: String, CaseIterable, Identifiable, Hashable {
    case compress
    case rotate
    case merge
    case extract
    case deletePages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "Compress PDF"
        case .rotate: return "Rotate PDF"
        case .merge: return "Merge PDF"
        case .extract: return "Extract PDF Pages"
        case .deletePages: return "Delete PDF Pages"
        }
    }

    var subtitle: String {
        switch self {
        case .compress:
            return "Shrink file size for sharing"
        case .rotate:
            return "Turn pages 90° at a time"
        case .merge:
            return "Combine PDFs in order"
        case .extract:
            return "Save selected pages as a new PDF"
        case .deletePages:
            return "Remove unwanted pages"
        }
    }

    var symbolName: String {
        switch self {
        case .compress: return "arrow.down.doc"
        case .rotate: return "rotate.right"
        case .merge: return "square.stack.3d.up"
        case .extract: return "doc.on.clipboard"
        case .deletePages: return "doc.badge.minus"
        }
    }

    var accent: Color {
        switch self {
        case .compress: return .orange
        case .rotate: return .blue
        case .merge: return .purple
        case .extract: return .teal
        case .deletePages: return .pink
        }
    }
}
