import AppKit
import PDFKit
import SwiftUI

/// Size (points, view space) of the corner resize handle drawn on the selected item.
private let handleSide: CGFloat = 20

private func handleRect(for viewRect: CGRect) -> CGRect {
    // Visual bottom-right corner. The overlay is not flipped (AppKit y-up), so that corner is (maxX, minY).
    CGRect(
        x: viewRect.maxX - handleSide / 2,
        y: viewRect.minY - handleSide / 2,
        width: handleSide,
        height: handleSide
    )
}

/// An interactive placement surface: the PDF renders underneath, and typed-text / signature items are
/// drawn, selected, dragged, and resized on top — the direct analogue of `RedactionPDFEditor`, but the
/// marks here carry content and can be moved after they land. A pan only begins when it starts on an
/// item (or the selected item's resize handle), so normal scrolling and text selection still work.
struct FillSignPDFEditor: NSViewRepresentable {
    let document: PDFDocument
    @Binding var items: [FillSignItem]
    @Binding var selectedID: UUID?
    @Binding var currentPageIndex: Int
    let accent: Color

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let pdfView = PDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = true
        pdfView.document = document

        let overlay = FillSignOverlayView()
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

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        click.delegate = context.coordinator
        pdfView.addGestureRecognizer(click)

        context.coordinator.pdfView = pdfView
        context.coordinator.overlay = overlay
        context.coordinator.observePageChanges(on: pdfView)

        overlay.items = items
        overlay.selectedID = selectedID
        overlay.scaleFactor = pdfView.scaleFactor
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.pdfView?.document !== document {
            context.coordinator.pdfView?.document = document
        }
        context.coordinator.overlay?.items = items
        context.coordinator.overlay?.selectedID = selectedID
        context.coordinator.overlay?.accent = NSColor(accent)
        context.coordinator.overlay?.scaleFactor = context.coordinator.pdfView?.scaleFactor ?? 1
        context.coordinator.overlay?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var parent: FillSignPDFEditor
        weak var pdfView: PDFView?
        fileprivate weak var overlay: FillSignOverlayView?

        private enum DragMode { case move, resize }
        private var dragMode: DragMode?
        private var dragItemID: UUID?
        private var lastPagePoint: CGPoint?
        private var resizeAnchor: CGPoint?

        init(_ parent: FillSignPDFEditor) { self.parent = parent }

        func observePageChanges(on pdfView: PDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: pdfView
            )
        }

        @objc private func pageChanged(_ note: Notification) {
            guard let pdfView, let page = pdfView.currentPage, let doc = pdfView.document else { return }
            guard let idx = (0..<doc.pageCount).first(where: { doc.page(at: $0) === page }) else { return }
            if parent.currentPageIndex != idx { parent.currentPageIndex = idx }
        }

        // MARK: Hit testing (view space)

        private func viewRect(for item: FillSignItem) -> CGRect? {
            guard let pdfView, let page = pdfView.document?.page(at: item.pageIndex) else { return nil }
            return pdfView.convert(item.rect, from: page)
        }

        private func hitTest(at loc: CGPoint) -> (id: UUID, mode: DragMode)? {
            // The selected item's resize handle wins, so you can grab a handle that sits over another box.
            if let sel = parent.selectedID,
               let item = parent.items.first(where: { $0.id == sel }),
               let vr = viewRect(for: item),
               handleRect(for: vr).contains(loc) {
                return (sel, .resize)
            }
            // Otherwise the topmost (last-added) item under the point.
            for item in parent.items.reversed() {
                if let vr = viewRect(for: item), vr.contains(loc) {
                    return (item.id, .move)
                }
            }
            return nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            // Clicks always resolve (select / deselect). Pans only hijack the scroll when they start on an item.
            if gestureRecognizer is NSClickGestureRecognizer { return true }
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
        }

        @objc func handlePan(_ g: NSPanGestureRecognizer) {
            guard let pdfView else { return }
            let loc = g.location(in: pdfView)

            switch g.state {
            case .began:
                guard let hit = hitTest(at: loc),
                      let item = parent.items.first(where: { $0.id == hit.id }),
                      let page = pdfView.document?.page(at: item.pageIndex)
                else { return }
                parent.selectedID = hit.id
                dragItemID = hit.id
                dragMode = hit.mode
                lastPagePoint = pdfView.convert(loc, to: page)
                if hit.mode == .resize {
                    // Anchor the opposite (visual top-left) corner = page-space (minX, maxY).
                    resizeAnchor = CGPoint(x: item.rect.minX, y: item.rect.maxY)
                }
                overlay?.selectedID = hit.id
                overlay?.needsDisplay = true

            case .changed:
                guard let id = dragItemID, let mode = dragMode,
                      let index = parent.items.firstIndex(where: { $0.id == id }),
                      let page = pdfView.document?.page(at: parent.items[index].pageIndex)
                else { return }
                let pagePoint = pdfView.convert(loc, to: page)
                let box = page.bounds(for: .cropBox)

                switch mode {
                case .move:
                    guard let last = lastPagePoint else { return }
                    let moved = parent.items[index].rect.offsetBy(dx: pagePoint.x - last.x, dy: pagePoint.y - last.y)
                    parent.items[index].rect = FillSignGeometry.clamped(moved, in: box)
                    lastPagePoint = pagePoint
                case .resize:
                    guard let anchor = resizeAnchor else { return }
                    let resized = FillSignGeometry.resizedRect(anchor: anchor, corner: pagePoint)
                    parent.items[index].rect = FillSignGeometry.clamped(resized, in: box)
                }
                overlay?.items = parent.items
                overlay?.needsDisplay = true

            case .ended, .cancelled:
                dragItemID = nil
                dragMode = nil
                lastPagePoint = nil
                resizeAnchor = nil

            default:
                break
            }
        }
    }
}

