import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PdfToolkit

/// A unique scratch directory for a test's fixture files, removed when the test's holder is
/// deinitialized. Modeled on SyncCloud's `ContentSignalExtractorTests.FixtureDir` so operation
/// tests can write real PDFs to disk and clean up deterministically.
final class FixtureDir {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PdfToolkitTests-\(UUID().uuidString)", isDirectory: true)

    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// A child URL inside this fixture directory (the file need not exist yet).
    func url(_ name: String) -> URL { url.appendingPathComponent(name) }
    func path(_ name: String) -> String { url(name).path }
}

/// Builders and readers for real PDF fixtures. Pages carry a distinctive marker string drawn with
/// genuine text ops (via CoreText), so PDFKit's text extraction sees them and tests can assert on
/// page identity and order after an operation. The marker for page *i* (1-based) defaults to
/// `MARKERPAGE<i>` — a token unlikely to appear by accident.
enum PDFFixtures {
    /// US Letter, matching CoreGraphics' default and PDFKit's expectations.
    static let letter = CGSize(width: 612, height: 792)

    /// The canonical marker string drawn on page `oneBased`.
    static func marker(_ oneBased: Int) -> String { "MARKERPAGE\(oneBased)" }

    /// Writes a PDF whose page *i* draws `markers[i]` as a single line of real text.
    static func writePDF(markers: [String], to url: URL, size: CGSize = PDFFixtures.letter) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for line in markers {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: NSFont.systemFont(ofSize: 24)]
            )
            context.textPosition = CGPoint(x: 72, y: size.height / 2)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    /// Convenience: an `n`-page PDF whose pages carry the canonical `MARKERPAGE1…MARKERPAGEn` markers.
    @discardableResult
    static func writePDF(pageCount n: Int, to url: URL, size: CGSize = PDFFixtures.letter) throws -> [String] {
        let markers = (1...max(1, n)).map(marker)
        try writePDF(markers: markers, to: url, size: size)
        return markers
    }

    /// Raw bytes of a marker PDF, for callers that build documents in memory.
    static func pdfData(markers: [String], size: CGSize = PDFFixtures.letter) throws -> Data {
        let dir = FixtureDir()
        let url = dir.url("mem.pdf")
        try writePDF(markers: markers, to: url, size: size)
        return try Data(contentsOf: url)
    }

    /// A single US-Letter page carrying two well-separated text tokens: `top` drawn near the top edge
    /// and `bottom` near the bottom edge (PDF coordinates, origin bottom-left). A redaction rectangle
    /// over one half then covers exactly one token, so a pixel-level test can prove the black fill lands
    /// only where the mark is — the covered token gone, the other still rendered.
    static func writeTwoZonePage(top: String, bottom: String, to url: URL, size: CGSize = PDFFixtures.letter) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        for (line, y) in [(top, size.height - 100), (bottom, CGFloat(80))] {
            let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 24)])
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    /// A one-page marker PDF composed from any mix of: custom media size, intrinsic rotation, a
    /// first-page crop box (possibly with non-zero origin), and a green square annotation — for
    /// geometry tests that pin where content and annotations land on rebuilt pages.
    static func writePDF(
        markers: [String],
        size: CGSize = PDFFixtures.letter,
        rotations: [Int: Int] = [:],
        cropFirstPageTo crop: CGRect? = nil,
        greenSquareOnFirstPage annotationRect: CGRect? = nil,
        to url: URL
    ) throws {
        let base = url.deletingLastPathComponent()
            .appendingPathComponent("mix-base-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: base) }
        try writePDF(markers: markers, to: base, size: size)
        let doc = try #require(PDFDocument(url: base))
        if let crop {
            try #require(doc.page(at: 0)).setBounds(crop, for: .cropBox)
        }
        for (index, degrees) in rotations {
            try #require(doc.page(at: index)).rotation = degrees
        }
        if let annotationRect {
            let annotation = PDFAnnotation(bounds: annotationRect, forType: .square, withProperties: nil)
            annotation.color = .green
            annotation.interiorColor = .green
            try #require(doc.page(at: 0)).addAnnotation(annotation)
        }
        #expect(doc.write(to: url))
    }

    /// A file that is not a valid PDF, for "corrupt input" cases.
    static func writeCorrupt(to url: URL) throws {
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: url, options: .atomic)
    }

    /// A marker PDF encrypted with an OWNER password only (empty user password): it opens with no
    /// prompt (`isLocked == false`) yet reports `isEncrypted == true` — the shape of third-party
    /// "restrictions-only" PDFs. PDFKit's writer can't produce one (`PDFToolkit.encrypt` always
    /// sets both passwords), so this builds it with CoreGraphics directly.
    static func writeOwnerRestrictedPDF(markers: [String], to url: URL, ownerPassword: String = "owner-secret") throws {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: letter)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let options: [CFString: Any] = [kCGPDFContextOwnerPassword: ownerPassword]
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, options as CFDictionary))
        for line in markers {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: NSFont.systemFont(ofSize: 24)]
            )
            context.textPosition = CGPoint(x: 72, y: letter.height / 2)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    // Note: the `emptyPDF` guards in `PDFToolkit` are deliberately not fixture-tested. PDFKit's
    // writer cannot persist a zero-page document — an empty (or fully emptied) `PDFDocument` reopens
    // as a one-blank-page file, and a hand-crafted zero-page PDF is rejected on load — so those
    // guards are defensive and unreachable through any constructible input.

    // MARK: Readers

    static func pageCount(at url: URL) throws -> Int {
        try #require(PDFDocument(url: url)).pageCount
    }

    /// The trimmed extracted text of every page, in document order.
    static func pageTexts(at url: URL) throws -> [String] {
        let doc = try #require(PDFDocument(url: url))
        return (0..<doc.pageCount).map { i in
            doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// The `PDFPage.rotation` of every page, in document order.
    static func pageRotations(at url: URL) throws -> [Int] {
        let doc = try #require(PDFDocument(url: url))
        return (0..<doc.pageCount).map { doc.page(at: $0)?.rotation ?? 0 }
    }

    /// The media-box size of one page.
    static func pageSize(at url: URL, page index: Int = 0) throws -> CGSize {
        let doc = try #require(PDFDocument(url: url))
        return try #require(doc.page(at: index)).bounds(for: .mediaBox).size
    }

    /// Renders a page to a bitmap and returns a sampler from PDF-space points (origin bottom-left)
    /// to average brightness in 0…1 (0 = black, 1 = white), so geometry tests can assert *where*
    /// content, annotations, and redaction fills landed on the emitted page.
    static func brightnessSampler(at url: URL, page index: Int = 0) throws -> (CGFloat, CGFloat) -> CGFloat {
        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: index))
        let media = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: media.size, for: .mediaBox)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let sx = CGFloat(rep.pixelsWide) / media.width
        let sy = CGFloat(rep.pixelsHigh) / media.height
        return { pdfX, pdfY in
            let col = min(rep.pixelsWide - 1, max(0, Int(pdfX * sx)))
            let row = min(rep.pixelsHigh - 1, max(0, Int((media.height - pdfY) * sy)))   // flip: PDF y-up → image y-down
            guard let c = rep.colorAt(x: col, y: row)?.usingColorSpace(.deviceRGB) else { return 1 }
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
    }

    /// The darkest sample over a grid of PDF-space points — a cheap "are there glyph strokes in
    /// this band?" probe for asserting text rendered where the geometry says it should.
    static func darkestSample(
        _ sampler: (CGFloat, CGFloat) -> CGFloat,
        xRange: StrideThrough<CGFloat>,
        yValues: [CGFloat]
    ) -> CGFloat {
        var darkest: CGFloat = 1
        for x in xRange {
            for y in yValues {
                darkest = min(darkest, sampler(x, y))
            }
        }
        return darkest
    }
}

