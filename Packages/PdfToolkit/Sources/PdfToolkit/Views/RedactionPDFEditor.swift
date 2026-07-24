import AppKit
import PDFKit
import SwiftUI

/// Size (points, view space) of the corner resize handle's grab target on the selected mark.
private let redactHandleSide: CGFloat = 20

/// The handle's square at the VISUAL bottom-right corner of a view-space rect. The overlay is not
/// flipped (AppKit y-up), so that corner is (maxX, minY).
private func redactHandleRect(for viewRect: CGRect) -> CGRect {
    CGRect(
        x: viewRect.maxX - redactHandleSide / 2,
        y: viewRect.minY - redactHandleSide / 2,
        width: redactHandleSide,
        height: redactHandleSide
    )
}

/// PDF preview with **⇧-drag** rubber-band rectangles in page space, and — new — direct editing of the
/// marks already down: click one to select it, drag it to move, or drag its corner handle to resize.
/// Normal scrolling and text selection still work: a plain drag only hijacks the scroll when it starts
/// on a mark (or the selected mark's handle); everything else falls through to the `PDFView`.
struct RedactionPDFEditor: NSViewRepresentable {
    let document: PDFDocument
    @Binding var marks: [RedactionMark]
    /// The mark currently selected for keyboard/handle editing, shared with the tool so its Regions
    /// list and this canvas stay in agreement. nil = nothing selected.
    @Binding var selectedID: UUID?
    /// True from a drag's start to its end, so the tool records the whole drag as one undo step
    /// instead of one per mouse-move (see ``UndoHistory``).
    @Binding var isInteracting: Bool
    /// ⌘Z / ⌘⇧Z, routed to the tool's shared history when this canvas holds focus (a mark selected).
    var onUndo: () -> Void
    var onRedo: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, marks: $marks)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let pdfView = PDFView()
        pdfView.disableLiveTextAnalysis()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = true
        pdfView.document = document

        let overlay = RedactionOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        overlay.pdfView = pdfView

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

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        click.delegate = context.coordinator
        pdfView.addGestureRecognizer(click)

        let coordinator = context.coordinator
        overlay.onKeyDown = { [weak coordinator] event in coordinator?.handleKeyDown(event) ?? false }

        coordinator.pdfView = pdfView
        coordinator.overlay = overlay
        overlay.marks = marks
        overlay.selectedID = selectedID
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.marksBinding = $marks
        if context.coordinator.pdfView?.document !== document {
            context.coordinator.pdfView?.document = document
        }
        context.coordinator.overlay?.marks = marks
        context.coordinator.overlay?.selectedID = selectedID
        context.coordinator.overlay?.needsDisplay = true
        // A mark selected from the Regions list (not the canvas) should still enable keyboard editing;
        // acquire focus safely (never from a text field). See acquireKeyFocusIfSelected.
        context.coordinator.acquireKeyFocusIfSelected()
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var parent: RedactionPDFEditor
        var marksBinding: Binding<[RedactionMark]>
        weak var pdfView: PDFView?
        fileprivate weak var overlay: RedactionOverlayView?

        /// What a plain (non-shift) drag is doing to an existing mark.
        private enum EditMode { case move, resize }

        // ⇧-drag create state.
        private var dragStartPage: PDFPage?
        private var dragStartOnPage: CGPoint?
        // Move/resize state.
        private var editMode: EditMode?
        private var editMarkID: UUID?
        private var editPage: PDFPage?
        private var lastPagePoint: CGPoint?
        private var resizeAnchor: CGPoint?

        init(parent: RedactionPDFEditor, marks: Binding<[RedactionMark]>) {
            self.parent = parent
            self.marksBinding = marks
        }

        // MARK: Hit testing (view space)

        private func viewRect(for mark: RedactionMark) -> CGRect? {
            guard let pdfView, let page = pdfView.document?.page(at: mark.pageIndex) else { return nil }
            return pdfView.convert(mark.rect, from: page)
        }

        /// The mark (and what a drag there would do) under a view-space point. The selected mark's
        /// resize handle wins, so you can grab a handle sitting over another mark; otherwise the
        /// topmost (last-drawn) mark containing the point is moved.
        private func hitTest(at loc: CGPoint) -> (id: UUID, mode: EditMode)? {
            if let sel = parent.selectedID,
               let mark = parent.marks.first(where: { $0.id == sel }),
               let vr = viewRect(for: mark),
               redactHandleRect(for: vr).contains(loc) {
                return (sel, .resize)
            }
            for mark in parent.marks.reversed() {
                if let vr = viewRect(for: mark), vr.contains(loc) {
                    return (mark.id, .move)
                }
            }
            return nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            // A click always resolves (select / deselect). A ⇧-drag always draws a new mark. A plain
            // drag only takes over the scroll when it starts on a mark or the selected mark's handle.
            if gestureRecognizer is NSClickGestureRecognizer { return true }
            if NSEvent.modifierFlags.contains(.shift) { return true }
            guard let pdfView else { return false }
            return hitTest(at: gestureRecognizer.location(in: pdfView)) != nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handleClick(_ g: NSClickGestureRecognizer) {
            guard let pdfView else { return }
            let hit = hitTest(at: g.location(in: pdfView))
            parent.selectedID = hit?.id
            overlay?.selectedID = hit?.id
            overlay?.needsDisplay = true
            focusOverlayForKeys()
        }

        @objc func handlePan(_ g: NSPanGestureRecognizer) {
            guard let pdfView else { return }
            let loc = g.location(in: pdfView)

            switch g.state {
            case .began:
                // One undo step per drag: mark the interaction so the tool defers its history push
                // until the drag settles.
                parent.isInteracting = true
                if NSEvent.modifierFlags.contains(.shift) {
                    beginCreate(at: loc)
                } else {
                    beginEdit(at: loc)
                }

            case .changed:
                if dragStartPage != nil {
                    updateCreate(to: loc)
                } else {
                    updateEdit(to: loc)
                }

            case .ended, .cancelled:
                if dragStartPage != nil {
                    finishCreate(at: loc)
                }
                editMode = nil
                editMarkID = nil
                editPage = nil
                lastPagePoint = nil
                resizeAnchor = nil
                focusOverlayForKeys()
                // Flip LAST — the tool commits the settled drag when this goes false.
                parent.isInteracting = false

            default:
                break
            }
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
            case .delete: return deleteSelected()
            case .nudge(let dx, let dy): return nudgeSelected(dx: dx, dy: dy)
            }
        }

        /// Moves the selected mark by a fixed page-point step in the arrow's screen direction —
        /// zoom-independent and rotation-correct (the screen vector is mapped through the view). A
        /// single mutation, so the tool's `onChange` records it as one undo step.
        private func nudgeSelected(dx: CGFloat, dy: CGFloat) -> Bool {
            guard let pdfView,
                  let id = parent.selectedID,
                  let index = marksBinding.wrappedValue.firstIndex(where: { $0.id == id }),
                  let page = pdfView.document?.page(at: marksBinding.wrappedValue[index].pageIndex) else { return false }
            let step = max(abs(dx), abs(dy))
            let flip: CGFloat = pdfView.isFlipped ? -1 : 1
            let base = pdfView.convert(CGPoint.zero, to: page)
            let tip = pdfView.convert(CGPoint(x: dx, y: dy * flip), to: page)
            let delta = EditorNudge.scaled(CGSize(width: tip.x - base.x, height: tip.y - base.y), to: step)
            let box = page.bounds(for: .cropBox)
            marksBinding.wrappedValue[index].rect = EditorNudge.moved(marksBinding.wrappedValue[index].rect, by: delta, within: box)
            overlay?.marks = marksBinding.wrappedValue
            overlay?.needsDisplay = true
            return true
        }

        private func deleteSelected() -> Bool {
            guard let id = parent.selectedID,
                  marksBinding.wrappedValue.contains(where: { $0.id == id }) else { return false }
            marksBinding.wrappedValue.removeAll { $0.id == id }
            parent.selectedID = nil
            overlay?.selectedID = nil
            overlay?.marks = marksBinding.wrappedValue
            overlay?.needsDisplay = true
            focusOverlayForKeys()
            return true
        }

        // MARK: First responder

        /// Give the overlay keyboard focus so nudge / ⌘Z / delete are live. Called from any canvas
        /// gesture — unconditionally, even a click that deselects: keeping focus here is what lets ⌘Z
        /// keep undoing past a deselect, and the overlay's `keyDown` forwards anything it doesn't handle
        /// (arrows with nothing selected, Page Up/Down) to the PDFView, so scrolling still works.
        /// Clicking a text field resigns this automatically, so it can't trap focus.
        private func focusOverlayForKeys() {
            guard let overlay, let window = overlay.window,
                  window.firstResponder !== overlay else { return }
            window.makeFirstResponder(overlay)
        }

        /// Safe to call from `updateNSView`: when a mark is selected from OUTSIDE the canvas (a
        /// Regions-list tap), give the overlay focus so arrows/⌘Z work there too — but only by taking
        /// focus from the PDFView or an unfocused window, NEVER from a text field.
        func acquireKeyFocusIfSelected() {
            guard parent.selectedID != nil,
                  let overlay, let window = overlay.window,
                  window.firstResponder !== overlay else { return }
            let fr = window.firstResponder
            if fr === pdfView || fr === window || fr == nil {
                window.makeFirstResponder(overlay)
            }
        }

        // MARK: ⇧-drag create

        private func beginCreate(at loc: CGPoint) {
            guard let pdfView, let page = pdfView.page(for: loc, nearest: true) else { return }
            let start = pdfView.convert(loc, to: page)
            dragStartPage = page
            dragStartOnPage = start
            overlay?.draftPage = page
            overlay?.draftRect = CGRect(origin: start, size: .zero)
            overlay?.needsDisplay = true
        }

        private func updateCreate(to loc: CGPoint) {
            guard let pdfView, let startPage = dragStartPage, let startPt = dragStartOnPage else { return }
            guard let endPage = pdfView.page(for: loc, nearest: true), endPage === startPage else { return }
            let endPt = pdfView.convert(loc, to: startPage)
            overlay?.draftRect = RedactionMarkGeometry.normalizedDragRect(start: startPt, end: endPt)
            overlay?.needsDisplay = true
        }

        private func finishCreate(at loc: CGPoint) {
            defer {
                dragStartPage = nil
                dragStartOnPage = nil
                overlay?.draftPage = nil
                overlay?.draftRect = nil
                overlay?.needsDisplay = true
            }
            guard let pdfView, let startPage = dragStartPage, let startPt = dragStartOnPage else { return }
            guard let endPage = pdfView.page(for: loc, nearest: true), endPage === startPage else { return }
            let endPt = pdfView.convert(loc, to: startPage)
            let rect = RedactionMarkGeometry.normalizedDragRect(start: startPt, end: endPt)
            guard RedactionMarkGeometry.isMeaningful(rect) else { return }
            // Clip to the CROP box — the region the user can actually see and the same box the export
            // clips against.
            let visible = startPage.bounds(for: .cropBox)
            guard let clipped = RedactionMarkGeometry.clip(rect, to: visible) else { return }
            guard let doc = pdfView.document else { return }
            guard let idx = (0..<doc.pageCount).first(where: { doc.page(at: $0) === startPage }) else { return }
            let mark = RedactionMark(pageIndex: idx, rect: clipped)
            marksBinding.wrappedValue.append(mark)
            // A freshly drawn mark comes up selected, so it can be nudged, resized, or deleted at once.
            parent.selectedID = mark.id
            overlay?.selectedID = mark.id
        }

        // MARK: Move / resize an existing mark

        private func beginEdit(at loc: CGPoint) {
            guard let pdfView,
                  let hit = hitTest(at: loc),
                  let mark = parent.marks.first(where: { $0.id == hit.id }),
                  let page = pdfView.document?.page(at: mark.pageIndex) else { return }
            parent.selectedID = hit.id
            overlay?.selectedID = hit.id
            editMode = hit.mode
            editMarkID = hit.id
            editPage = page
            lastPagePoint = pdfView.convert(loc, to: page)
            if hit.mode == .resize {
                // Anchor the resize at the mark's VISUAL top-left, converted through the view so the
                // page's /Rotate is applied — the same reasoning Fill & Sign documents for its handle.
                let vr = pdfView.convert(mark.rect, from: page)
                resizeAnchor = pdfView.convert(CGPoint(x: vr.minX, y: vr.maxY), to: page)
            }
            overlay?.needsDisplay = true
        }

        private func updateEdit(to loc: CGPoint) {
            guard let pdfView,
                  let id = editMarkID, let mode = editMode, let page = editPage,
                  let index = marksBinding.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
            let pagePoint = pdfView.convert(loc, to: page)
            let box = page.bounds(for: .cropBox)

            switch mode {
            case .move:
                guard let last = lastPagePoint else { return }
                let moved = marksBinding.wrappedValue[index].rect.offsetBy(dx: pagePoint.x - last.x, dy: pagePoint.y - last.y)
                marksBinding.wrappedValue[index].rect = RedactionMarkGeometry.clamped(moved, in: box)
                lastPagePoint = pagePoint
            case .resize:
                guard let anchor = resizeAnchor else { return }
                let resized = RedactionMarkGeometry.resizedRect(anchor: anchor, corner: pagePoint)
                marksBinding.wrappedValue[index].rect = RedactionMarkGeometry.clamped(resized, in: box)
            }
            overlay?.marks = marksBinding.wrappedValue
            overlay?.needsDisplay = true
        }
    }
}

