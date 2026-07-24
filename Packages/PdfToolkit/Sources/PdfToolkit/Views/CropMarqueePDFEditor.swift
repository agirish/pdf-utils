import AppKit
import PDFKit
import SwiftUI

/// The eight resize handles of a crop marquee, and the edges each one moves.
private enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Which view-space edges this handle drags. Named by the *visual* frame — with the overlay in
    /// AppKit's non-flipped (y-up) space, "top" is `maxY` and "bottom" is `minY`.
    var edges: (left: Bool, right: Bool, bottom: Bool, top: Bool) {
        switch self {
        case .topLeft:     return (true, false, false, true)
        case .top:         return (false, false, false, true)
        case .topRight:    return (false, true, false, true)
        case .right:       return (false, true, false, false)
        case .bottomRight: return (false, true, true, false)
        case .bottom:      return (false, false, true, false)
        case .bottomLeft:  return (true, false, true, false)
        case .left:        return (true, false, false, false)
        }
    }

    /// The handle's centre on a view-space selection rect.
    func center(in rect: CGRect) -> CGPoint {
        let midX = rect.midX, midY = rect.midY
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:         return CGPoint(x: midX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return CGPoint(x: rect.maxX, y: midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return CGPoint(x: midX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: midY)
        }
    }
}

/// A single-page PDF preview the user drags a crop rectangle on. The page renders underneath; a
/// dimmed scrim covers everything outside the selection, which carries eight resize handles (four
/// corners + four edge midpoints).
///
/// The selection is two-way bound to displayed-edge ``CropInsets``: a drag rewrites the insets live,
/// and typing into the numeric fields nudges the box — because the marquee, expressed in stored page
/// space, is exactly ``PDFToolkit/insetRect(_:rotation:by:)`` applied to the crop box, and reading it
/// back is ``PDFToolkit/insets(from:rotation:in:)``. All page↔view mapping goes through
/// `pdfView.convert`, so a rotated page or a non-zero-origin crop box needs no special-casing here.
struct CropMarqueePDFEditor: NSViewRepresentable {
    let document: PDFDocument
    /// 0-based index of the page being drawn on.
    let pageIndex: Int
    @Binding var insets: CropInsets
    /// Fit-to-view zoom multiplier from the slider — 1 fits the whole page to the pane.
    let zoom: CGFloat
    let accent: Color
    /// True from a drag's start to its end, so the tool records the whole drag as one undo step.
    @Binding var isInteracting: Bool
    /// ⌘Z / ⌘⇧Z, routed to the tool's shared history while the marquee holds keyboard focus.
    var onUndo: () -> Void
    var onRedo: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let pdfView = PDFView()
        pdfView.disableLiveTextAnalysis()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .clear
        pdfView.document = document

        let overlay = CropMarqueeOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        overlay.pdfView = pdfView
        overlay.accent = NSColor(accent)

        container.addSubview(pdfView)
        container.addSubview(overlay)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pdfView.addGestureRecognizer(pan)

        let coordinator = context.coordinator
        overlay.onKeyDown = { [weak coordinator] event in coordinator?.handleKeyDown(event) ?? false }