extension PDFOperationError {
    /// A stable, associated-value-free tag so tests can assert *which* case was thrown without the
    /// type needing `Equatable` (its associated `URL`/`String`/`Int` payloads are inspected via
    /// `if case` where a test cares about them). Paired with swift-testing's
    /// `#expect(throws: PDFOperationError.self) { … }`, which returns the thrown error.
    var kind: String {
        switch self {
        case .couldNotOpen: return "couldNotOpen"
        case .couldNotWrite: return "couldNotWrite"
        case .outputMatchesInput: return "outputMatchesInput"
        case .invalidPageRange: return "invalidPageRange"
        case .pageOutOfBounds: return "pageOutOfBounds"
        case .pageRangeRequired: return "pageRangeRequired"
        case .cannotRemoveEveryPage: return "cannotRemoveEveryPage"
        case .fileAccessDenied: return "fileAccessDenied"
        case .noInputFiles: return "noInputFiles"
        case .noPagesSelected: return "noPagesSelected"
        case .compressionFailed: return "compressionFailed"
        case .emptyPDF: return "emptyPDF"
        case .noRedactions: return "noRedactions"
        case .redactionFailed: return "redactionFailed"
        case .watermarkTextRequired: return "watermarkTextRequired"
        case .watermarkFailed: return "watermarkFailed"
        case .noFillSignItems: return "noFillSignItems"
        case .fillSignFailed: return "fillSignFailed"
        case .passwordRequired: return "passwordRequired"
        case .incorrectPassword: return "incorrectPassword"
        case .notEncrypted: return "notEncrypted"
        case .protectionFailed: return "protectionFailed"
        case .metadataEncrypted: return "metadataEncrypted"
        case .couldNotOpenImage: return "couldNotOpenImage"
        case .cropTooSmall: return "cropTooSmall"
        case .ocrFailed: return "ocrFailed"
        case .encryptedInput: return "encryptedInput"
        }
    }
}