fileprivate final class RedactionOverlayView: PDFViewSyncedOverlay {
    var marks: [RedactionMark] = []
    var selectedID: UUID?
    weak var draftPage: PDFPage?
    var draftRect: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView else { return }

        let fillColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.11, alpha: 0.5)
        let strokeColor = NSColor(calibratedRed: 0.78, green: 0.16, blue: 0.22, alpha: 0.95)

        for mark in marks {
            guard let page = pdfView.document?.page(at: mark.pageIndex) else { continue }
            let viewRect = pdfView.convert(mark.rect, from: page)
            let isSelected = mark.id == selectedID
            fillColor.setFill()
            viewRect.fill()
            strokeColor.setStroke()
            let path = NSBezierPath(rect: viewRect)
            // The selected mark wears a heavier border so it reads apart from the rest at a glance.
            path.lineWidth = isSelected ? 2.5 : 1.5
            // Auto-detected matches wear a dashed outline so they read as "suggested — review me,"
            // while hand-drawn marks stay solid. Both fill and redact identically.
            if mark.origin == .autoMatch {
                path.setLineDash([4, 3], count: 2, phase: 0)
            }
            path.stroke()

            if isSelected {
                drawSelectionHandle(in: viewRect, stroke: strokeColor)
            }
        }

        if let page = draftPage, let dr = draftRect, dr.width > 0.5, dr.height > 0.5 {
            let viewRect = pdfView.convert(dr, from: page)
            strokeColor.withAlphaComponent(0.75).setStroke()
            let path = NSBezierPath(rect: viewRect)
            path.lineWidth = 1.5
            path.stroke()
            fillColor.withAlphaComponent(0.24).setFill()
            viewRect.fill(using: .sourceOver)
        }
    }

    /// The bottom-right corner knob shown on the selected mark: a filled disc with a white ring so it
    /// stays visible over both the mark's dark fill and the bright page.
    private func drawSelectionHandle(in viewRect: CGRect, stroke: NSColor) {
        let knob = redactHandleRect(for: viewRect).insetBy(dx: 4, dy: 4)
        stroke.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: knob)
        ring.lineWidth = 1.5
        ring.stroke()
    }
}
