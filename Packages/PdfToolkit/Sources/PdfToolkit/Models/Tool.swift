import SwiftUI

public enum Tool: String, CaseIterable, Identifiable, Hashable {
    case compress
    case rotate
    case merge
    case extract
    case deletePages
    case redact

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compress: return "Compress PDF"
        case .rotate: return "Rotate PDF"
        case .merge: return "Merge PDF"
        case .extract: return "Extract PDF Pages"
        case .deletePages: return "Delete PDF Pages"
        case .redact: return "Redact PDF"
        }
    }

    public var subtitle: String {
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
        case .redact:
            return "Permanently black out sensitive areas"
        }
    }

    /// Short paragraph shown under the navigation area on each tool screen.
    public var headerDescription: String {
        switch self {
        case .compress:
            return "Rebuilds each page as an image to reduce file size—best for scans and photos. Vector text may become non-selectable; use the quality slider to balance size and sharpness."
        case .rotate:
            return "Turn every page or only the pages you list. Rotation is written into a new PDF; your original file stays untouched until you save over it from the save panel."
        case .merge:
            return "Stack several PDFs into one file in the order shown. Use the arrows beside each row to change order, or remove a file from the list without deleting it from disk."
        case .extract:
            return "Copy chosen pages into a new PDF in the order you type (for example 5,1,2). Handy for pulling chapters or attachments out of a larger document."
        case .deletePages:
            return "Produce a new PDF without the pages you specify. You must list which pages to drop—an empty field will not delete everything. At least one page must remain."
        case .redact:
            return "Draw rectangles over names, account numbers, or images you want gone for good. Marked regions are rebuilt as solid black—text there can’t be copied or searched. Everything runs on your Mac; review marks before exporting."
        }
    }

    public var symbolName: String {
        switch self {
        case .compress: return "arrow.down.doc"
        case .rotate: return "rotate.right"
        case .merge: return "square.stack.3d.up"
        case .extract: return "doc.on.clipboard"
        // Badge-style "doc" symbols can look blank with hierarchical tinting on dashboard tiles; use a solid portrait-page + minus.
        case .deletePages: return "minus.rectangle.portrait.fill"
        case .redact: return "eraser.line.dashed"
        }
    }

    public var accent: Color {
        switch self {
        case .compress: return .orange
        case .rotate: return .blue
        case .merge: return .purple
        case .extract: return .teal
        case .deletePages: return .pink
        case .redact: return Color(red: 0.78, green: 0.16, blue: 0.22)
        }
    }
}
