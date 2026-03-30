import CoreGraphics
import Foundation

/// One rectangular redaction region in a document page’s media-box coordinate space.
struct RedactionMark: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Zero-based page index.
    var pageIndex: Int
    /// Rectangle in `PDFPage` media box space (PDF user space).
    var rect: CGRect

    init(id: UUID = UUID(), pageIndex: Int, rect: CGRect) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = rect
    }
}

enum RedactionMarkGeometry {
    static let minimumSidePt: CGFloat = 4

    static func normalizedDragRect(start: CGPoint, end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    static func isMeaningful(_ rect: CGRect) -> Bool {
        rect.width >= minimumSidePt && rect.height >= minimumSidePt
    }

    static func clipToMediaBox(_ rect: CGRect, mediaBox: CGRect) -> CGRect? {
        let i = rect.intersection(mediaBox)
        guard i.width >= minimumSidePt / 2, i.height >= minimumSidePt / 2 else { return nil }
        return i
    }
}
