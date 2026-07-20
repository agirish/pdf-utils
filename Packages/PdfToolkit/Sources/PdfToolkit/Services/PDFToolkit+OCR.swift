import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

/// How recognition runs. Plain values so the options cross the PDF serial queue.
struct OCROptions: Sendable {
    /// Accurate uses the slower neural path with language correction; Fast trades some hit rate
    /// for speed on long documents.
    var accurate = true
    /// Pages that already extract text are copied through untouched — running OCR over live vector
    /// text would stack a second, slightly-off text layer under every selection.
    var skipPagesWithText = true
}

/// What an OCR run did, for the caller's messaging.
struct OCRRunSummary: Sendable {
    var recognizedPages = 0
    var skippedPages = 0
}

extension PDFToolkit {
    /// Long-edge render sizes for recognition: ~300 dpi on US Letter for the accurate recognizer,
    /// half that for Fast — the mode users pick for speed shouldn't pay full rasterization cost.
    private static let accurateOCRPixelDimension: CGFloat = 3300
    private static let fastOCRPixelDimension: CGFloat = 1650

    /// One recognized line: the text and its normalized (0…1, lower-left origin) image rectangle.
    private typealias RecognizedLine = (string: String, normalizedRect: CGRect)

    /// Lays an invisible, selectable text layer behind every scanned page and writes a new PDF.
    ///
    /// Pages are rebuilt the way ``watermark`` rebuilds them — original content re-drawn as vector
    /// through `drawPDFPage` (nothing is rasterized), visible annotations flattened in, intrinsic
    /// rotation baked into an upright page. On pages with no extractable text, the page is rendered
    /// to a bitmap, Apple's Vision text recognition runs over it on-device, and each recognized
    /// line is drawn back in invisible text mode at its detected position, sized so selection
    /// highlights match the printed words underneath.
    static func ocr(
        inputURL: URL,
        outputURL: URL,
        options: OCROptions,
        progress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> OCRRunSummary {
        try requireDistinctOutput(outputURL, from: [inputURL])
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.ocrFailed
        }

        var summary = OCRRunSummary()
        for i in 0..<source.pageCount {
            progress?(i + 1, source.pageCount)
            if isCancelled?() == true { throw CancellationError() }
            // Throw, never skip: silently dropping an unreadable page would ship an output with
            // fewer pages than the input — data loss dressed up as success. (Locked docs, whose
            // pages all lack a pageRef, are already refused by openUnlockedDocument.)
            guard let page = source.page(at: i), let cgPage = page.pageRef else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }

            let cropBox = page.bounds(for: .cropBox)
            let rotation = ((page.rotation % 360) + 360) % 360
            let displaySize = (rotation == 90 || rotation == 270)
                ? CGSize(width: cropBox.height, height: cropBox.width)
                : cropBox.size
            let box = CGRect(origin: .zero, size: displaySize)

            let needsRecognition: Bool
            if options.skipPagesWithText {
                let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                needsRecognition = existing.isEmpty
            } else {
                needsRecognition = true
            }

            var lines: [RecognizedLine] = []
            if needsRecognition {
                let renderSize = options.accurate ? accurateOCRPixelDimension : fastOCRPixelDimension
                guard let bitmap = renderPageBitmap(page, maxPixelDimension: renderSize) else {
                    throw PDFOperationError.ocrFailed
                }
                lines = try recognizeText(in: bitmap, accurate: options.accurate)
                summary.recognizedPages += 1
            } else {
                summary.skippedPages += 1
            }

            // Same emit pattern as watermark, including the CFData media-box gotcha.
            var pageBox = box
            let pageBoxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: pageBoxData] as CFDictionary)

            ctx.saveGState()
            let transform = cgPage.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: false)
            ctx.concatenate(transform)
            ctx.drawPDFPage(cgPage)
            ctx.restoreGState()

            drawAnnotations(of: page, in: ctx)

            for line in lines {
                drawInvisibleLine(line.string, at: pageRect(for: line.normalizedRect, in: box), in: ctx)
            }

            ctx.endPDFPage()
        }
        ctx.closePDF()

        guard pdfData.length > 0 else { throw PDFOperationError.ocrFailed }
        do {
            try (pdfData as Data).write(to: outputURL, options: .atomic)
        } catch {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
        return summary
    }

    // MARK: Recognition

    /// Runs Vision over one page bitmap and returns per-line text with normalized rectangles.
    private static func recognizeText(in image: CGImage, accurate: Bool) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = accurate
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw PDFOperationError.ocrFailed
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return (candidate.string, observation.boundingBox)
        }
    }

    /// Vision's normalized lower-left-origin rectangle → displayed-page points. The recognition
    /// bitmap was rendered from the displayed page (rotation and crop applied), so normalized
    /// coordinates map straight onto the emitted page box.
    private static func pageRect(for normalized: CGRect, in box: CGRect) -> CGRect {
        CGRect(
            x: box.minX + normalized.minX * box.width,
            y: box.minY + normalized.minY * box.height,
            width: normalized.width * box.width,
            height: normalized.height * box.height
        )
    }

    /// Draws one line of text in invisible mode (PDF text-rendering mode 3), sized to the detected
    /// rectangle in BOTH dimensions: the font is fit to the rect's height (so selection highlights
    /// stay on this line instead of towering over it when Vision's box is wide relative to the
    /// glyph run — letter-spaced headings), then the glyph run is stretched horizontally via the
    /// text matrix to span the rect's width. The text is real vector text: searchable, selectable,
    /// copyable.
    private static func drawInvisibleLine(_ string: String, at rect: CGRect, in ctx: CGContext) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }

        let probeSize: CGFloat = 12
        let probeLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: probeSize)])
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let probeWidth = CGFloat(CTLineGetTypographicBounds(probeLine, &ascent, &descent, &leading))
        guard probeWidth > 0, ascent + descent > 0 else { return }

        let heightScale = rect.height / (ascent + descent)
        let fontSize = probeSize * heightScale
        let naturalWidth = probeWidth * heightScale
        let stretch = naturalWidth > 0 ? rect.width / naturalWidth : 1
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        )

        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        // Scale first: textPosition writes only the matrix's translation, so the stretch survives.
        ctx.textMatrix = CGAffineTransform(scaleX: stretch, y: 1)
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + descent * heightScale)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
