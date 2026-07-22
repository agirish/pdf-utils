import AppKit
import PDFKit

/// Base class for transparent overlays pinned above a `PDFView` that draw geometry mapped from
/// page space at draw time (`pdfView.convert(_:from:)`). That mapping changes on every scroll,
/// zoom, and relayout of the underlying view — none of which SwiftUI's update cycle sees — so the
/// overlay must invalidate itself on those events, or its drawing visibly detaches from the page
/// content beneath it while the stored page-space geometry stays correct.
class PDFViewSyncedOverlay: NSView {
    weak var pdfView: PDFView? {
        didSet { registerForMappingChanges() }
    }

    /// Set by an editor that wants keyboard editing (arrow-nudge, ⌘Z/⌘⇧Z, delete) while this overlay
    /// is first responder; it returns true when it consumed the event. Left nil by overlays that don't
    /// opt in, which then stay non-focusable plain layers exactly as before. The overlay is made first
    /// responder by the editor only in the contexts where these keys should win (a mark selected, the
    /// crop marquee active) — otherwise focus stays with the `PDFView` so arrows scroll normally.
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { onKeyDown != nil }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Owns the notification tokens so removal can happen in a nonisolated deinit — an NSView's
    /// MainActor isolation forbids touching stored state from its own deinit.
    private final class ObserverBag {
        var tokens: [NSObjectProtocol] = []
        func drain() {
            tokens.forEach(NotificationCenter.default.removeObserver(_:))
            tokens = []
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver(_:)) }
    }

    private let bag = ObserverBag()
    private var scrollObserverRegistered = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForMappingChanges()
    }

    override func layout() {
        super.layout()
        // PDFView builds its internal scroll view lazily; if it didn't exist when we registered,
        // pick it up once layout has realized the hierarchy.
        if !scrollObserverRegistered {
            registerForMappingChanges()
        }
    }

    private func registerForMappingChanges() {
        bag.drain()
        scrollObserverRegistered = false
        guard let pdfView else { return }

        let center = NotificationCenter.default
        let redraw: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        bag.tokens.append(center.addObserver(
            forName: .PDFViewScaleChanged, object: pdfView, queue: .main, using: redraw
        ))
        bag.tokens.append(center.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main, using: redraw
        ))
        // Scrolling never posts a PDFView notification — it lives in the internal scroll view's
        // clip bounds, so observe those directly.
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            bag.tokens.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: redraw
            ))
            scrollObserverRegistered = true
        }
    }
}