        coordinator.pdfView = pdfView
        coordinator.overlay = overlay
        coordinator.syncPageAndSelection()
        // Focus the marquee so arrow-key nudging works as soon as the drag pane appears. The window
        // isn't attached yet inside makeNSView, so defer to the next runloop turn; clicking a sidebar
        // inset field still takes focus away normally.
        DispatchQueue.main.async { [weak overlay] in
            guard let overlay, let window = overlay.window, window.firstResponder === window else { return }
            window.makeFirstResponder(overlay)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        guard let pdfView = context.coordinator.pdfView,
              let overlay = context.coordinator.overlay else { return }

        if pdfView.document !== document { pdfView.document = document }
        overlay.accent = NSColor(accent)

        // Zoom 1 = fit and keep fitting as the pane resizes; beyond 1, pin an explicit scale.
        let shouldAutoScale = zoom <= 1.0001
        if pdfView.autoScales != shouldAutoScale { pdfView.autoScales = shouldAutoScale }
        if !shouldAutoScale {
            let fit = pdfView.scaleFactorForSizeToFit
            if fit > 0 { pdfView.scaleFactor = fit * zoom }
        }

        context.coordinator.syncPageAndSelection()
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var parent: CropMarqueePDFEditor
        weak var pdfView: PDFView?
        fileprivate weak var overlay: CropMarqueeOverlayView?

        private enum DragKind {
            case create
            case move
            case resize(CropHandle)
        }
        private var dragKind: DragKind?
        /// Cached loupe render, keyed by the page and its on-screen size — see `loupeSourceImage()`.
        private var loupeSource: (page: PDFPage, size: CGSize, image: NSImage)?
        private var dragStartMouse: CGPoint = .zero
        private var dragStartRectView: CGRect = .zero
        /// True from a drag's `.began` to its `.ended`; suppresses the field→box sync so a live drag
        /// (which writes the insets) never fights itself when SwiftUI re-runs `updateNSView`.
        private(set) var isDragging = false

        init(_ parent: CropMarqueePDFEditor) { self.parent = parent }

        /// The page currently being drawn on, resolved from the binding — not from `pdfView.currentPage`,
        /// which lags a `go(to:)` and would desync the overlay from the gesture during a page switch.
        private var activePage: PDFPage? {
            let count = parent.document.pageCount
            guard count > 0 else { return nil }
            return parent.document.page(at: min(max(parent.pageIndex, 0), count - 1))
        }

        /// Points a crop-side of `minimumCropSide` occupies at the current zoom, so the min-size clamp
        /// is enforced in the same view space the drag math runs in.
        private var minSideView: CGFloat {
            PDFToolkit.minimumCropSide * (pdfView?.scaleFactor ?? 1)
        }

        /// Shows the bound page and redraws the marquee the current insets describe. Skipped mid-drag,
        /// where the drag owns the selection and is busy writing the insets the other direction.
        func syncPageAndSelection() {
            guard let pdfView, let overlay, let page = activePage else { return }
            if pdfView.currentPage !== page { pdfView.go(to: page) }
            overlay.page = page
            guard !isDragging else { return }
            let box = page.bounds(for: .cropBox)
            overlay.selectionPageRect = PDFToolkit.insetRect(box, rotation: page.rotation, by: parent.insets)
            overlay.needsDisplay = true
        }

        // MARK: Hit testing (view space)

        private func selectionViewRect() -> CGRect? {
            guard let pdfView, let overlay, let page = activePage, let sel = overlay.selectionPageRect else { return nil }
            return pdfView.convert(sel, from: page)
        }

        private func kind(at loc: CGPoint) -> DragKind {
            if let selView = selectionViewRect() {
                // Nearest handle within grab range wins, so overlapping targets at a tiny selection
                // resolve to the corner the press is actually closest to rather than iteration order.
                var best: (handle: CropHandle, distance: CGFloat)?
                for handle in CropHandle.allCases {
                    let c = handle.center(in: selView)
                    let d = hypot(loc.x - c.x, loc.y - c.y)
                    if d <= CropMarqueeOverlayView.handleHitRadius, d < (best?.distance ?? .greatestFiniteMagnitude) {
                        best = (handle, d)
                    }
                }
                if let best { return .resize(best.handle) }
                if selView.contains(loc) { return .move }
            }
            return .create
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            guard let pdfView, let page = activePage else { return false }
            let loc = gestureRecognizer.location(in: pdfView)
            // A press on a handle must start the drag even when it lands a hair off the page — the
            // top and right handles sit exactly on the page's max edges, which `CGRect.contains`
            // treats as outside, so grabbing them was impossible. Accept the whole page grown by the
            // handle grab radius so every edge and corner handle is reachable from the page boundary.
            let pageView = pdfView.convert(page.bounds(for: .cropBox), from: page)
            return pageView.insetBy(dx: -CropMarqueeOverlayView.handleHitRadius,
                                    dy: -CropMarqueeOverlayView.handleHitRadius).contains(loc)
        }

        @objc func handlePan(_ g: NSPanGestureRecognizer) {
            guard let pdfView, let overlay, let page = activePage else { return }
            let loc = g.location(in: pdfView)

            switch g.state {
            case .began:
                isDragging = true
                // One undo step per drag: the tool defers its history push until this settles.
                parent.isInteracting = true
                // A drag focuses the marquee, so arrow-nudge and ⌘Z work right after it.
                if let window = overlay.window, window.firstResponder !== overlay {
                    window.makeFirstResponder(overlay)
                }
                dragStartMouse = loc
                let hit = kind(at: loc)
                dragKind = hit
                if case .create = hit {
                    dragStartRectView = CGRect(origin: loc, size: .zero)
                    overlay.selectionPageRect = pdfView.convert(CGRect(origin: loc, size: .zero), to: page)
                } else {
                    dragStartRectView = selectionViewRect() ?? CGRect(origin: loc, size: .zero)
                }
                // Bring up the loupe for edge/corner work: snapshot the page once (it doesn't move
                // during a crop drag) and mark the point being dragged. Skipped for a whole-box move,
                // where there's no single edge to zoom in on.
                if let focus = loupeFocus(kind: hit, mouse: loc) {
                    overlay.loupeSnapshot = loupeSourceImage()
                    overlay.loupeFocusPoint = focus
                }

            case .changed:
                guard let kind = dragKind else { return }
                let pageView = pdfView.convert(page.bounds(for: .cropBox), from: page)
                let newView = resolvedRect(kind: kind, current: loc, page: pageView)
                let pageRect = pdfView.convert(newView, to: page)
                overlay.selectionPageRect = pageRect
                if overlay.loupeSnapshot != nil {
                    overlay.loupeFocusPoint = loupeFocus(kind: kind, mouse: loc, selView: newView)
                }
                overlay.needsDisplay = true
                parent.insets = PDFToolkit.insets(from: pageRect, rotation: page.rotation, in: page.bounds(for: .cropBox))

            case .ended, .cancelled:
                isDragging = false
                dragKind = nil
                overlay.loupeSnapshot = nil
                overlay.loupeFocusPoint = nil
                overlay.needsDisplay = true
                // Flip LAST — the tool commits the settled drag when this goes false.
                parent.isInteracting = false

            default:
                break
            }
        }

        // MARK: Loupe

        /// The point the loupe magnifies for a drag: the corner/edge handle being dragged, or the live
        /// corner of a freshly drawn box. Nil for a whole-box move — there's no single edge to zoom.
        private func loupeFocus(kind: DragKind, mouse loc: CGPoint, selView: CGRect? = nil) -> CGPoint? {
            switch kind {
            case .move: return nil
            case .create: return loc
            case .resize(let handle):
                let rect = selView ?? selectionViewRect()
                return rect.map { handle.center(in: $0) } ?? loc
            }
        }

        /// The page rendered for the loupe to magnify, cached across drags.
        ///
        /// Rendered with PDFKit rather than snapshotted off the `PDFView`: PDFView draws its page
        /// through CALayer content, which `cacheDisplay(in:to:)` does not capture, so snapshotting
        /// produced a blank bitmap and the loupe showed an empty circle. `thumbnail(of:for:.cropBox)`
        /// renders the page exactly as displayed (rotation and crop applied), so it lines up 1:1 with
        /// the page rect in view space. Rendered at the loupe's magnification so the zoom stays sharp,
        /// and reused until the page or its on-screen size changes — a crop drag never changes either.
        private func loupeSourceImage() -> NSImage? {
            guard let pdfView, let page = activePage else { return nil }
            let pageRect = pdfView.convert(page.bounds(for: .cropBox), from: page)
            guard pageRect.width > 1, pageRect.height > 1 else { return nil }
            if let cached = loupeSource, cached.page === page,
               abs(cached.size.width - pageRect.width) < 0.5,
               abs(cached.size.height - pageRect.height) < 0.5 {
                return cached.image
            }
            let scale = CropMarqueeOverlayView.loupeMagnification
            let image = page.thumbnail(
                of: NSSize(width: pageRect.width * scale, height: pageRect.height * scale),
                for: .cropBox
            )
            loupeSource = (page, pageRect.size, image)
            return image
        }

        // MARK: Keyboard editing

        func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let command = EditorKeyMapping.command(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers?.lowercased(),
                hasCommand: event.modifierFlags.contains(.command),
                hasShift: event.modifierFlags.contains(.shift)
            ) else { return false }

            switch command {
            case .undo: parent.onUndo(); return true
            case .redo: parent.onRedo(); return true
            case .delete: return false  // Crop has one persistent marquee; nothing to delete.
            case .nudge(let dx, let dy): return nudgeMarquee(dx: dx, dy: dy)
            }
        }

