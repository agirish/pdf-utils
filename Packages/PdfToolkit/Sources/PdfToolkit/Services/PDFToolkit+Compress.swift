import AppKit
import CoreGraphics
import Foundation
import PDFKit

// Compress: rebuilds pages as JPEG-backed images to shrink file size, either at a fixed
// quality or by binary-searching the quality ladder to hit a target byte budget. Split out
// of PDFToolkit.swift; still `extension PDFToolkit`, so callers are unchanged.
extension PDFToolkit {
    /// Rebuilds the PDF from rendered page images to reduce size. `quality` is 0...1 (JPEG-style tradeoff).
    public static func compress(inputURL: URL, outputURL: URL, quality: Double) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try compressData(inputURL: inputURL, quality: quality), to: outputURL)
    }

    /// In-memory core of ``compress(inputURL:outputURL:quality:)`` — the guarded open plus the
    /// shared page-rebuild loop.
    ///
    /// `onProgress` reports the 1-based page being rebuilt and the total, once per page, so a long
    /// single-file run can drive a determinate bar; `isCancelled` is polled between pages to stop a
    /// multi-second scan promptly (both mirror the OCR engine). Both default to `nil`, so the batch
    /// path and the size-estimate callers compile unchanged.
    internal static func compressData(
        inputURL: URL,
        quality: Double,
        onProgress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> Data {
        let source = try openUnlockedDocument(at: inputURL)
        return try compressedData(from: source, quality: quality, onProgress: onProgress, isCancelled: isCancelled)
    }

    /// Compresses toward a byte budget by sweeping a bounded ladder of qualities from high to low,
    /// stopping at the first that lands under `targetBytes`. Writes the best attempt: the highest
    /// quality that fits, or — when even the lowest quality overshoots — the smallest file produced,
    /// so an unreachable target still yields the most-compressed result rather than an error.
    ///
    /// The sweep rebuilds the document a handful of times at most (the ladder is short), trading a
    /// few extra rasterizations for a size the caller can actually promise. ``compressToTargetData``
    /// binary-searches the quality ladder for the highest rung that fits, falling back to the smallest
    /// result when none do; its end-to-end behavior is pinned by `PDFToolkitCompressTargetTests`.
    static func compressToTarget(inputURL: URL, outputURL: URL, targetBytes: Int) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        guard let sourceBytes = try? inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }

        // Already at or under the target: keep the cheap on-disk copy instead of pulling the whole
        // source through memory just to write it back out.
        if sourceBytes <= targetBytes {
            // Guarded open before the pass-through, so a locked file errors clearly instead of
            // being copied under a "-compressed" name when it happens to fit the target.
            _ = try openUnlockedDocument(at: inputURL)
            do {
                try? FileManager.default.removeItem(at: outputURL)
                try FileManager.default.copyItem(at: inputURL, to: outputURL)
            } catch {
                throw PDFOperationError.couldNotWrite(outputURL)
            }
            return
        }

        try writeOutput(try compressToTargetData(inputURL: inputURL, targetBytes: targetBytes), to: outputURL)
    }

    /// In-memory core of ``compressToTarget(inputURL:outputURL:targetBytes:)`` — the quality-ladder
    /// sweep. A source that already fits the target passes through as its own unchanged bytes.
    ///
    /// `onProgress`/`isCancelled` (defaulted `nil`, so existing callers are unchanged) thread straight
    /// into each ladder rung's page loop: progress is reported per page *within the current pass* — a
    /// lower rung simply re-reports 1…total — which is enough to keep the bar moving without inventing
    /// multi-pass math, and cancellation is honored between pages exactly as in ``compressData``.
    internal static func compressToTargetData(
        inputURL: URL,
        targetBytes: Int,
        onProgress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> Data {
        // The byte count, not the bytes: pinning the whole source Data across a multi-rung sweep
        // doubled peak memory on exactly the scan-heavy files this operation exists for. The full
        // bytes are read only in the rare inflation fallback at the end.
        guard let sourceBytes = try? inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        // Guarded open before the pass-through below, so a locked file errors clearly instead of
        // being handed back under a "-compressed" name when it happens to fit the target.
        let source = try openUnlockedDocument(at: inputURL)

        // Already at or under the target: rasterizing can only lose quality, so pass the source
        // through unchanged instead of walking the ladder for a worse, possibly larger file.
        if sourceBytes <= targetBytes {
            do {
                return try Data(contentsOf: inputURL)
            } catch {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
        }

        // Attempt size is monotone in quality (a lower rung rasterizes fewer pixels), so binary-
        // search the ladder for the highest rung that fits: at most 3 rebuilds instead of walking
        // up to all 6. Memory holds at most one fitting payload OR the running smallest — once any
        // rung fits, the smallest-so-far fallback can never be needed and is released.
        let ladder: [Double] = [0.9, 0.75, 0.6, 0.45, 0.3, 0.2]
        var fittingBest: Data?
        var smallest: Data?
        var lo = 0
        var hi = ladder.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            // Per-attempt pool: each rung rebuilds the whole document; its scratch must not stack
            // across rungs. The returned Data survives the drain — it's retained, not autoreleased.
            let data = try autoreleasepool {
                try compressedData(from: source, quality: ladder[mid], onProgress: onProgress, isCancelled: isCancelled)
            }
            if data.count <= targetBytes {
                fittingBest = data      // fits — hunt a higher-quality rung
                smallest = nil
                hi = mid - 1
            } else {
                if fittingBest == nil, data.count < (smallest?.count ?? .max) {
                    smallest = data
                }
                lo = mid + 1
            }
        }

        guard var chosen = fittingBest ?? smallest else {
            throw PDFOperationError.compressionFailed
        }
        // Rasterizing a lean vector/text PDF can *inflate* it past every rung. Never hand back a
        // "compressed" file bigger than the original — fall back to the source bytes, so the
        // output is bounded by the input even when the target is unreachable.
        if chosen.count >= sourceBytes {
            do {
                chosen = try Data(contentsOf: inputURL)
            } catch {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
        }

        return chosen
    }

    /// JPEG factor for rebuilt compress pages, driven by the quality lever. The top of the range stays
    /// at 0.85 — the value calibrated to what `PDFPage(image:)` (the previous path) effectively encoded
    /// at, so highest-quality output holds the historical size curve (a photo-class bitmap through
    /// PDFPage(image:) landed within ~8% of an explicit 0.85 encode, probed) — and eases down to ~0.33
    /// at the bottom.
    ///
    /// Encoding quality is deliberately a *second* size lever alongside raster resolution: resolution
    /// downsampling caps at 1 pt/px (`rasterGeometry(allowUpscale: false)`), so on a standard-size page
    /// — whose long edge is already below every quality's `maxPixel` — resolution alone is identical at
    /// every setting and the quality slider would do nothing. Varying the JPEG factor makes quality
    /// (and the strength cards that front it) actually change the output size on ordinary pages too.
    private static func compressedPageJPEGFactor(for quality: Double) -> Double {
        min(0.85, max(0.3, 0.30 + 0.55 * quality))
    }

    /// Rebuilds every page as a bitmap at the resolution implied by `quality` and returns the new PDF
    /// as in-memory `Data`. Shared by `compress` (writes it once) and `compressToTarget` (measures the
    /// size at several qualities before writing the best one) so the page-rebuild loop lives in one place.
    ///
    /// **Streamed**: each page's JPEG bytes flow into the growing output as they're produced, so
    /// peak memory is one page's render/encode scratch plus the compressed output — not every page
    /// bitmap pinned in a `PDFDocument` until a final serialization, which peaked at gigabytes on
    /// long scans. CGPDFContext embeds a JPEG-sourced CGImage as its original DCT data (probed:
    /// a 579 KB JPEG emitted a 583 KB page), so this is `PDFPage(image:)`'s encoding made explicit.
    private static func compressedData(
        from source: PDFDocument,
        quality: Double,
        onProgress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> Data {
        let q = min(1, max(0.05, quality))
        let maxPixel = CGFloat(600 + (2400 - 600) * q)

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.compressionFailed
        }

        var emitted = 0
        for i in 0..<source.pageCount {
            // Report the page about to be rebuilt, then bail before its (expensive) render if the run
            // was cancelled — same order as the OCR engine, so a cancelled compress stops promptly
            // between pages and surfaces as a `CancellationError`.
            onProgress?(i + 1, source.pageCount)
            if isCancelled?() == true { throw CancellationError() }
            // Per-page pool: the render bitmap, its rep, and the JPEG bytes are all page-sized
            // transients — drained page by page, only the compressed stream accumulates.
            try autoreleasepool {
                guard let page = source.page(at: i), let cgPage = page.pageRef else {
                    // A page we can't reach (nil page/pageRef) must fail loudly, not vanish: the old
                    // `return` skipped it, so the output silently came out with fewer pages than the
                    // input, caught only by the coarse `emitted > 0` backstop. Match the render-failure
                    // guard right below and throw, so a page that can't be rebuilt is an error.
                    throw PDFOperationError.compressionFailed
                }
                guard
                    let geometry = rasterGeometry(for: page, maxPixelDimension: maxPixel, allowUpscale: false),
                    let bitmap = renderBitmap(page, cgPage: cgPage, geometry: geometry, redactionFills: []),
                    let jpeg = NSBitmapImageRep(cgImage: bitmap)
                        .representation(using: .jpeg, properties: [.compressionFactor: compressedPageJPEGFactor(for: q)]),
                    let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
                    let jpegImage = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)
                else {
                    throw PDFOperationError.compressionFailed
                }
                // The bitmap is the page as *displayed* (rotation applied, crop box), so the
                // emitted page uses that size — the raw media box would letterbox rotated pages,
                // and no PDFPage.rotation is re-applied on top.
                let box = CGRect(origin: .zero, size: geometry.displaySize)
                beginDisplayedPage(ctx, box: box)
                ctx.interpolationQuality = .high
                ctx.draw(jpegImage, in: box)
                ctx.endPDFPage()
                emitted += 1
            }
        }
        ctx.closePDF()

        guard emitted > 0, pdfData.length > 0 else {
            throw PDFOperationError.compressionFailed
        }
        return pdfData as Data
    }
}
