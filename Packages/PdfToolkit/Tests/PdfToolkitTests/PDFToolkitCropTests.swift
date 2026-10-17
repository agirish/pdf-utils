import CoreGraphics
import Foundation
import PDFKit
import PDFToolkitCore
import Testing
@testable import PdfToolkit

/// Geometry of the Crop operation: displayed-edge insets land on the correct stored edges under
/// every intrinsic rotation, existing (non-zero-origin) crop boxes compose, auto-detect wraps the
/// rendered content, and degenerate crops are refused.
@Suite struct PDFToolkitCropTests {

    private func cropBox(at url: URL, page index: Int = 0) throws -> CGRect {
        let doc = try #require(PDFDocument(url: url))
        return try #require(doc.page(at: index)).bounds(for: .cropBox)
    }

    // MARK: insetRect geometry (pure)

    // MARK: Interactive marquee preview (form/annotation strip)

    @MainActor
    @Test func disableLiveTextAnalysisTurnsOffDocumentAnalysis() throws {
        let pdfView = PDFView()
        // The private getter mirrors the setter the helper drives — if a future macOS drops either,
        // this fails loudly rather than letting the Vision Live-Text hang silently return.
        let getter = NSSelectorFromString("isDocumentAnalysisEnabled")
        try #require(pdfView.responds(to: getter))
        pdfView.disableLiveTextAnalysis()
        typealias GetBool = @convention(c) (NSObject, Selector) -> Bool
        let enabled = unsafeBitCast(pdfView.method(for: getter), to: GetBool.self)(pdfView, getter)
        #expect(enabled == false)
    }

    @Test func previewLoadCapsAnnotationCountingAtTheHeavyThreshold() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("heavy.pdf")
        try PDFFixtures.writePDF(markers: ["x"], to: url)
        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: 0))
        for i in 0..<400 {
            let a = PDFAnnotation(bounds: CGRect(x: CGFloat(i), y: 0, width: 2, height: 2), forType: .square, withProperties: nil)
            page.addAnnotation(a)
        }

        let load = InteractivePreviewLoad(document: doc)
        // Counting stops once the threshold is crossed rather than tallying all 400.
        #expect(load.isHeavy)
        #expect(load.annotationCountCapped)
        #expect(load.annotationCount >= 250)
    }

    @Test func previewLoadCountsAnnotationsAndFlagsHeavy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("one-annotation.pdf")
        try PDFFixtures.writePDF(
            markers: ["content"],
            greenSquareOnFirstPage: CGRect(x: 50, y: 60, width: 100, height: 100),
            to: url
        )
        let doc = try #require(PDFDocument(url: url))

        let load = InteractivePreviewLoad(document: doc)
        #expect(load.pageCount == 1)
        #expect(load.annotationCount == 1)
        #expect(load.isHeavy == false)
    }

    // MARK: crop()

    // MARK: Drag-to-crop pipeline (selection → insets → output)

    // MARK: autoCrop()

    // MARK: Outline (bookmark) preservation
}
