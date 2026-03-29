import AppKit
import PDFKit
import SwiftUI

/// PDF preview with **⇧-drag** rubber-band rectangles in page space. Normal scrolling and selection work without Shift.
struct RedactionPDFEditor: NSViewRepresentable {
    let document: PDFDocument
    @Binding var marks: [RedactionMark]

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, marks: $marks)
    }

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

        context.coordinator.pdfView = pdfView
        context.coordinator.overlay = overlay
        overlay.marks = marks
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.marksBinding = $marks
        if context.coordinator.pdfView?.document !== document {
            context.coordinator.pdfView?.document = document
        }
        context.coordinator.overlay?.marks = marks
        context.coordinator.overlay?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var parent: RedactionPDFEditor
        var marksBinding: Binding<[RedactionMark]>
        weak var pdfView: PDFView?
        fileprivate weak var overlay: RedactionOverlayView?

        private var dragStartPage: PDFPage?
        private var dragStartOnPage: CGPoint?

        init(parent: RedactionPDFEditor, marks: Binding<[RedactionMark]>) {
            self.parent = parent
            self.marksBinding = marks
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            NSEvent.modifierFlags.contains(.shift)
        }

        @objc func handlePan(_ g: NSPanGestureRecognizer) {
            guard let pdfView else { return }

            let loc = g.location(in: pdfView)

            switch g.state {
            case .began:
                guard let page = pdfView.page(for: loc, nearest: true) else { return }
                let start = pdfView.convert(loc, to: page)
                dragStartPage = page
                dragStartOnPage = start
                overlay?.draftPage = page
                overlay?.draftRect = CGRect(origin: start, size: .zero)
                overlay?.needsDisplay = true

            case .changed:
                guard let startPage = dragStartPage, let startPt = dragStartOnPage else { return }
                guard let endPage = pdfView.page(for: loc, nearest: true), endPage === startPage else { return }
                let endPt = pdfView.convert(loc, to: startPage)
                overlay?.draftRect = RedactionMarkGeometry.normalizedDragRect(start: startPt, end: endPt)
                overlay?.needsDisplay = true

            case .ended, .cancelled:
                defer {
                    dragStartPage = nil
                    dragStartOnPage = nil
                    overlay?.draftPage = nil
                    overlay?.draftRect = nil
                    overlay?.needsDisplay = true
                }
                guard let startPage = dragStartPage, let startPt = dragStartOnPage else { return }
                guard let endPage = pdfView.page(for: loc, nearest: true), endPage === startPage else { return }
                let endPt = pdfView.convert(loc, to: startPage)
                let rect = RedactionMarkGeometry.normalizedDragRect(start: startPt, end: endPt)
                guard RedactionMarkGeometry.isMeaningful(rect) else { return }
                let media = startPage.bounds(for: .mediaBox)
                guard let clipped = RedactionMarkGeometry.clipToMediaBox(rect, mediaBox: media) else { return }
                guard let doc = pdfView.document else { return }
                guard let idx = (0..<doc.pageCount).first(where: { doc.page(at: $0) === startPage }) else { return }
                marksBinding.wrappedValue.append(RedactionMark(pageIndex: idx, rect: clipped))

            default:
                break
            }
        }
    }
}

fileprivate final class RedactionOverlayView: NSView {
    weak var pdfView: PDFView?
    var marks: [RedactionMark] = []
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
            fillColor.setFill()
            viewRect.fill()
            strokeColor.setStroke()
            let path = NSBezierPath(rect: viewRect)
            path.lineWidth = 1.5
            path.stroke()
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
}
