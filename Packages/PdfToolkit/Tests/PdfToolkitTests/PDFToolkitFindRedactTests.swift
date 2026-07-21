import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PdfToolkit

/// Find & redact locates text (literal or preset regex), turns each occurrence into a redaction
/// region in PDF user space, and hands it to the same pipeline a hand-drawn mark uses. These tests
/// pin: the returned rectangles land on the matched text and nowhere else (verified through the real
/// redaction, by pixel), the located geometry is rotation-invariant (so rotated pages need no special
/// case), the preset patterns catch the values they should, and pages with no text layer are surfaced
/// rather than silently skipped.
@Suite struct PDFToolkitFindRedactTests {

    /// A low raster ceiling keeps the redaction bitmaps fast in tests.
    private let fastOptions = PDFRedactionExportOptions(
        stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 800
    )

    // MARK: - Regex presets (unit)

    /// Builds a preset's compiled regex the same way the matcher does, and returns the substrings it
    /// matches in `text`.
    private func matches(_ pattern: FindRedactPattern, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern.regexPattern, options: [.caseInsensitive])
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    @Test func emailPresetCatchesAddressesAndIgnoresProse() throws {
        let found = try matches(.email, in: "Write jane.doe+tag@work.co or bob_99@x.io — not http://x.io or @handle.")
        #expect(found == ["jane.doe+tag@work.co", "bob_99@x.io"])
    }

    @Test func ssnPresetMatchesDashedNinesOnly() throws {
        #expect(try matches(.ssn, in: "SSN 123-45-6789 on file") == ["123-45-6789"])
        // A phone-shaped or over-long digit run must not read as an SSN.
        #expect(try matches(.ssn, in: "acct 1234-56-7890 and 12-345-6789").isEmpty)
    }

    @Test func phonePresetMatchesCommonUSFormats() throws {
        #expect(try matches(.phone, in: "call (415) 555-0132 today").count == 1)
        #expect(try matches(.phone, in: "or +1 415.555.0132").count == 1)
        #expect(try matches(.phone, in: "or 4155550132 works").count == 1)
    }

    @Test func cardPresetMatchesGroupedAndAmexShapes() throws {
        #expect(try matches(.card, in: "Visa 4111 1111 1111 1111 exp") == ["4111 1111 1111 1111"])
        #expect(try matches(.card, in: "Amex 3782 822463 10005 ok") == ["3782 822463 10005"])
        #expect(try matches(.card, in: "order 12345 shipped").isEmpty)
    }

    // MARK: - Literal search geometry (end-to-end, unrotated)

    @Test func literalMatchMarksTheTextAndRedactionBlacksOutOnlyThere() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        // Top line is exactly the email; a different line sits at the bottom.
        try PDFFixtures.writeTwoZonePage(top: "agent@example.com", bottom: "PUBLICLINE", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("agent@example.com"))
        #expect(result.matchCount == 1)
        #expect(result.pageCount == 1)
        let auto = result.marks()
        #expect(auto.count == 1)
        let mark = try #require(auto.first)
        #expect(mark.pageIndex == 0)
        #expect(mark.origin == .autoMatch)
        // The rect sits on the top line (baseline y ≈ 692), starts near the left margin, and spans
        // the email — not the whole page.
        #expect(mark.rect.midY > 640)
        #expect(mark.rect.minX < 90)
        #expect(mark.rect.width > 60)
        #expect(mark.rect.width < 300)

        // Apply the real redaction with exactly that mark.
        try PDFToolkit.redact(inputURL: src, outputURL: out, marks: auto, options: fastOptions)

        // The email text is gone (page rasterized) — not selectable, not recoverable.
        #expect(!(try PDFFixtures.pageTexts(at: out)[0].contains("agent@example.com")))

