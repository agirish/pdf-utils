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

/// One measured compression attempt: the `quality` it was produced at and the resulting file size.
/// Kept as a plain value so the "which attempt do we keep for this target?" decision can be unit
/// tested without any file IO.
struct CompressionAttempt: Equatable, Sendable {
    let quality: Double
    let byteCount: Int
}

enum PDFToolkit {
    /// Quick page count for UI summaries; the URL must already be readable (e.g. under active security scope).
    static func pageCount(at url: URL) -> Int? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return doc.pageCount
    }

    /// Refuses to write an operation's result on top of one of its own inputs.
    ///
    /// Every write path here targets a *fresh* file, so this only fires on caller misuse — but the
    /// consequences of that misuse are silent and unrecoverable: `deletePages`/`rotate` mutate the
    /// loaded `PDFDocument` and then `write(to:)` back over the very file it lazily reads from,
    /// producing an unopenable, zero-recoverable-pages source; the CoreGraphics paths (watermark)
    /// fully materialize the output in memory and would overwrite the original with the transformed
    /// copy. Called before the source is ever opened, this converts that data-losing accident into a
    /// clear error while the source is still untouched. Paths are compared after resolving symlinks
    /// and `.`/`..` so `/var`↔`/private/var`-style aliases don't slip through.
    private static func requireDistinctOutput(_ output: URL, from inputs: [URL]) throws {
        let target = output.resolvingSymlinksInPath().standardizedFileURL
        for input in inputs where input.resolvingSymlinksInPath().standardizedFileURL == target {
            throw PDFOperationError.outputMatchesInput(output)
        }
    }

    /// Merges PDFs in the order given, copying each source page into the result.
    ///
    /// Uses `page.copy()` rather than moving the original page out of its document — the same
    /// approach as `extract`/`split`. Inserting a page that still belongs to another live
    /// `PDFDocument` hangs on macOS 26 (PDFKit spins building an `NSOrderedSet` inside
    /// `insertPage:atIndex:`), which would freeze every merge; copying detaches the page first and
    /// sidesteps it.
    static func merge(inputURLs: [URL], outputURL: URL) throws {
        guard !inputURLs.isEmpty else { throw PDFOperationError.noInputFiles }
        try requireDistinctOutput(outputURL, from: inputURLs)

        let merged = PDFDocument()
        for url in inputURLs {
            guard let doc = PDFDocument(url: url) else {
                throw PDFOperationError.couldNotOpen(url)
            }
            for i in 0..<doc.pageCount {
                guard let copy = doc.page(at: i)?.copy() as? PDFPage else {
                    throw PDFOperationError.couldNotOpen(url)
                }
                merged.insert(copy, at: merged.pageCount)
            }
        }

        guard merged.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Splits a PDF into several files, one per segment. Each `segment` is a list of zero-based
    /// page indices copied (in order) into its own document. Files are written into `directory`
    /// as `baseName-01.pdf`, `baseName-02.pdf`, … (index width grows with the part count) and the
    /// produced URLs are returned in order. A name clash with an existing file is numbered via
    /// ``PDFExportCoordinator/uniqueURL(inDirectory:filename:fileManager:)`` — never overwritten,
    /// upholding the same promise the Files settings make for every single-file tool.
    static func split(inputURL: URL, into directory: URL, baseName: String, segments: [[Int]]) throws -> [URL] {
        guard !segments.isEmpty else { throw PDFOperationError.noPagesSelected }
        guard let source = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let width = max(2, String(segments.count).count)
        var outputs: [URL] = []
        do {
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
                let url = PDFExportCoordinator.uniqueURL(
                    inDirectory: directory,
                    filename: "\(baseName)-\(suffix).pdf"
                )
                try requireDistinctOutput(url, from: [inputURL])
                guard out.write(to: url) else {
                    try? FileManager.default.removeItem(at: url)
                    throw PDFOperationError.couldNotWrite(url)
                }
                outputs.append(url)
            }
        } catch {
            // Unwind parts already written so a failed split never leaves a half set behind.
            // Safe to delete: uniqueURL guarantees every path here was created by this call.
            for url in outputs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        guard !outputs.isEmpty else { throw PDFOperationError.noPagesSelected }
        return outputs
    }

    /// Copies listed pages (zero-based) into a new PDF.
    static func extract(inputURL: URL, outputURL: URL, pageIndices: [Int]) throws {
        guard !pageIndices.isEmpty else { throw PDFOperationError.noPagesSelected }
        try requireDistinctOutput(outputURL, from: [inputURL])
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
        try requireDistinctOutput(outputURL, from: [inputURL])
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
        try requireDistinctOutput(outputURL, from: [inputURL])
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
        try requireDistinctOutput(outputURL, from: [inputURL])
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
        try requireDistinctOutput(outputURL, from: [inputURL])
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
        // The rebuild keeps pages and the info dictionary; document-level structure that PDFKit
        // can't re-attach (outline/bookmarks, attachments, form dictionary) does not survive —
        // the tool's UI discloses this.
        let output = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else {
                throw PDFOperationError.protectionFailed
            }
            output.insert(page, at: output.pageCount)
        }
        output.documentAttributes = doc.documentAttributes
        guard output.pageCount > 0, output.write(to: outputURL) else {
            throw PDFOperationError.protectionFailed
        }
    }

    /// Rebuilds the PDF from rendered page images to reduce size. `quality` is 0...1 (JPEG-style tradeoff).
    static func compress(inputURL: URL, outputURL: URL, quality: Double) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        guard let source = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        let data = try compressedData(from: source, quality: quality)
        do {
            try data.write(to: outputURL)
        } catch {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Compresses toward a byte budget by sweeping a bounded ladder of qualities from high to low,
    /// stopping at the first that lands under `targetBytes`. Writes the best attempt: the highest
    /// quality that fits, or — when even the lowest quality overshoots — the smallest file produced,
    /// so an unreachable target still yields the most-compressed result rather than an error.
    ///
    /// The sweep rebuilds the document a handful of times at most (the ladder is short), trading a
    /// few extra rasterizations for a size the caller can actually promise. The pure "which attempt
    /// wins?" decision lives in `selectBestAttempt` so it can be unit tested without file IO.
    static func compressToTarget(inputURL: URL, outputURL: URL, targetBytes: Int) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        guard let source = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }

        // Highest first so the loop can stop the moment an attempt fits — a generous target then
        // costs a single rebuild instead of walking the whole ladder.
        let ladder: [Double] = [0.9, 0.75, 0.6, 0.45, 0.3, 0.2]
        var produced: [(attempt: CompressionAttempt, data: Data)] = []
        for q in ladder {
            let data = try compressedData(from: source, quality: q)
            produced.append((CompressionAttempt(quality: q, byteCount: data.count), data))
            if data.count <= targetBytes { break }
        }

        guard
            let best = selectBestAttempt(from: produced.map(\.attempt), targetBytes: targetBytes),
            let data = produced.first(where: { $0.attempt == best })?.data
        else {
            throw PDFOperationError.compressionFailed
        }

        do {
            try data.write(to: outputURL)
        } catch {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Chooses which measured attempt to keep for a target size: the **highest-quality** attempt whose
    /// file fits under `targetBytes`, or — when even the smallest overshoots — the **smallest** file
    /// produced. Pure and IO-free so the target-size loop's decision is directly testable.
    static func selectBestAttempt(from attempts: [CompressionAttempt], targetBytes: Int) -> CompressionAttempt? {
        let fitting = attempts.filter { $0.byteCount <= targetBytes }
        if !fitting.isEmpty {
            return fitting.max { $0.quality < $1.quality }
        }
        return attempts.min { $0.byteCount < $1.byteCount }
    }

    /// Rebuilds every page as a bitmap at the resolution implied by `quality` and returns the new PDF
    /// as in-memory `Data`. Shared by `compress` (writes it once) and `compressToTarget` (measures the
    /// size at several qualities before writing the best one) so the page-rebuild loop lives in one place.
    private static func compressedData(from source: PDFDocument, quality: Double) throws -> Data {
        let q = min(1, max(0.05, quality))
        let maxPixel = CGFloat(600 + (2400 - 600) * q)

        let output = PDFDocument()
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else { continue }
            guard let image = renderPage(page, maxPixelDimension: maxPixel) else {
                throw PDFOperationError.compressionFailed
            }
            // The bitmap is the page as *displayed* (rotation applied, crop box), so the emitted
            // page must use that size — the raw media box would letterbox rotated pages.
            let pageRect = CGRect(origin: .zero, size: image.size)
            let imageOpts: [PDFPage.ImageInitializationOption: Any] = [
                .mediaBox: NSValue(rect: pageRect),
            ]
            guard let newPage = PDFPage(image: image, options: imageOpts) else {
                throw PDFOperationError.compressionFailed
            }
            // Bitmap already includes PDF rotation via CGPDFPage drawing transform; do not re-apply PDFPage.rotation.
            newPage.rotation = 0
            output.insert(newPage, at: output.pageCount)
        }

        guard output.pageCount > 0, let data = output.dataRepresentation() else {
            throw PDFOperationError.compressionFailed
        }
        return data
    }

    /// Stamps `options.text` onto every page and writes a new PDF.
    ///
    /// Each page is copied into a fresh CoreGraphics PDF context with `drawPDFPage`, which keeps the
    /// original page **as vector content** (text stays selectable, graphics stay sharp) rather than
    /// rasterizing it the way compression does. The watermark is then drawn on top with CoreText via
    /// an `NSGraphicsContext` bridge, so it is baked into the page content stream — not a strippable
    /// annotation. Intrinsic page rotation is honored: the output page's media box uses the page's
    /// *displayed* size and `getDrawingTransform` maps the source upright before the stamp is added.
    /// Visible annotation appearances (form values, signatures, notes) are drawn after the content
    /// so they survive the rebuild — flattened into the page rather than silently dropped.
    static func watermark(inputURL: URL, outputURL: URL, options: WatermarkOptions) throws {
        let trimmed = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PDFOperationError.watermarkTextRequired }
        try requireDistinctOutput(outputURL, from: [inputURL])
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
            // Crop box, not media box: it is what viewers display, so the stamped page keeps the
            // visible size and never resurfaces content the source's crop deliberately hid.
            let cropBox = page.bounds(for: .cropBox)
            let rotation = ((page.rotation % 360) + 360) % 360
            let displaySize = (rotation == 90 || rotation == 270)
                ? CGSize(width: cropBox.height, height: cropBox.width)
                : cropBox.size
            let box = CGRect(origin: .zero, size: displaySize)

            ctx.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)

            ctx.saveGState()
            let transform = cgPage.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: false)
            ctx.concatenate(transform)
            ctx.drawPDFPage(cgPage)
            drawAnnotations(of: page, in: ctx)
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

    /// Bakes placed text and drawn signatures onto their pages and writes a new PDF.
    ///
    /// Built exactly like ``watermark``: each page is redrawn as **vector** content with
    /// `drawPDFPage` (so the underlying text stays selectable) and its visible annotations are
    /// flattened in. The placed items are then drawn *inside the same crop-box drawing transform* as
    /// the content — so an item's page-space rectangle (captured from the placement canvas) lands on
    /// exactly the pixels the user saw, honoring page rotation and crop just like redaction fills.
    /// Typed runs are drawn with CoreText (they remain selectable, searchable vector text); drawn
    /// signatures are stroked as vector paths from their normalized polylines — never rasterized.
    static func fillAndSign(inputURL: URL, outputURL: URL, items: [FillSignItem]) throws {
        let inked = items.filter(\.hasInk)
        guard !inked.isEmpty else { throw PDFOperationError.noFillSignItems }
        try requireDistinctOutput(outputURL, from: [inputURL])
        guard let source = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let byPage = Dictionary(grouping: inked, by: \.pageIndex)
        for key in byPage.keys where key < 0 || key >= source.pageCount {
            throw PDFOperationError.pageOutOfBounds(key + 1)
        }

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.fillSignFailed
        }

        for i in 0..<source.pageCount {
            guard let page = source.page(at: i), let cgPage = page.pageRef else { continue }
            let cropBox = page.bounds(for: .cropBox)
            let rotation = ((page.rotation % 360) + 360) % 360
            let displaySize = (rotation == 90 || rotation == 270)
                ? CGSize(width: cropBox.height, height: cropBox.width)
                : cropBox.size
            let box = CGRect(origin: .zero, size: displaySize)

            ctx.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)

            ctx.saveGState()
            let transform = cgPage.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: false)
            ctx.concatenate(transform)
            ctx.drawPDFPage(cgPage)
            drawAnnotations(of: page, in: ctx)
            for item in byPage[i] ?? [] {
                drawFillSignItem(item, in: ctx)
            }
            ctx.restoreGState()

            ctx.endPDFPage()
        }
        ctx.closePDF()

        guard pdfData.length > 0 else { throw PDFOperationError.fillSignFailed }
        try (pdfData as Data).write(to: outputURL)
    }

    private static func drawFillSignItem(_ item: FillSignItem, in ctx: CGContext) {
        switch item.content {
        case .text(let text):
            drawFillText(text, in: item.rect, ctx: ctx)
        case .signature(let signature):
            drawFillSignature(signature, in: item.rect, ctx: ctx)
        }
    }

    private static func drawFillText(_ text: FillSignText, in rect: CGRect, ctx: CGContext) {
        let trimmed = text.string
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        let color = NSColor(srgbRed: text.red, green: text.green, blue: text.blue, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: scriptOrSystemFont(size: max(4, text.fontSize), script: text.isScript),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        // `flipped: false` matches the placement overlay: the first line sits at the top of the box.
        NSAttributedString(string: trimmed, attributes: attributes).draw(in: rect)

        NSGraphicsContext.restoreGraphicsState()
    }

    /// A handwriting face for typed signatures, falling back down a chain and finally to an italic
    /// system font so a machine missing the script fonts still renders something signature-like.
    static func scriptOrSystemFont(size: CGFloat, script: Bool) -> NSFont {
        guard script else { return NSFont.systemFont(ofSize: size) }
        for name in ["SnellRoundhand", "SavoyeLetPlain", "Zapfino", "BradleyHandITCTT-Bold"] {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }

    private static func drawFillSignature(_ signature: FillSignSignature, in rect: CGRect, ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let strokes = signature.strokes.filter { !$0.isEmpty }
        guard !strokes.isEmpty else { return }

        ctx.saveGState()
        ctx.setStrokeColor(red: signature.red, green: signature.green, blue: signature.blue, alpha: 1)
        ctx.setFillColor(red: signature.red, green: signature.green, blue: signature.blue, alpha: 1)
        let lineWidth = max(0.4, signature.penWidthFraction * min(rect.width, rect.height))
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for stroke in strokes {
            let points = stroke.map { FillSignGeometry.pagePoint(normalized: $0, in: rect) }
            if points.count == 1 {
                // A single tap (a dot on an "i", a period) has no length to stroke — fill a nib blob.
                let p = points[0]
                let r = lineWidth / 2
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: lineWidth, height: lineWidth))
                continue
            }
            ctx.beginPath()
            ctx.addLines(between: points)
            ctx.strokePath()
        }

        ctx.restoreGState()
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
        try requireDistinctOutput(outputURL, from: [inputURL])
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
                guard
                    let cgPage = page.pageRef,
                    let geometry = rasterGeometry(
                        for: page,
                        maxPixelDimension: options.maxPixelDimension,
                        allowUpscale: true
                    )
                else {
                    throw PDFOperationError.redactionFailed
                }
                let fills = mergeOverlappingRedactions(rectsForPage, pageBox: geometry.pageBox)
                guard
                    !fills.isEmpty,
                    let cgImage = renderBitmap(page, cgPage: cgPage, geometry: geometry, redactionFills: fills),
                    let pdfData = Self.singlePagePDFData(cgImage: cgImage, pageSize: geometry.displaySize),
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

    /// One-page PDF with explicit Core Graphics MediaBox and bitmap drawn into the full page rect.
    /// The page is emitted at origin zero with the given (displayed) size, so odd source origins and
    /// intrinsic rotation never confuse viewers.
    private static func singlePagePDFData(cgImage: CGImage, pageSize: CGSize) -> Data? {
        let pageRect = CGRect(x: 0, y: 0, width: abs(pageSize.width), height: abs(pageSize.height))
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

    /// How a page maps onto a raster: the crop box drawn (what viewers actually display), its
    /// rotation-aware displayed size in points, and the exact pixels-per-point scale.
    private struct PageRasterGeometry {
        let pageBox: CGRect
        let displaySize: CGSize
        let scale: CGFloat
        var pixelWidth: Int { max(1, Int(ceil(displaySize.width * scale))) }
        var pixelHeight: Int { max(1, Int(ceil(displaySize.height * scale))) }
    }

    private static func rasterGeometry(
        for page: PDFPage,
        maxPixelDimension: CGFloat,
        allowUpscale: Bool
    ) -> PageRasterGeometry? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0, page.pageRef != nil else { return nil }
        let rotation = ((page.rotation % 360) + 360) % 360
        let displaySize = (rotation == 90 || rotation == 270)
            ? CGSize(width: box.height, height: box.width)
            : box.size
        let longest = max(displaySize.width, displaySize.height)
        let raw = maxPixelDimension / max(longest, 1)
        // Redaction supersamples past 1 PDF point per pixel (otherwise pages look ~72 dpi and text
        // is fuzzy); compression only ever downsamples.
        let scale = allowUpscale ? min(max(raw, 0.5), 12) : min(1, raw)
        return PageRasterGeometry(pageBox: box, displaySize: displaySize, scale: scale)
    }

    /// Draws the page — content stream, then visible annotation appearances, then any redaction
    /// fills — upright into a fresh bitmap of `geometry`'s pixel size.
    ///
    /// The supersample scale is applied to the context *before* the page transform, and the
    /// transform maps into a 1x, display-sized rect. Both halves matter: `getDrawingTransform`
    /// refuses to scale a page up, so asking it to map straight into a supersampled pixel rect
    /// silently drew the page 1:1 and centered — a redacted US Letter page came out at ~1/5 size in
    /// a field of white. And the rect must use the rotation-swapped *displayed* size, or a
    /// /Rotate 90 page gets letterboxed into its unrotated aspect. Redaction rects arrive in PDF
    /// user space and are filled under the same transform, so they track the content exactly.
    private static func renderBitmap(
        _ page: PDFPage,
        cgPage: CGPDFPage,
        geometry: PageRasterGeometry,
        redactionFills: [CGRect]
    ) -> CGImage? {
        let pixelW = geometry.pixelWidth
        let pixelH = geometry.pixelHeight
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
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH)))

        ctx.saveGState()
        ctx.scaleBy(x: geometry.scale, y: geometry.scale)
        let displayRect = CGRect(origin: .zero, size: geometry.displaySize)
        let transform = cgPage.getDrawingTransform(.cropBox, rect: displayRect, rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.drawPDFPage(cgPage)
        drawAnnotations(of: page, in: ctx)

        ctx.setBlendMode(.normal)
        ctx.setFillColor(gray: 0, alpha: 1)
        for r in redactionFills {
            ctx.fill(r)
        }
        ctx.restoreGState()

        return ctx.makeImage()
    }

    /// Annotation appearances (typed form values, ink signatures, notes, highlights, stamps) live in
    /// `/Annots`, outside the content stream `drawPDFPage` replays — a rebuilt page silently loses
    /// them unless they are drawn here, in the same PDF-space transform as the content. Redaction
    /// fills paint after this, so a marked annotation stays buried under black.
    private static func drawAnnotations(of page: PDFPage, in ctx: CGContext) {
        let visible = page.annotations.filter(\.shouldDisplay)
        guard !visible.isEmpty else { return }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for annotation in visible {
            annotation.draw(with: .cropBox, in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Keep redaction passes from leaving thin gaps between adjacent user rectangles.
    private static func mergeOverlappingRedactions(_ rects: [CGRect], pageBox: CGRect) -> [CGRect] {
        var list: [CGRect] = rects.compactMap { RedactionMarkGeometry.clipToMediaBox($0, mediaBox: pageBox) }
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

    /// Renders the page — content plus visible annotations — upright at its displayed size via the
    /// shared raster pipeline (rotation-swapped crop box, exact scale). Compression never upscales.
    private static func renderPage(_ page: PDFPage, maxPixelDimension: CGFloat) -> NSImage? {
        guard
            let cgPage = page.pageRef,
            let geometry = rasterGeometry(for: page, maxPixelDimension: maxPixelDimension, allowUpscale: false),
            let cgImage = renderBitmap(page, cgPage: cgPage, geometry: geometry, redactionFills: [])
        else { return nil }
        let logicalSize = NSSize(width: geometry.displaySize.width, height: geometry.displaySize.height)
        return NSImage(cgImage: cgImage, size: logicalSize)
    }
}
