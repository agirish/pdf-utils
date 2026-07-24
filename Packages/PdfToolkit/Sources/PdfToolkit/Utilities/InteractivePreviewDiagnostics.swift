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
    let pageCount: Int
    let annotationCount: Int

    /// Counting annotations touches every page's `annotations` array, so this must run on the PDF
    /// serial queue like all other `PDFPage` access.
    init(document: PDFDocument) {
        pageCount = document.pageCount
        var annotations = 0
        for i in 0..<document.pageCount {
            annotations += document.page(at: i)?.annotations.count ?? 0
        }
        annotationCount = annotations
    }

    /// A form-field storm is what actually hangs PDFKit; well past this, a live `PDFView` mount is a
    /// real risk, so the load is logged as a warning rather than a routine breadcrumb.
    var isHeavy: Bool { annotationCount >= 250 }

    /// Records the load to the Activity Log — a warning when heavy, an info breadcrumb otherwise —
    /// naming the tool and file so a hang is traceable to exactly this document. Counting happens on
    /// the PDF serial queue; the value is `Sendable`, so this logs on the main actor after the hop.
    @MainActor
    func log(tool: String, url: URL, stripped: Bool) {
        let name = url.lastPathComponent
        let detail = "\(tool): mounting preview — \(pageCount) page\(pageCount == 1 ? "" : "s"), "
            + "\(annotationCount) annotation\(annotationCount == 1 ? "" : "s")"
            + (stripped ? " (stripped for display)" : "") + " — \(name)"
        if isHeavy && !stripped {
            ActivityLog.shared.warning(detail)
        } else {
            ActivityLog.shared.info(detail)
        }
    }
}