        let brightness = try PDFFixtures.brightnessSampler(at: out)
        // Solid black exactly where the match was located.
        #expect(brightness(mark.rect.midX, mark.rect.midY) < 0.2)
        // The bottom line was not marked, so its glyphs still render (dark strokes present).
        let bottomGlyphs = PDFFixtures.darkestSample(
            brightness, xRange: stride(from: 76, through: 150, by: 2), yValues: [82, 86, 90]
        )
        #expect(bottomGlyphs < 0.5)
        // The empty middle of the page stayed white — redaction did not spill past the match.
        #expect(brightness(400, 400) > 0.7)
    }

    @Test func literalMatchInsideAWordIsBoundedToTheMatchNotTheWholeLine() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "from agent@example.com now", bottom: "PUBLICLINE", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("agent@example.com"))
        let mark = try #require(result.marks().first)
        // If the character-range → selection mapping were off, the box would start at the line origin
        // and cover "from"; the leading word means a correct mapping starts well to the right of x72.
        #expect(mark.rect.minX > 95)
        #expect(mark.rect.midY > 640)
    }

    @Test func literalSearchIsCaseInsensitiveAndFindsEveryOccurrence() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "Smith and SMITH", bottom: "or smith again", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("smith"))
        #expect(result.matchCount == 3)
        #expect(result.pageCount == 1)
    }

    @Test func noMatchLeavesNoMarks() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "nothing here", bottom: "or here", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("absent"))
        #expect(result.matchCount == 0)
        #expect(result.marks().isEmpty)
    }

    // MARK: - Rotation

    /// The load-bearing geometry guarantee: `PDFSelection.bounds(for:)` returns the match rect in the
    /// page's *unrotated* user space — the space the redaction fill expects — so the very same content
    /// yields the very same rect no matter the page's /Rotate. If this held display-space coordinates
    /// instead, the rotated rect's axes would swap and this would fail.
    @Test func locatedRectIsInvariantToPageRotation() throws {
        let dir = FixtureDir()
        let upright = dir.url("upright.pdf"), rotated = dir.url("rotated.pdf")
        try PDFFixtures.writePDF(markers: ["agent@example.com"], to: upright)
        try PDFFixtures.writePDF(markers: ["agent@example.com"], rotations: [0: 90], to: rotated)

        let a = try #require(PDFToolkit.findRedactionMarks(inputURL: upright, query: .literal("agent@example.com")).marks().first)
        let b = try #require(PDFToolkit.findRedactionMarks(inputURL: rotated, query: .literal("agent@example.com")).marks().first)

        let tol: CGFloat = 1.0
        #expect(abs(a.rect.minX - b.rect.minX) < tol)
        #expect(abs(a.rect.minY - b.rect.minY) < tol)
        #expect(abs(a.rect.width - b.rect.width) < tol)
        #expect(abs(a.rect.height - b.rect.height) < tol)
    }

    @Test func redactionBlacksOutTheMatchOnARotatedPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        // /Rotate 90 US-Letter displays landscape (792×612); the marker's native baseline (72,396)
        // maps to a vertical run near display x≈402 descending from y≈540 (pinned by the redact suite).
        try PDFFixtures.writePDF(markers: ["agent@example.com"], rotations: [0: 90], to: src)

        let auto = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("agent@example.com")).marks()
        #expect(auto.count == 1)
        try PDFToolkit.redact(inputURL: src, outputURL: out, marks: auto, options: fastOptions)

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 792, height: 612))
        #expect(!(try PDFFixtures.pageTexts(at: out)[0].contains("agent@example.com")))

        let brightness = try PDFFixtures.brightnessSampler(at: out)
        // Over the email's displayed glyph column, the samples are now a solid black block (a
        // mis-placed box would leave visible glyphs, so most samples would be white).
        var total = 0, black = 0
        for x in stride(from: CGFloat(398), through: 406, by: 4) {
            for y in stride(from: CGFloat(400), through: 535, by: 5) {
                total += 1
                if brightness(x, y) < 0.2 { black += 1 }
            }
        }
        #expect(Double(black) / Double(total) > 0.85)
        // A corner far from the text stayed white — the whole page was not blacked.
        #expect(brightness(720, 560) > 0.7)
    }

    // MARK: - Presets end-to-end

    @Test func emailPresetMarksEveryAddressInTheDocument() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "jane.doe@work.co", bottom: "bob_99@x.io", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .pattern(.email))
        #expect(result.matchCount == 2)
        #expect(result.marks().allSatisfy { $0.origin == .autoMatch })
    }

    @Test func ssnPresetMarksTheDashedNumber() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "SSN 123-45-6789", bottom: "ref 001", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .pattern(.ssn))
        #expect(result.matchCount == 1)
    }

    // MARK: - No text layer

    @Test func pagesWithoutTextAreReportedNotSilentlySkipped() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        // Page 1 carries text; page 2 is blank (no text layer) — the stand-in for an un-recognized scan.
        try PDFFixtures.writePDF(markers: ["hello agent@example.com", ""], to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .pattern(.email))
        #expect(result.matchCount == 1)
        #expect(result.pagesWithoutText == [1])
    }

    // MARK: - Guards

    @Test func lockedInputIsRefused() throws {
        let dir = FixtureDir()
        let src = dir.url("locked.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        let doc = try #require(PDFDocument(url: src))
        let locked = dir.url("locked-enc.pdf")
        #expect(doc.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))

        #expect(throws: PDFOperationError.self) {
            try PDFToolkit.findRedactionMarks(inputURL: locked, query: .literal("MARKERPAGE1"))
        }
    }
}
