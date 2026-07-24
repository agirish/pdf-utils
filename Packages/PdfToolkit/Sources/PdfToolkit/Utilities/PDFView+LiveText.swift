import PDFKit

extension PDFView {
    /// Turns off PDFKit's automatic Vision "Live Text" document analysis for this view.
    ///
    /// On macOS, a `PDFView` kicks off `PDFPageAnalyzerV2` → `VNRecognizeDocumentsRequest` whenever
    /// its visible pages change, to make scanned text selectable. None of our tools use that — we
    /// only mount a `PDFView` so the user can draw a crop/redaction/signature box — and on a scanned
    /// document it is expensive: measured at ~3.3 s of extra CPU on a single 2-page image PDF, which
    /// in the full app compounded into a multi-second hang and ~2.6 GB of memory. Disabling it makes
    /// the interactive canvases open promptly on heavy scans and closes off that class of hang for good.
    ///
    /// `documentAnalysisEnabled` isn't in PDFKit's public Swift surface, so it's set through its ObjC
    /// setter, guarded by `responds(to:)` — a no-op on any OS that ever drops the selector, never a crash.
    func disableLiveTextAnalysis() {
        let selector = NSSelectorFromString("setDocumentAnalysisEnabled:")
        guard responds(to: selector) else { return }
        typealias SetBool = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: selector), to: SetBool.self)(self, selector, false)
    }
}