        /// Slides the whole crop marquee by a fixed page-point step in the arrow's screen direction —
        /// zoom-independent and rotation-correct — and writes the resulting insets back. One mutation,
        /// so the tool records it as a single undo step.
        private func nudgeMarquee(dx: CGFloat, dy: CGFloat) -> Bool {
            guard let pdfView, let overlay, let page = activePage,
                  let sel = overlay.selectionPageRect else { return false }
            let step = max(abs(dx), abs(dy))
            let flip: CGFloat = pdfView.isFlipped ? -1 : 1
            let base = pdfView.convert(CGPoint.zero, to: page)
            let tip = pdfView.convert(CGPoint(x: dx, y: dy * flip), to: page)
            let delta = EditorNudge.scaled(CGSize(width: tip.x - base.x, height: tip.y - base.y), to: step)
            let box = page.bounds(for: .cropBox)
            let moved = EditorNudge.moved(sel, by: delta, within: box)
            overlay.selectionPageRect = moved
            overlay.needsDisplay = true
            parent.insets = PDFToolkit.insets(from: moved, rotation: page.rotation, in: box)
            return true
        }

        /// Turns the drag delta into a clamped view-space selection rect for the current handle/mode.
        private func resolvedRect(kind: DragKind, current loc: CGPoint, page pageView: CGRect) -> CGRect {
            let start = dragStartRectView
            switch kind {
            case .create:
                let rect = CGRect(x: min(dragStartMouse.x, loc.x), y: min(dragStartMouse.y, loc.y),
                                  width: abs(loc.x - dragStartMouse.x), height: abs(loc.y - dragStartMouse.y))
                return clampResize(rect, in: pageView)

            case .move:
                let dx = loc.x - dragStartMouse.x
                let dy = loc.y - dragStartMouse.y
                return clampMove(start.offsetBy(dx: dx, dy: dy), size: start.size, in: pageView)

            case .resize(let handle):
                let dx = loc.x - dragStartMouse.x
                let dy = loc.y - dragStartMouse.y
                let e = handle.edges
                var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
                if e.left { minX += dx }
                if e.right { maxX += dx }
                if e.bottom { minY += dy }
                if e.top { maxY += dy }
                if minX > maxX { swap(&minX, &maxX) }
                if minY > maxY { swap(&minY, &maxY) }
                return clampResize(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), in: pageView)
            }
        }

        /// Keeps a resized/created rect inside the page and no smaller than the minimum crop side,
        /// growing back toward whichever side has room so the box never escapes the page edge.
        private func clampResize(_ rect: CGRect, in page: CGRect) -> CGRect {
            var minX = max(rect.minX, page.minX)
            var maxX = min(rect.maxX, page.maxX)
            var minY = max(rect.minY, page.minY)
            var maxY = min(rect.maxY, page.maxY)
            let minSide = min(minSideView, min(page.width, page.height))
            if maxX - minX < minSide {
                if minX + minSide <= page.maxX { maxX = minX + minSide } else { minX = maxX - minSide }
            }
            if maxY - minY < minSide {
                if minY + minSide <= page.maxY { maxY = minY + minSide } else { minY = maxY - minSide }
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        /// Slides a fixed-size rect back inside the page without changing its size (the move drag).
        private func clampMove(_ rect: CGRect, size: CGSize, in page: CGRect) -> CGRect {
            let x = min(max(rect.minX, page.minX), max(page.minX, page.maxX - size.width))
            let y = min(max(rect.minY, page.minY), max(page.minY, page.maxY - size.height))
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }
}

/// Transparent overlay above the `PDFView` that draws the marquee: a dimmed scrim over the page
/// outside the selection, the selection border, and the eight resize handles. Hit-testing passes
/// through so the `PDFView`'s pan recognizer receives every event (the coordinator drives edits).
fileprivate final class CropMarqueeOverlayView: PDFViewSyncedOverlay {
    /// Half-size of a drawn knob.
    static let handleSide: CGFloat = 7
    /// Grab radius for hit-testing — far larger than the knob so corners and edges (including the
    /// ones flush with the page boundary) are easy to catch. See `Coordinator.kind(at:)`.
    static let handleHitRadius: CGFloat = 18

    private static let loupeRadius: CGFloat = 58
    /// Also the scale the loupe's page render is produced at, so magnifying it stays sharp.
    static let loupeMagnification: CGFloat = 2.5

    weak var page: PDFPage?
    /// The selection in stored page space; the one source of truth the coordinator writes and reads.
    var selectionPageRect: CGRect?
    var accent: NSColor = .systemGreen

    /// While a corner/edge drag is live: a still of the page to magnify, and the point to centre on.
    /// Both nil at rest and during a whole-box move, so the loupe shows only when trimming an edge.
    var loupeSnapshot: NSImage?
    var loupeFocusPoint: CGPoint?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let page = page ?? pdfView.currentPage else { return }
        let pageView = pdfView.convert(page.bounds(for: .cropBox), from: page)
        guard let sel = selectionPageRect else { return }
        let selView = pdfView.convert(sel, from: page).intersection(pageView)

        // Dim everything on the page outside the selection (even-odd = page minus selection).
        let scrim = NSBezierPath(rect: pageView)
        scrim.append(NSBezierPath(rect: selView))
        scrim.windingRule = .evenOdd
        NSColor(calibratedWhite: 0, alpha: 0.45).setFill()
        scrim.fill()

        guard selView.width > 1, selView.height > 1 else { return }

        // Selection border.
        let border = NSBezierPath(rect: selView)
        border.lineWidth = 1.5
        accent.setStroke()
        border.stroke()

        // Eight knobs: white fill + accent ring, legible over both the bright page and the scrim.
        let knob = CropMarqueeOverlayView.handleSide
        for handle in CropHandle.allCases {
            let c = handle.center(in: selView)
            let square = CGRect(x: c.x - knob, y: c.y - knob, width: knob * 2, height: knob * 2)
            let path = NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        if let snapshot = loupeSnapshot, let focus = loupeFocusPoint {
            drawLoupe(snapshot: snapshot, focus: focus, selView: selView, pageView: pageView)
        }
    }

    /// A circular magnifier of the page under the handle being dragged: the zoomed content, the crop
    /// edges (with the trimmed side dimmed, mirroring the main marquee), and a crosshair on the exact
    /// point — so the user can seat a crop right on the content instead of guessing at the page edge.
    private func drawLoupe(snapshot: NSImage, focus: CGPoint, selView: CGRect, pageView: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = Self.loupeRadius
        let mag = Self.loupeMagnification
        let gap: CGFloat = 26
        let margin: CGFloat = 10

        // Park the loupe off the focus so the cursor never hides it; flip and clamp to stay on-screen.
        var lc = CGPoint(x: focus.x - (r + gap), y: focus.y + (r + gap))
        if lc.x - r < margin { lc.x = focus.x + (r + gap) }
        if lc.y + r > bounds.maxY - margin { lc.y = focus.y - (r + gap) }
        lc.x = min(max(lc.x, r + margin), bounds.maxX - r - margin)
        lc.y = min(max(lc.y, r + margin), bounds.maxY - r - margin)
        let circle = CGRect(x: lc.x - r, y: lc.y - r, width: 2 * r, height: 2 * r)

        ctx.saveGState()
        NSBezierPath(ovalIn: circle).addClip()
        NSColor.white.setFill()
        NSBezierPath(rect: circle).fill()

        // Magnified page: map the focus point onto the loupe centre at `mag`. The render covers exactly
        // the page's on-screen rect, so drawing it there puts page content under the same view
        // coordinates the handles use — the focus point then lands on the content it points at.
        ctx.saveGState()
        ctx.translateBy(x: lc.x, y: lc.y)
        ctx.scaleBy(x: mag, y: mag)
        ctx.translateBy(x: -focus.x, y: -focus.y)
        snapshot.draw(in: pageView, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()

        // The selection mapped into the loupe: dim the trimmed side, stroke the crop edges, magnified.
        let tsel = CGRect(x: lc.x + mag * (selView.minX - focus.x),
                          y: lc.y + mag * (selView.minY - focus.y),
                          width: selView.width * mag,
                          height: selView.height * mag)
        let dim = NSBezierPath(rect: circle)
        dim.append(NSBezierPath(rect: tsel))
        dim.windingRule = .evenOdd
        NSColor(calibratedWhite: 0, alpha: 0.4).setFill()
        dim.fill()
        accent.setStroke()
        let edges = NSBezierPath(rect: tsel)
        edges.lineWidth = 1.5
        edges.stroke()
        ctx.restoreGState()  // drop the circular clip

        // Crosshair on the exact focus, then a white halo + accent ring so the loupe reads over anything.
        accent.withAlphaComponent(0.9).setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: lc.x - 8, y: lc.y)); cross.line(to: CGPoint(x: lc.x + 8, y: lc.y))
        cross.move(to: CGPoint(x: lc.x, y: lc.y - 8)); cross.line(to: CGPoint(x: lc.x, y: lc.y + 8))
        cross.lineWidth = 1
        cross.stroke()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let halo = NSBezierPath(ovalIn: circle.insetBy(dx: -1, dy: -1)); halo.lineWidth = 2; halo.stroke()
        accent.setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75)); ring.lineWidth = 2; ring.stroke()
    }
}
