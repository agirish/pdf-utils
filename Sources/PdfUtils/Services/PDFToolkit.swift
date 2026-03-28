import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum PDFToolkit {
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
            guard let newPage = PDFPage(image: image) else {
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

    /// Renders using `CGPDFPage`’s drawing transform so page rotation from the PDF (and PDFKit’s `rotation`) appears upright in the bitmap.
    private static func renderPage(_ page: PDFPage, maxPixelDimension: CGFloat) -> NSImage? {
        let mediaRect = page.bounds(for: .mediaBox)
        guard mediaRect.width > 0, mediaRect.height > 0 else { return nil }

        let cgPage = page.pageRef
        let longest = max(mediaRect.width, mediaRect.height)
        let scale = min(1, maxPixelDimension / longest)
        let pixelW = max(1, Int(mediaRect.width * scale))
        let pixelH = max(1, Int(mediaRect.height * scale))
        let targetRect = CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH))

        let image = NSImage(size: NSSize(width: pixelW, height: pixelH), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(targetRect)

            ctx.saveGState()
            let transform = cgPage.getDrawingTransform(.mediaBox, rect: targetRect, rotate: 0, preserveAspectRatio: true)
            ctx.concatenate(transform)
            ctx.drawPDFPage(cgPage)
            ctx.restoreGState()
            return true
        }
        return image
    }
}
