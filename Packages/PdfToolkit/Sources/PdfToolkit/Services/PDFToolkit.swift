import AppKit
import CoreGraphics
import Foundation
import PDFKit

struct PDFRedactionExportOptions: Sendable {
    /// When true, removes every annotation (highlights, comments, ink, etc.) from pages that are copied without rasterization.
    /// Redacted pages are always rebuilt as images, so their prior content under the marks is gone.
    var stripAnnotationsFromUnredactedPages: Bool
    /// Target length in **pixels** of the page’s longest edge when rasterizing a redacted page (higher = sharper, larger files and slower export).
    /// Unlike compression, this **supersamples** past 1× PDF points so text stays crisp (e.g. 4000 ≈ ~5× on US Letter height).
    var maxPixelDimension: CGFloat

    static let `default` = PDFRedactionExportOptions(
        stripAnnotationsFromUnredactedPages: false,
        maxPixelDimension: 4000
    )
}

/// How the watermark text is stamped onto every page. RGB components (not `NSColor`) keep this
/// `Sendable` for the background PDF queue.
struct WatermarkOptions: Sendable {
    var text: String
    var fontSize: CGFloat
    /// 0…1 fill opacity of the stamped text.
    var opacity: CGFloat
    var rotationDegrees: CGFloat
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// When true, the text is repeated across the whole page; otherwise it is drawn once, centered.
    var tiled: Bool
}

