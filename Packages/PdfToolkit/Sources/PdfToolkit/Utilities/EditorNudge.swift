import CoreGraphics

/// Pure geometry shared by the three direct editors' arrow-key nudge. Kept free of PDFKit/AppKit so
/// the zoom-independence and clamp behaviour are unit-testable; the coordinators supply the one
/// PDFKit-dependent step (mapping a screen direction to a raw page-space vector via `pdfView.convert`).
enum EditorNudge {
    /// Rescales a raw page-space vector to a fixed page-point magnitude, preserving direction. The raw
    /// vector comes from converting a screen-space step through the view, so its length carries the
    /// zoom (step ÷ scaleFactor); rescaling to `length` makes a nudge move a fixed number of *page*
    /// points no matter how far in the page is zoomed. A zero vector stays zero.
    static func scaled(_ raw: CGSize, to length: CGFloat) -> CGSize {
        let magnitude = (raw.width * raw.width + raw.height * raw.height).squareRoot()
        guard magnitude > 0 else { return .zero }
        let k = length / magnitude
        return CGSize(width: raw.width * k, height: raw.height * k)
    }

    /// Slides `rect` by `delta` and keeps it inside `box` **without resizing** — the move-clamp an
    /// arrow nudge needs. Larger-than-page rects are shrunk to fit first (defensive; a crop/redaction
    /// rect is already within the box), then pushed back from whichever edge they overhang.
    static func moved(_ rect: CGRect, by delta: CGSize, within box: CGRect) -> CGRect {
        var r = CGRect(
            x: rect.origin.x + delta.width,
            y: rect.origin.y + delta.height,
            width: min(rect.width, box.width),
            height: min(rect.height, box.height)
        )
        if r.minX < box.minX { r.origin.x = box.minX }
        if r.minY < box.minY { r.origin.y = box.minY }
        if r.maxX > box.maxX { r.origin.x = box.maxX - r.width }
        if r.maxY > box.maxY { r.origin.y = box.maxY - r.height }
        return r
    }
}
