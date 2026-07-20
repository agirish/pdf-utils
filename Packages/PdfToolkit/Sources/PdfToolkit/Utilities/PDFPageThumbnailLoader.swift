import AppKit
import PDFKit

/// One rendered page thumbnail for preview grids (every grid, Merge's included, sizes via
/// ``PDFPageThumbnailLoader/thumbnailBox(for:maxSide:)``).
/// `NSImage` is not `Sendable`; thumbnails are produced on the PDF serial queue and consumed on the main actor only.
struct PDFPageThumbnail: Identifiable, @unchecked Sendable {
    var id: Int { pageNumber }
    let pageNumber: Int
    let image: NSImage
}

enum PDFPageThumbnailLoader {
    /// The box to hand `PDFPage.thumbnail(of:for:.mediaBox)` for a ≤`maxSide`-pt preview.
    ///
    /// Must use the DISPLAYED orientation: `thumbnail(of:for:)` renders with /Rotate applied and
    /// aspect-fits into the box, so sizing from the raw media box constrained a rotated page to
    /// the box's short side (~309 pt instead of 400 for a /Rotate 90 US Letter) — visibly softer
    /// thumbnails. The single sizing authority for every preview grid (including Merge's inline
    /// sweep, which once carried a diverged copy of this math).
    static func thumbnailBox(for page: PDFPage, maxSide: CGFloat = 400) -> NSSize {
        let raw = page.bounds(for: .mediaBox).size
        let rotation = ((page.rotation % 360) + 360) % 360
        let size = (rotation == 90 || rotation == 270)
            ? CGSize(width: raw.height, height: raw.width)
            : raw
        let longest = max(size.width, size.height)
        let scale = min(1.0, maxSide / max(longest, 1))
        return NSSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }

    static func loadAllPages(from url: URL) async throws -> [PDFPageThumbnail] {
        try await PDFBackgroundWork.run { isCancelled in
            try url.withSecurityScopedAccess {
                guard let doc = PDFDocument(url: url) else {
                    throw PDFOperationError.couldNotOpen(url)
                }
                var items: [PDFPageThumbnail] = []
                for i in 0..<doc.pageCount {
                    // Task.checkCancellation() is inert on the GCD queue; only this probe can see
                    // the caller's cancellation and stop a superseded sweep early.
                    if isCancelled() { throw CancellationError() }
                    guard let page = doc.page(at: i) else { continue }
                    let image = page.thumbnail(of: thumbnailBox(for: page), for: .mediaBox)
                    items.append(PDFPageThumbnail(pageNumber: i + 1, image: image))
                }
                return items
            }
        }
    }
}
