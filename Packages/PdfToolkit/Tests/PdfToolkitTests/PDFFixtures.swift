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

    /// Writes a marker PDF, then stamps intrinsic page rotation onto the pages named in `rotations`
    /// (zero-based index → degrees) via PDFKit, so operation tests can exercise pre-rotated inputs.
    ///
    /// The rotated document is built from a throwaway sibling and written to `url` — a *different*
    /// path. Writing a `PDFDocument` back to the very file it was opened from is unreliable: PDFKit
    /// intermittently corrupts the file or returns false, and a half-written document can wedge
    /// PDFKit's shared state so that other tests' PDF work stalls behind it.
    static func writePDF(markers: [String], rotations: [Int: Int], to url: URL) throws {
        let base = url.deletingLastPathComponent()
            .appendingPathComponent("rot-base-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: base) }
        try writePDF(markers: markers, to: base)
        let doc = try #require(PDFDocument(url: base))
        for (index, degrees) in rotations {
            try #require(doc.page(at: index)).rotation = degrees
        }
        #expect(doc.write(to: url))
    }

    /// A file that is not a valid PDF, for "corrupt input" cases.
    static func writeCorrupt(to url: URL) throws {
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: url, options: .atomic)
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
        case .passwordRequired: return "passwordRequired"
        case .incorrectPassword: return "incorrectPassword"
        case .notEncrypted: return "notEncrypted"
        case .protectionFailed: return "protectionFailed"
        }
    }
}
