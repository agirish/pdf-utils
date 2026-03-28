import AppKit
import Foundation
import PDFKit

enum PDFToolkit {
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

    /// Removes pages (zero-based). Indices should be unique; removed from highest index first.
    static func deletePages(inputURL: URL, outputURL: URL, pageIndices: [Int]) throws {
        guard !pageIndices.isEmpty else { throw PDFOperationError.noPagesSelected }
        guard let doc = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }

        for index in pageIndices.sorted(by: >) {
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
            r += turns * 90
            r %= 360
            if r < 0 { r += 360 }
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
            newPage.rotation = page.rotation
            output.insert(newPage, at: output.pageCount)
        }

        guard output.pageCount > 0 else {
            throw PDFOperationError.compressionFailed
        }

        guard output.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    private static func renderPage(_ page: PDFPage, maxPixelDimension: CGFloat) -> NSImage? {
        let rect = page.bounds(for: .mediaBox)
        guard rect.width > 0, rect.height > 0 else { return nil }

        let longest = max(rect.width, rect.height)
        let scale = min(1, maxPixelDimension / longest)
        let pixelW = max(1, Int(rect.width * scale))
        let pixelH = max(1, Int(rect.height * scale))

        let image = NSImage(size: NSSize(width: pixelW, height: pixelH), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(pixelH))
            ctx.scaleBy(x: CGFloat(pixelW) / rect.width, y: -CGFloat(pixelH) / rect.height)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            return true
        }
        return image
    }
}
