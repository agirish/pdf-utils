import AppKit
import Foundation

/// The identity of one preview-grid cell: its 1-based display number (badges, the selection layer)
/// and a stable cache key that survives list reordering — reordering rows just remaps positions to
/// keys, and every already-rendered cell is a cache hit instead of a re-render.
///
/// Keys are content-addressed by convention: `<path>@<mtime>` for whole images,
/// `<path>@<mtime>#<pageIndex>` for PDF pages — so an externally modified file naturally misses
/// and stale entries age out of the LRU without explicit invalidation.
struct PreviewPageSpec: Identifiable, Hashable, Sendable {
    let id: Int
    let cacheKey: String

    /// Specs for every page of one PDF, keyed so reorder/re-pick of the same unchanged file hits.
    static func specs(forPDFAt url: URL, pageCount: Int) -> [PreviewPageSpec] {
        guard pageCount > 0 else { return [] }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? 0
        let base = "\(url.path)@\(modified)"
        return (1...pageCount).map { PreviewPageSpec(id: $0, cacheKey: "\(base)#\($0 - 1)") }
    }

    /// The cache key for one non-PDF file (an image row in Images to PDF).
    static func fileKey(for url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)@\(modified)"
    }
}

/// LRU cache of rendered preview images, shared by every preview grid.
///
/// This is what makes the grids virtualized: cells hold no image state of their own — they read
/// this cache in `body` and populate it on demand — so a 500-page document resident in a grid
/// costs at most `capacity` thumbnails, not 500. Main-actor because the images are UI-only; the
/// rendering itself happens off-main in each grid's `render` closure. Reads refresh recency, so
/// visible cells are never the ones evicted (capacity comfortably exceeds a screenful).
@MainActor
final class PreviewThumbnailCache {
    static let shared = PreviewThumbnailCache()

    /// ~45 MB worst case at 400-pt renders — flat regardless of document length.
    private let capacity = 180
    private var images: [String: NSImage] = [:]
    /// Least-recently-used first.
    private var order: [String] = []

    func image(for key: String) -> NSImage? {
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    func store(_ image: NSImage, for key: String) {
        if images[key] == nil, images.count >= capacity, let oldest = order.first {
            images.removeValue(forKey: oldest)
            order.removeFirst()
        }
        images[key] = image
        touch(key)
    }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}