/// Draws placed items on top of the PDF: a WYSIWYG preview of each item's ink plus a dashed selection
/// frame and a corner resize handle for the selected one. Transparent to hit-testing so the PDFView and
/// the gesture recognizers receive every event.
fileprivate final class FillSignOverlayView: PDFViewSyncedOverlay {
    var items: [FillSignItem] = []
    var selectedID: UUID?
    var accent: NSColor = .systemPink
    /// PDFView zoom, so page-point sizes (font size, pen width) preview at the right on-screen scale.
    var scaleFactor: CGFloat = 1

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let doc = pdfView.document else { return }

        for item in items {
            guard let page = doc.page(at: item.pageIndex) else { continue }
            let vr = pdfView.convert(item.rect, from: page)
            let selected = item.id == selectedID

            switch item.content {
            case .text(let text):
                drawText(text, in: vr)
            case .signature(let signature):
                drawSignature(signature, item: item, in: vr, page: page)
            }

            let frame = NSBezierPath(rect: vr)
            frame.lineWidth = selected ? 1.5 : 1
            frame.setLineDash([5, 4], count: 2, phase: 0)
            (selected ? accent : accent.withAlphaComponent(0.45)).setStroke()
            frame.stroke()

            if selected {
                let h = handleRect(for: vr)
                accent.setFill()
                NSBezierPath(ovalIn: h).fill()
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: h)
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }

    private func drawText(_ text: FillSignText, in rect: CGRect) {
        guard text.hasInk else { return }
        let color = NSColor(srgbRed: text.red, green: text.green, blue: text.blue, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PDFToolkit.scriptOrSystemFont(size: max(4, text.fontSize * scaleFactor), script: text.isScript),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        NSAttributedString(string: text.string, attributes: attributes).draw(in: rect)
    }

    private func drawSignature(_ signature: FillSignSignature, item: FillSignItem, in rect: CGRect, page: PDFPage) {
        guard let pdfView else { return }
        let color = NSColor(srgbRed: signature.red, green: signature.green, blue: signature.blue, alpha: 1)
        color.setStroke()
        color.setFill()
        let lineWidth = max(0.6, signature.penWidthFraction * min(rect.width, rect.height))

        for stroke in signature.strokes where !stroke.isEmpty {
            let viewPoints = stroke.map { normalized -> CGPoint in
                let pagePoint = FillSignGeometry.pagePoint(normalized: normalized, in: item.rect)
                return pdfView.convert(pagePoint, from: page)
            }
            if viewPoints.count == 1 {
                let p = viewPoints[0]
                let r = lineWidth / 2
                NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: lineWidth, height: lineWidth)).fill()
                continue
            }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: viewPoints[0])
            for p in viewPoints.dropFirst() { path.line(to: p) }
            path.stroke()
        }
    }
}

/// A small freehand drawing pad. Strokes are captured in the view's own (flipped, top-left) space and
/// reported back **normalized** to 0…1 with y-down, alongside the pad's aspect ratio so the placed
/// signature keeps its proportions. Nothing here touches the network or disk.
struct SignatureCanvas: NSViewRepresentable {
    @Binding var strokes: [[CGPoint]]
    /// width / height of the pad, reported so the caller can size the placed signature without distortion.
    @Binding var aspect: CGFloat
    var inkColor: Color

    func makeNSView(context: Context) -> SignatureCanvasView {
        let view = SignatureCanvasView()
        let strokesBinding = $strokes
        let aspectBinding = $aspect
        view.onChange = { newStrokes, newAspect in
            strokesBinding.wrappedValue = newStrokes
            aspectBinding.wrappedValue = newAspect
        }
        view.inkColor = NSColor(inkColor)
        return view
    }

    func updateNSView(_ view: SignatureCanvasView, context: Context) {
        view.inkColor = NSColor(inkColor)
        // The caller cleared the pad (e.g. after placing a signature): drop the on-screen ink to match.
        if strokes.isEmpty && !view.isEmpty {
            view.clearStrokes()
        }
    }
}

final class SignatureCanvasView: NSView {
    var inkColor: NSColor = .black { didSet { needsDisplay = true } }
    var onChange: (([[CGPoint]], CGFloat) -> Void)?

    private var strokes: [[CGPoint]] = []

    var isEmpty: Bool { strokes.allSatisfy(\.isEmpty) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        strokes.append([p])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if strokes.isEmpty { strokes.append([]) }
        strokes[strokes.count - 1].append(p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        reportChange()
    }

    func clearStrokes() {
        strokes = []
        needsDisplay = true
    }

    private func reportChange() {
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let normalized = strokes.map { stroke in
            stroke.map { CGPoint(x: min(max($0.x / w, 0), 1), y: min(max($0.y / h, 0), 1)) }
        }
        onChange?(normalized, w / h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        // A light baseline so a signature has something to sit on, like a paper form line.
        let baselineY = bounds.height * 0.72
        NSColor(white: 0.85, alpha: 1).setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: CGPoint(x: 12, y: baselineY))
        baseline.line(to: CGPoint(x: bounds.width - 12, y: baselineY))
        baseline.lineWidth = 1
        baseline.stroke()

        inkColor.setStroke()
        inkColor.setFill()
        for stroke in strokes where !stroke.isEmpty {
            if stroke.count == 1 {
                let p = stroke[0]
                NSBezierPath(ovalIn: CGRect(x: p.x - 1.25, y: p.y - 1.25, width: 2.5, height: 2.5)).fill()
                continue
            }
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke[0])
            for p in stroke.dropFirst() { path.line(to: p) }
            path.stroke()
        }
    }
}
