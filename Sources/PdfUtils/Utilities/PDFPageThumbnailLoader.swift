import AppKit
import PDFKit

/// One rendered page thumbnail for preview grids (same scale heuristic as Merge PDF).
/// `NSImage` is not `Sendable`; thumbnails are produced on the PDF serial queue and consumed on the main actor only.
struct PDFPageThumbnail: Identifiable, @unchecked Sendable {
    var id: Int { pageNumber }
    let pageNumber: Int
    let image: NSImage
}

enum PDFPageThumbnailLoader {
    static func loadAllPages(from url: URL) async throws -> [PDFPageThumbnail] {
        try await PDFBackgroundWork.run {
            try url.withSecurityScopedAccess {
                guard let doc = PDFDocument(url: url) else {
                    throw PDFOperationError.couldNotOpen(url)
                }
                var items: [PDFPageThumbnail] = []
                for i in 0..<doc.pageCount {
                    try Task.checkCancellation()
                    guard let page = doc.page(at: i) else { continue }
                    let size = page.bounds(for: .mediaBox).size
                    let longest = max(size.width, size.height)
                    let scale = min(1.0, 400.0 / longest)
                    let thumbSize = NSSize(
                        width: max(1, size.width * scale),
                        height: max(1, size.height * scale)
                    )
                    let image = page.thumbnail(of: thumbSize, for: .mediaBox)
                    items.append(PDFPageThumbnail(pageNumber: i + 1, image: image))
                }
                return items
            }
        }
    }
}