enum PDFToolkit {
    /// Quick page count for UI summaries; the URL must already be readable (e.g. under active security scope).
    static func pageCount(at url: URL) -> Int? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return doc.pageCount
    }

    /// Merges PDFs in the order given. Pages are moved out of each temporary document into the result.
    static func merge(inputURLs: [URL], outputURL: URL) throws {
        guard !inputURLs.isEmpty else { throw PDFOperationError.noInputFiles }

        let merged = PDFDocument()
        for url in inputURLs {
            guard let doc = PDFDocument(url: url) else {
                throw PDFOperationError.couldNotOpen(url)
            }
            while doc.pageCount > 0 {
                guard let page = doc.page(at: 0) else { break }
                merged.insert(page, at: merged.pageCount)
            }
        }

        guard merged.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Splits a PDF into several files, one per segment. Each `segment` is a list of zero-based
    /// page indices copied (in order) into its own document. Files are written into `directory`
    /// as `baseName-01.pdf`, `baseName-02.pdf`, … (index width grows with the part count) and the
    /// produced URLs are returned in order. Existing files with the same names are overwritten.
    static func split(inputURL: URL, into directory: URL, baseName: String, segments: [[Int]]) throws -> [URL] {
        guard !segments.isEmpty else { throw PDFOperationError.noPagesSelected }
        guard let source = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let width = max(2, String(segments.count).count)
        var outputs: [URL] = []
        for (partIndex, segment) in segments.enumerated() {
            guard !segment.isEmpty else { continue }
            let out = PDFDocument()
            var insertAt = 0
            for i in segment {
                guard let src = source.page(at: i) else {
                    throw PDFOperationError.pageOutOfBounds(i + 1)
                }
                guard let copy = src.copy() as? PDFPage else {
                    throw PDFOperationError.couldNotOpen(inputURL)
                }
                out.insert(copy, at: insertAt)
                insertAt += 1
            }
            let suffix = String(format: "%0\(width)d", partIndex + 1)
            let url = directory.appendingPathComponent("\(baseName)-\(suffix).pdf")
            guard out.write(to: url) else {
                throw PDFOperationError.couldNotWrite(url)
            }
            outputs.append(url)
        }

        guard !outputs.isEmpty else { throw PDFOperationError.noPagesSelected }
        return outputs
    }

    /// Copies listed pages (zero-based) into a new PDF.
    static func extract(inputURL: URL, outputURL: URL, pageIndices: [Int]) throws {
        guard !pageIndices.isEmpty else { throw PDFOperationError.noPagesSelected }
        guard let source = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }

        let out = PDFDocument()
        var insertAt = 0
        for i in pageIndices {
            guard let src = source.page(at: i) else {
                throw PDFOperationError.pageOutOfBounds(i + 1)
            }
            guard let copy = src.copy() as? PDFPage else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
            out.insert(copy, at: insertAt)
            insertAt += 1
        }

        guard out.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Writes a new PDF whose pages follow `order` (a permutation of the source's zero-based
    /// indices). This is `extract` with the full page set reshuffled — a page appears exactly
    /// where the new order places it.
    static func reorder(inputURL: URL, outputURL: URL, order: [Int]) throws {
        try extract(inputURL: inputURL, outputURL: outputURL, pageIndices: order)
    }

    /// Removes pages (zero-based). Duplicates are ignored. Removed from highest index first.
    static func deletePages(inputURL: URL, outputURL: URL, pageIndices: [Int]) throws {
        guard !pageIndices.isEmpty else { throw PDFOperationError.noPagesSelected }
        guard let doc = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }

        let unique = Set(pageIndices)
        guard unique.count < doc.pageCount else {
            throw PDFOperationError.cannotRemoveEveryPage
        }

        for index in unique.sorted(by: >) {
            guard index >= 0, index < doc.pageCount else {
                throw PDFOperationError.pageOutOfBounds(index + 1)
            }
            doc.removePage(at: index)
        }

        guard doc.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Rotates selected pages by `quarterTurns` × 90° clockwise.
    static func rotate(inputURL: URL, outputURL: URL, pageIndices: [Int], quarterTurns: Int) throws {
        guard let doc = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else {
            guard doc.write(to: outputURL) else { throw PDFOperationError.couldNotWrite(outputURL) }
            return
        }

        let unique = Set(pageIndices)
        for i in 0..<doc.pageCount {
            guard unique.contains(i), let page = doc.page(at: i) else { continue }
            var r = page.rotation
            r = ((r % 360) + 360) % 360
            r += turns * 90
            r = ((r % 360) + 360) % 360
            page.rotation = r
        }

        guard doc.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Writes an encrypted copy that requires `password` to open. The same string is set as both the
    /// user password (needed to open) and the owner password (needed to change permissions), so the
    /// document is fully locked behind one password. The input must be an openable, unencrypted PDF.
    static func encrypt(inputURL: URL, outputURL: URL, password: String) throws {
        guard !password.isEmpty else { throw PDFOperationError.passwordRequired }
        guard let doc = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        guard !doc.isLocked else { throw PDFOperationError.incorrectPassword }
        guard doc.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: password,
        ]
        guard doc.write(to: outputURL, withOptions: options) else {
            throw PDFOperationError.protectionFailed
        }
    }

    /// Writes a decrypted copy with no password. If the source is locked it is unlocked with
    /// `password` first (wrong password → `incorrectPassword`); a source that isn't encrypted at all
    /// throws `notEncrypted` so the tool can say there's nothing to remove.
    static func removePassword(inputURL: URL, outputURL: URL, password: String) throws {
        guard let doc = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        if doc.isLocked {
            guard doc.unlock(withPassword: password) else {
                throw PDFOperationError.incorrectPassword
            }
        } else if !doc.isEncrypted {
            throw PDFOperationError.notEncrypted
        }
        guard doc.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        // Writing the unlocked document directly is NOT enough: PDFKit carries the original
        // encryption into the output, so `write(to:)` on a just-unlocked doc produces a file that
        // is still locked with the same password. Rebuild the pages into a fresh document, which
        // has no encryption dictionary, so the saved copy genuinely opens with no password.
        let output = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else {
                throw PDFOperationError.protectionFailed
            }
            output.insert(page, at: output.pageCount)
        }
        guard output.pageCount > 0, output.write(to: outputURL) else {
            throw PDFOperationError.protectionFailed
        }
    }

    /// Rebuilds the PDF from rendered page images to reduce size. `quality` is 0...1 (JPEG-style tradeoff).
    static func compress(inputURL: URL, outputURL: URL, quality: Double) throws {
        guard let source = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }

        let q = min(1, max(0.05, quality))
        let maxPixel = CGFloat(600 + (2400 - 600) * q)

        let output = PDFDocument()
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else { continue }
            guard let image = renderPage(page, maxPixelDimension: maxPixel) else {
                throw PDFOperationError.compressionFailed
            }
            let media = page.bounds(for: .mediaBox)
            let imageOpts: [PDFPage.ImageInitializationOption: Any] = [
                .mediaBox: NSValue(rect: media),
            ]
            guard let newPage = PDFPage(image: image, options: imageOpts) else {
                throw PDFOperationError.compressionFailed
            }
            // Bitmap already includes PDF rotation via CGPDFPage drawing transform; do not re-apply PDFPage.rotation.
            newPage.rotation = 0
            output.insert(newPage, at: output.pageCount)
        }

        guard output.pageCount > 0 else {
            throw PDFOperationError.compressionFailed
        }

        guard output.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Stamps `options.text` onto every page and writes a new PDF.
    ///
    /// Each page is copied into a fresh CoreGraphics PDF context with `drawPDFPage`, which keeps the
    /// original page **as vector content** (text stays selectable, graphics stay sharp) rather than
    /// rasterizing it the way compression does. The watermark is then drawn on top with CoreText via
    /// an `NSGraphicsContext` bridge, so it is baked into the page content stream — not a strippable
    /// annotation. Intrinsic page rotation is honored: the output page's media box uses the page's
    /// *displayed* size and `getDrawingTransform` maps the source upright before the stamp is added.
    static func watermark(inputURL: URL, outputURL: URL, options: WatermarkOptions) throws {
        let trimmed = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PDFOperationError.watermarkTextRequired }
        guard let source = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.watermarkFailed
        }

        for i in 0..<source.pageCount {
            guard let page = source.page(at: i), let cgPage = page.pageRef else { continue }
            let media = page.bounds(for: .mediaBox)
            let rotation = ((page.rotation % 360) + 360) % 360
            let displaySize = (rotation == 90 || rotation == 270)
                ? CGSize(width: media.height, height: media.width)
                : media.size
            let box = CGRect(origin: .zero, size: displaySize)

            ctx.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)

            ctx.saveGState()
            let transform = cgPage.getDrawingTransform(.mediaBox, rect: box, rotate: 0, preserveAspectRatio: false)
            ctx.concatenate(transform)
            ctx.drawPDFPage(cgPage)
            ctx.restoreGState()

            drawWatermark(in: ctx, box: box, text: trimmed, options: options)

            ctx.endPDFPage()
        }
        ctx.closePDF()

        guard pdfData.length > 0 else { throw PDFOperationError.watermarkFailed }
        try (pdfData as Data).write(to: outputURL)
    }

    private static func drawWatermark(in ctx: CGContext, box: CGRect, text: String, options: WatermarkOptions) {
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        let color = NSColor(
            srgbRed: options.red,
            green: options.green,
            blue: options.blue,
            alpha: max(0, min(1, options.opacity))
        )
        let font = NSFont.boldSystemFont(ofSize: max(4, options.fontSize))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let radians = options.rotationDegrees * .pi / 180

        ctx.saveGState()
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.rotate(by: radians)

        if options.tiled {
            // Cover the page after rotation: step over a square whose side is the page diagonal.
            let diagonal = (box.width * box.width + box.height * box.height).squareRoot()
            let stepX = textSize.width + 100
            let stepY = textSize.height + 100
            var y = -diagonal / 2
            while y <= diagonal / 2 {
                var x = -diagonal / 2
                while x <= diagonal / 2 {
                    string.draw(at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
            }
        } else {
            string.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
        }

        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Permanently removes visual content inside the given rectangles by rasterizing affected pages and painting solid black over those regions—
    /// underlying text and vectors in those areas cannot be copied out afterward (same model as professional “burn-in” redaction). Unmarked pages are copied as PDF unless `options.stripAnnotationsFromUnredactedPages` is true.
    static func redact(
        inputURL: URL,
        outputURL: URL,
        marks: [RedactionMark],
        options: PDFRedactionExportOptions = .default
    ) throws {
        guard !marks.isEmpty else { throw PDFOperationError.noRedactions }
        guard let source = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let grouped = Dictionary(grouping: marks, by: \.pageIndex)
        for key in grouped.keys {
            guard key >= 0, key < source.pageCount else {
                throw PDFOperationError.pageOutOfBounds(key + 1)
            }
        }

        let output = PDFDocument()
        for pageIndex in 0..<source.pageCount {
            guard let page = source.page(at: pageIndex) else { continue }
            let rectsForPage = (grouped[pageIndex] ?? []).map(\.rect)

            if rectsForPage.isEmpty {
                try Self.insertUnredactedPage(
                    into: output,
                    from: page,
                    stripAnnotations: options.stripAnnotationsFromUnredactedPages
                )
            } else {
                let mediaRect = page.bounds(for: .mediaBox)
                guard
                    let cgImage = renderPageWithRedactions(
                        page,
                        redactionRects: rectsForPage,
                        maxPixelDimension: options.maxPixelDimension
                    ),
                    let pdfData = Self.singlePagePDFData(cgImage: cgImage, sourceMediaBox: mediaRect),
                    let tempDoc = PDFDocument(data: pdfData),
                    let newPage = tempDoc.page(at: 0)
                else {
                    throw PDFOperationError.redactionFailed
                }
                // Move the page into `output` so we never rely on `PDFPage.copy()` for image-heavy pages
                // (copy has dropped resolution / MediaBox issues). `insert` removes the page from `tempDoc`.
                newPage.rotation = 0
                output.insert(newPage, at: output.pageCount)
            }
        }

        guard output.pageCount > 0 else { throw PDFOperationError.redactionFailed }
        // Do not pass `saveTextFromOCROption`: PDFKit’s OCR-on-save pass re-encodes image-based pages and
        // reliably produced thumbnail-sized redacted pages in testing (even with screen-optimize off).
        guard output.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Media box for the emitted page: origin at zero, size from the source (avoids odd origins confusing viewers).
    private static func normalizedMediaRectForOutput(_ mediaBox: CGRect) -> CGRect {
        CGRect(x: 0, y: 0, width: abs(mediaBox.width), height: abs(mediaBox.height))
    }

    /// One-page PDF with explicit Core Graphics MediaBox and bitmap drawn into the full page rect.
    private static func singlePagePDFData(cgImage: CGImage, sourceMediaBox: CGRect) -> Data? {
        let pageRect = normalizedMediaRectForOutput(sourceMediaBox)
        guard pageRect.width > 0.5, pageRect.height > 0.5 else { return nil }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = pageRect
        guard let pdfContext = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        pdfContext.beginPDFPage(nil)
        pdfContext.interpolationQuality = .high
        pdfContext.draw(cgImage, in: pageRect)
        pdfContext.endPDFPage()
        pdfContext.closePDF()

        return data as Data
    }

    private static func renderPageWithRedactions(
        _ page: PDFPage,
        redactionRects: [CGRect],
        maxPixelDimension: CGFloat
    ) -> CGImage? {
        let mediaRect = page.bounds(for: .mediaBox)
        guard mediaRect.width > 0, mediaRect.height > 0, let cgPage = page.pageRef else { return nil }

        let merged = mergeOverlappingRedactions(redactionRects, mediaBox: mediaRect)
        guard !merged.isEmpty else { return nil }

        let longest = max(mediaRect.width, mediaRect.height)
        // Supersample past 1 PDF point ≈ 1 pixel (otherwise pages look ~72 dpi and text is fuzzy).
        let rawScale = maxPixelDimension / max(longest, 1)
        let scale = min(max(rawScale, 0.5), 12)
        let pixelW = max(1, Int(ceil(mediaRect.width * scale)))
        let pixelH = max(1, Int(ceil(mediaRect.height * scale)))
        let targetRect = CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(targetRect)

        ctx.saveGState()
        let transform = cgPage.getDrawingTransform(.mediaBox, rect: targetRect, rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.drawPDFPage(cgPage)

        ctx.setBlendMode(.normal)
        ctx.setFillColor(gray: 0, alpha: 1)
        for r in merged {
            ctx.fill(r)
        }
        ctx.restoreGState()

        return ctx.makeImage()
    }

    /// Keep redaction passes from leaving thin gaps between adjacent user rectangles.
    private static func mergeOverlappingRedactions(_ rects: [CGRect], mediaBox: CGRect) -> [CGRect] {
        var list: [CGRect] = rects.compactMap { RedactionMarkGeometry.clipToMediaBox($0, mediaBox: mediaBox) }
        guard !list.isEmpty else { return [] }

        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<list.count {
                for j in (i + 1)..<list.count {
                    if list[i].intersects(list[j]) || list[i].insetBy(dx: -1, dy: -1).intersects(list[j]) {
                        list[i] = list[i].union(list[j])
                        list.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return list
    }

    private static func insertUnredactedPage(
        into output: PDFDocument,
        from page: PDFPage,
        stripAnnotations: Bool
    ) throws {
        guard let copy = page.copy() as? PDFPage else {
            throw PDFOperationError.redactionFailed
        }
        if stripAnnotations {
            let stale = copy.annotations
            for ann in stale {
                copy.removeAnnotation(ann)
            }
        }
        output.insert(copy, at: output.pageCount)
    }

    /// Renders using `CGPDFPage`’s drawing transform so page rotation from the PDF (and PDFKit’s `rotation`) appears upright in the bitmap.
    private static func renderPage(_ page: PDFPage, maxPixelDimension: CGFloat) -> NSImage? {
        let mediaRect = page.bounds(for: .mediaBox)
        guard mediaRect.width > 0, mediaRect.height > 0 else { return nil }

        guard let cgPage = page.pageRef else { return nil }
        let longest = max(mediaRect.width, mediaRect.height)
        let scale = min(1, maxPixelDimension / longest)
        let pixelW = max(1, Int(mediaRect.width * scale))
        let pixelH = max(1, Int(mediaRect.height * scale))
        let targetRect = CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(targetRect)

        ctx.saveGState()
        let transform = cgPage.getDrawingTransform(.mediaBox, rect: targetRect, rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()

        guard let cgImage = ctx.makeImage() else { return nil }
        let logicalSize = NSSize(width: mediaRect.width, height: mediaRect.height)
        return NSImage(cgImage: cgImage, size: logicalSize)
    }
}
