import AppKit
import SwiftUI

/// One thumbnail cell, read straight from the shared LRU in `body` — the cell holds NO image state
/// of its own, which is what keeps a long document's resident cost at the cache's cap instead of one
/// image per created cell. On a cache miss the task renders off-main, stores, and bumps `tick` to
/// repaint. Visible cells touch the LRU every body pass, so eviction only ever takes offscreen
/// entries.
///
/// Keyed on a plain `cacheKey` + a no-arg `render` so it serves every grid identically: the page
/// preview columns pass `spec.cacheKey` and close over their spec; the Reorder sidebar row passes the
/// same key its preview cell uses, so a row and its cell share one render. The framing (size, corner
/// radius, borders, badges) lives in each caller's wrapper — this type only owns the load/repaint loop.
struct CachedThumbnailCell: View {
    /// The miss-state placeholder. The preview grids show a US-Letter sheet with a spinner until the
    /// first render attempt finishes; the tiny Reorder sidebar glyph shows bare white, where a spinner
    /// would just be noise.
    enum Placeholder {
        case letterSheet
        case blank
    }

    let cacheKey: String
    var placeholder: Placeholder = .letterSheet
    let render: () async -> NSImage?

    init(cacheKey: String, placeholder: Placeholder = .letterSheet, render: @escaping () async -> NSImage?) {
        self.cacheKey = cacheKey
        self.placeholder = placeholder
        self.render = render
    }

    /// Repaint trigger after a store; the image itself deliberately lives only in the cache.
    @State private var tick = 0
    /// True once a render attempt finished — a page that can't render (a damaged or locked entry)
    /// shows a plain sheet instead of an eternal spinner. Only consulted by `.letterSheet`.
    @State private var attempted = false

    var body: some View {
        Group {
            if let image = PreviewThumbnailCache.shared.image(for: cacheKey) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                switch placeholder {
                case .letterSheet:
                    // US Letter aspect placeholder; the cell reflows to the true aspect when loaded.
                    Color.white
                        .aspectRatio(8.5 / 11, contentMode: .fit)
                        .overlay {
                            if !attempted {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                case .blank:
                    Color.white
                }
            }
        }
        .id(tick)
        .task(id: cacheKey) {
            guard PreviewThumbnailCache.shared.image(for: cacheKey) == nil else { return }
            attempted = false
            let rendered = await render()
            guard !Task.isCancelled else { return }
            if let rendered {
                PreviewThumbnailCache.shared.store(rendered, for: cacheKey)
            }
            attempted = true
            tick += 1
        }
    }
}
