import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Per-edge trim amounts in *displayed* points — top is the top the user sees, regardless of the
/// page's intrinsic rotation. Plain values so they cross the PDF serial queue.
struct CropInsets: Equatable, Sendable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0

    var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }

    /// Element-wise minimum — the largest trim that is safe on every page (unified auto-crop).
    static func elementWiseMin(_ a: CropInsets, _ b: CropInsets) -> CropInsets {
        CropInsets(top: min(a.top, b.top), left: min(a.left, b.left),
                   bottom: min(a.bottom, b.bottom), right: min(a.right, b.right))
    }
}

extension PDFToolkit {
    /// No crop may leave less than this per axis — a sliver page is unusable in every viewer.
    static let minimumCropSide: CGFloat = 24

    /// Insets every page's crop box by the given displayed-edge amounts and writes a new PDF.
    ///
    /// The crop box is what viewers display; page content is not deleted, so cropping back out
    /// remains possible in any PDF editor. Insets are given in *displayed* orientation and mapped
    /// through each page's intrinsic rotation onto the stored (unrotated) crop rect — trimming
    /// "the top you see" of a rotation-90 page moves the stored box's minX edge, not maxY.
    static func crop(inputURL: URL, outputURL: URL, insets: CropInsets) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let output = PDFDocument()
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i), let copy = page.copy() as? PDFPage else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
            let current = page.bounds(for: .cropBox)
            let cropped = insetRect(current, rotation: page.rotation, by: insets)
            guard cropped.width >= minimumCropSide, cropped.height >= minimumCropSide else {
                throw PDFOperationError.cropTooSmall(pageNumber: i + 1)
            }
            copy.setBounds(cropped, for: .cropBox)
            output.insert(copy, at: output.pageCount)
        }
        guard output.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Crops every page to its rendered content bounds plus `padding` points of breathing room.
    ///
    /// Each page is rendered small and scanned for non-background pixels; the tight box those
    /// pixels span becomes the crop (in displayed space, then mapped through rotation like
    /// ``crop(inputURL:outputURL:insets:)``). With `unified` on, the smallest per-edge trim that
    /// is safe on every page is applied uniformly, so a book scan keeps a steady frame. Pages with
    /// no detectable content (blank separators) are left uncropped in per-page mode and don't
    /// shrink the unified trim; a page whose content box would fall under the minimum side keeps
    /// its original crop rather than failing the whole run.
    static func autoCrop(inputURL: URL, outputURL: URL, padding: CGFloat, unified: Bool) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        var perPage: [CropInsets?] = []
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
            perPage.append(contentInsets(of: page, padding: padding))
        }

        let applied: [CropInsets?]
        if unified {
            let detected = perPage.compactMap { $0 }
            if let first = detected.first {
                let shared = detected.dropFirst().reduce(first, CropInsets.elementWiseMin)
                applied = Array(repeating: shared, count: perPage.count)
            } else {
                applied = perPage   // nothing detectable anywhere: change nothing
            }
        } else {
            applied = perPage
        }

        let output = PDFDocument()
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i), let copy = page.copy() as? PDFPage else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
            if let insets = applied[i], !insets.isZero {
                let cropped = insetRect(page.bounds(for: .cropBox), rotation: page.rotation, by: insets)
                if cropped.width >= minimumCropSide, cropped.height >= minimumCropSide {
                    copy.setBounds(cropped, for: .cropBox)
                }
            }
            output.insert(copy, at: output.pageCount)
        }
        guard output.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    // MARK: Geometry

    /// Applies displayed-edge insets to a stored (unrotated) box, mapping each visual edge onto the
    /// media edge it lands on under the page's intrinsic rotation.
    ///
    /// Rotation is clockwise-on-display: at 90° the stored left edge (minX) is what the viewer sees
    /// on top, at 180° the stored bottom (minY) is on top, at 270° the stored right (maxX) is.
    /// Derived once, verified per-rotation by the crop geometry tests.
    static func insetRect(_ rect: CGRect, rotation: Int, by insets: CropInsets) -> CGRect {
        let r = ((rotation % 360) + 360) % 360
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch r {
        case 90:
            minX += insets.top
            maxY -= insets.right
            maxX -= insets.bottom
            minY += insets.left
        case 180:
            minY += insets.top
            minX += insets.right
            maxY -= insets.bottom
            maxX -= insets.left
        case 270:
            maxX -= insets.top
            minY += insets.right
            minX += insets.bottom
            maxY -= insets.left
        default:
            maxY -= insets.top
            maxX -= insets.right
            minY += insets.bottom
            minX += insets.left
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The displayed-edge trims that would tighten `page`'s crop box to its rendered content plus
    /// `padding`, or nil when no content is detectable (a blank page).
    ///
    /// Rendered via `thumbnail(of:for:.cropBox)`, which applies rotation and crop exactly as a
    /// viewer would — so the scan happens in displayed space and the result plugs straight into
    /// ``insetRect(_:rotation:by:)``. ~600 px on the long edge resolves a point to well under a
    /// millimeter of trim, plenty for margins.
    static func contentInsets(of page: PDFPage, padding: CGFloat) -> CropInsets? {
        // Pool per call (= per page in autoCrop's loop): the thumbnail, its TIFF, and the bitmap
        // rep are all page-sized transients; only the tiny CropInsets value leaves.
        autoreleasepool { contentInsetsBody(of: page, padding: padding) }
    }

    private static func contentInsetsBody(of page: PDFPage, padding: CGFloat) -> CropInsets? {
        let crop = page.bounds(for: .cropBox)
        let displaySize = displayedSize(of: crop, rotation: page.rotation)
        guard displaySize.width > 0, displaySize.height > 0 else { return nil }

        let longest = max(displaySize.width, displaySize.height)
        let scale = min(1, 600 / longest)
        let thumbSize = NSSize(width: max(8, displaySize.width * scale),
                               height: max(8, displaySize.height * scale))
        let image = page.thumbnail(of: thumbSize, for: .cropBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return nil }
        var minCol = Int.max
        var maxCol = -1
        var minRow = Int.max
        var maxRow = -1

        // Anything meaningfully darker than paper counts as content ((r+g+b)/765 < 0.92); the
        // thumbnail is drawn on an opaque white ground, so alpha needs no separate handling.
        let threshold = 704   // 0.92 × 765, rounded

        if !rep.isPlanar, rep.bitsPerSample == 8, rep.samplesPerPixel >= 3, let base = rep.bitmapData {
            // Fast path: 8-bit meshed RGB(A) — the format thumbnail TIFFs actually produce. The
            // per-pixel colorAt + usingColorSpace alternative allocates two NSColors per pixel
            // (~half a million per page); raw sample reads do the same threshold test for free.
            let rowBytes = rep.bytesPerRow
            let samples = rep.samplesPerPixel
            let rgbOffset = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            for row in 0..<height {
                let rowPtr = base + row * rowBytes
                for col in 0..<width {
                    let p = rowPtr + col * samples + rgbOffset
                    if Int(p[0]) + Int(p[1]) + Int(p[2]) < threshold {
                        if col < minCol { minCol = col }
                        if col > maxCol { maxCol = col }
                        if row < minRow { minRow = row }
                        if row > maxRow { maxRow = row }
                    }
                }
            }
        } else {
            // Exotic formats (planar, deep color, narrow gray) fall back to the slow universal
            // accessor rather than misreading bytes.
            for row in 0..<height {
                for col in 0..<width {
                    guard let color = rep.colorAt(x: col, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                    let sum = Int((color.redComponent + color.greenComponent + color.blueComponent) * 255)
                    if sum < threshold {
                        minCol = min(minCol, col)
                        maxCol = max(maxCol, col)
                        minRow = min(minRow, row)
                        maxRow = max(maxRow, row)
                    }
                }
            }
        }
        guard maxCol >= 0 else { return nil }

        // Bitmap rows count down from the displayed top; undo the render scale, then pad.
        let sx = displaySize.width / CGFloat(width)
        let sy = displaySize.height / CGFloat(height)
        return CropInsets(
            top: max(0, CGFloat(minRow) * sy - padding),
            left: max(0, CGFloat(minCol) * sx - padding),
            bottom: max(0, (displaySize.height - CGFloat(maxRow + 1) * sy) - padding),
            right: max(0, (displaySize.width - CGFloat(maxCol + 1) * sx) - padding)
        )
    }
}
