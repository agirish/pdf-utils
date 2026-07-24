import Foundation
import PDFKit

/// A cheap structural summary of a document about to be mounted in a live `PDFView` — the number
/// that predicts whether PDFKit will choke on it.
///
/// The drag-to-crop, Fill & Sign, and Redact panes all hand a `PDFDocument` to an interactive
/// `PDFView`. On an annotation-heavy file (a scanned government form with hundreds of widget
/// fields, say) PDFKit spins up a per-field `formFillingQueue` thread storm and a Vision Live-Text
/// pass, which measured at 500+ threads and ~2.6 GB and wedged the app with **no log line to
/// explain it**. Recording this summary just before the mount leaves a breadcrumb: after a force
/// quit, `~/pdf-utils.log` names the tool, file, and how heavy the document was.
struct InteractivePreviewLoad {
    /// Well past this many annotations, mounting a live `PDFView` is a real risk, so the load is
    /// logged as a warning rather than a routine breadcrumb.
    private static let heavyThreshold = 250

    let pageCount: Int
    /// Annotations counted, but only up to `heavyThreshold` — see `annotationCountCapped`.
    let annotationCount: Int
    /// True once counting hit the cap without finishing, so `annotationCount` is a floor, not exact.
    let annotationCountCapped: Bool

    /// Counting annotations touches every page's `annotations` array, which forces PDFKit to parse
    /// each page's annotation dictionary — the very work that is slow on the heavy scans this is meant
    /// to flag. Since the only consumer is the heavy/not-heavy decision, stop as soon as the threshold
    /// is crossed rather than parsing every page of a large document just to log an exact number.
    ///
    /// Must run on the PDF serial queue like all other `PDFPage` access.
    init(document: PDFDocument) {
        pageCount = document.pageCount
        var annotations = 0
        var capped = false
        for i in 0..<document.pageCount {
            annotations += document.page(at: i)?.annotations.count ?? 0
            if annotations >= Self.heavyThreshold { capped = true; break }
        }
        annotationCount = annotations
        annotationCountCapped = capped
    }

    var isHeavy: Bool { annotationCount >= Self.heavyThreshold }

    /// Records the load to the Activity Log — a warning when heavy, an info breadcrumb otherwise —
    /// naming the tool and file so a hang is traceable to exactly this document. Counting happens on
    /// the PDF serial queue; the value is `Sendable`, so this logs on the main actor after the hop.
    @MainActor
    func log(tool: String, url: URL, stripped: Bool) {
        let name = url.lastPathComponent
        let annotations = annotationCountCapped ? "\(annotationCount)+" : "\(annotationCount)"
        let detail = "\(tool): mounting preview — \(pageCount) page\(pageCount == 1 ? "" : "s"), "
            + "\(annotations) annotation\(annotationCount == 1 && !annotationCountCapped ? "" : "s")"
            + (stripped ? " (stripped for display)" : "") + " — \(name)"
        if isHeavy && !stripped {
            ActivityLog.shared.warning(detail)
        } else {
            ActivityLog.shared.info(detail)
        }
    }
}
