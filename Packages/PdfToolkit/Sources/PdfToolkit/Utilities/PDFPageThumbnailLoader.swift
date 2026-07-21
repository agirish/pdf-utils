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

    // MARK: Demand loading

    /// Documents kept open across per-page loads, keyed by path + modification date so an
    /// externally edited file misses. Accessed ONLY on the PDF serial queue (PDFBackgroundWork) —
    /// that queue is the sole executor for every closure that touches this, which is what makes
    /// the unsynchronized static safe. Tiny cap: the preview grids show at most a few documents.
    private nonisolated(unsafe) static var openDocuments: [(key: String, doc: PDFDocument)] = []
    private static let openDocumentCapacity = 4

    /// On-queue only. Opens (or reuses) the document and applies the locked-document gate.
    ///
    /// The gate lives HERE, not per call site: a locked document reports a real page count and
    /// renders every page as a blank placeholder, so an ungated caller shows a normal-looking grid
    /// of empty pages. Three separate rounds of review found call sites that missed a caller-side
    /// check — putting the refusal inside the one loader they all share is the only shape a future
    /// call site can't get wrong.
    private static func cachedDocument(at url: URL) throws -> PDFDocument {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)@\(modified)"
        if let hit = openDocuments.first(where: { $0.key == key }) {
            return hit.doc
        }
        guard let doc = PDFDocument(url: url) else {
            throw PDFOperationError.couldNotOpen(url)
        }
        guard !doc.isLocked else {
            throw PDFOperationError.encryptedInput(url)
        }
        openDocuments.append((key, doc))
        if openDocuments.count > openDocumentCapacity {
            openDocuments.removeFirst()
        }
        return doc
    }

    /// The page count a preview grid should build cells for — fast (no rendering), and the
    /// entry point that surfaces the locked-document refusal before any cell exists.
    static func pageCount(of url: URL) async throws -> Int {
        try await PDFBackgroundWork.run {
            try url.withSecurityScopedAccess {
                try cachedDocument(at: url).pageCount
            }
        }
    }

    /// One page's thumbnail, rendered on demand — the unit the virtualized preview grid loads as
    /// cells appear, instead of sweeping every page of the document up front.
    static func loadPage(from url: URL, pageIndex: Int) async throws -> PDFPageThumbnail? {
        try await PDFBackgroundWork.run {
            try url.withSecurityScopedAccess {
                let doc = try cachedDocument(at: url)
                // Per-render pool: page-sized scratch drains with the call, not the queue's lifetime.
                return autoreleasepool {
                    guard let page = doc.page(at: pageIndex) else { return nil }
                    let image = page.thumbnail(of: thumbnailBox(for: page), for: .mediaBox)
                    return PDFPageThumbnail(pageNumber: pageIndex + 1, image: image)
                }
            }
        }
    }
}
