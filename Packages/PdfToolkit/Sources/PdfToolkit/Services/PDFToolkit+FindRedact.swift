import CoreGraphics
import Foundation
import PDFKit

/// A built-in pattern the Find & redact search can auto-mark. Each case is a regular expression run
/// over every page's extracted text; matches become redaction regions the user reviews before
/// exporting. The patterns are deliberately permissive-but-anchored: they favor catching a real
/// value (an email, an SSN) over rejecting an oddly formatted one, because a human confirms every
/// mark and the cost of a false negative — a leaked identifier — is worse than a false positive the
/// user simply deletes.
enum FindRedactPattern: String, CaseIterable, Identifiable, Sendable {
    case email
    case ssn
    case phone
    case card

    var id: String { rawValue }

    /// Chip label on the Redact screen.
    var displayName: String {
        switch self {
        case .email: return "Emails"
        case .ssn: return "SSNs"
        case .phone: return "Phone numbers"
        case .card: return "Card numbers"
        }
    }

    var symbolName: String {
        switch self {
        case .email: return "at"
        case .ssn: return "person.text.rectangle"
        case .phone: return "phone"
        case .card: return "creditcard"
        }
    }

    /// The ICU regular expression. Raw strings keep the backslashes literal. `(?<!\d)…(?!\d)` guards
    /// stop a phone/card pattern from biting a slice out of a longer digit run.
    var regexPattern: String {
        switch self {
        case .email:
            return #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        case .ssn:
            return #"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#
        case .phone:
            return #"(?<!\d)(?:\+?1[\s.\-]?)?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}(?!\d)"#
        case .card:
            // 16-digit grouped in fours, or the 4-6-5 American Express shape.
            return #"(?<!\d)(?:\d{4}[ \-]?\d{4}[ \-]?\d{4}[ \-]?\d{4}|\d{4}[ \-]?\d{6}[ \-]?\d{5})(?!\d)"#
        }
    }
}

/// What Find & redact should search for. A plain literal substring the user typed, or a preset
/// pattern. Plain values only, so the query crosses onto the PDF serial queue.
enum FindRedactQuery: Sendable, Equatable {
    /// The exact text the user typed. Matched case-insensitively — names and emails vary in casing.
    case literal(String)
    case pattern(FindRedactPattern)

    /// Human phrase for the "N matches for …" summary and the Activity Log.
    var describedTarget: String {
        switch self {
        case .literal(let text): return "“\(text)”"
        case .pattern(let pattern): return pattern.displayName.lowercased()
        }
    }
}

/// One matched occurrence: the page it sits on and the rectangle(s) covering it. A match that wraps
/// across a line break yields more than one rect (one per visual line), so a redaction box never
/// spans the gap between lines.
struct FindRedactMatch: Sendable {
    let pageIndex: Int
    let rects: [CGRect]
}

/// The outcome of one Find & redact scan.
struct FindRedactResult: Sendable {
    /// Every occurrence found, in page then reading order.
    var matches: [FindRedactMatch]
    /// Zero-based indices of pages whose text layer was empty. Search cannot see these (they may be
    /// un-recognized scans), so the caller surfaces them rather than letting matches hide silently.
    var pagesWithoutText: [Int]

    /// Occurrences found (an occurrence spanning two lines still counts once).
    var matchCount: Int { matches.count }
    /// Distinct pages carrying at least one match.
    var pageCount: Int { Set(matches.map(\.pageIndex)).count }

    /// The auto-marks to hand to the editor — one `RedactionMark` per line rectangle, tagged so the
    /// UI can distinguish and clear them.
    func marks() -> [RedactionMark] {
        matches.flatMap { match in
            match.rects.map { RedactionMark(pageIndex: match.pageIndex, rect: $0, origin: .autoMatch) }
        }
    }
}

extension PDFToolkit {
    /// Scans every page's text for `query` and returns the rectangles each match covers, in PDF user
    /// space — the exact coordinate space ``redactData(inputURL:marks:options:)`` fills, so the
    /// returned marks drop straight into the redaction pipeline.
    ///
    /// Runs on the shared PDF serial queue (via ``PDFBackgroundWork``): `PDFDocument` text extraction
    /// and selection geometry are not thread-safe, and this must not race the editor's live document.
    /// Per-page `progress` mirrors OCR so long documents can show a scan bar; `isCancelled` lets the
    /// caller abort a sweep that's outlived its screen.
    ///
    /// Geometry: for each match the character range is turned into a `PDFSelection`, split into per-
    /// line selections, and each line's `bounds(for:)` is taken — PDFKit returns those in the page's
    /// unrotated user space, matching what the redaction fill expects, so rotated and cropped pages
    /// need no hand-rolled coordinate math. Bounds are clipped to the crop box (the visible region)
    /// exactly as a manual ⇧-drag is.
    static func findRedactionMarks(
        inputURL: URL,
        query: FindRedactQuery,
        progress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> FindRedactResult {
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let matcher = try TextMatcher(query: query)

        var matches: [FindRedactMatch] = []
        var pagesWithoutText: [Int] = []

        for pageIndex in 0..<source.pageCount {
            progress?(pageIndex + 1, source.pageCount)
            if isCancelled?() == true { throw CancellationError() }

            guard let page = source.page(at: pageIndex) else { continue }
            let text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pagesWithoutText.append(pageIndex)
                continue
            }

            let cropBox = page.bounds(for: .cropBox)
            for range in matcher.ranges(in: text) {
                let rects = Self.rects(forCharacterRange: range, on: page, cropBox: cropBox)
                if !rects.isEmpty {
                    matches.append(FindRedactMatch(pageIndex: pageIndex, rects: rects))
                }
            }
        }

        return FindRedactResult(matches: matches, pagesWithoutText: pagesWithoutText)
    }

    /// A match's character range → the covering rectangle(s) in PDF user space, one per visual line.
    private static func rects(forCharacterRange range: NSRange, on page: PDFPage, cropBox: CGRect) -> [CGRect] {
        guard range.length > 0, let selection = page.selection(for: range) else { return [] }
        // `selectionsByLine` splits a wrapped match into one selection per line; a single-line match
        // (the common case) comes back as one, and an empty result means fall back to the whole thing.
        let lines = selection.selectionsByLine()
        let perLine = lines.isEmpty ? [selection] : lines

        var rects: [CGRect] = []
        for line in perLine {
            let bounds = line.bounds(for: page)
            guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
            // A hair of outward padding guarantees ascenders/descenders and the last glyph edge are
            // fully covered — a redaction must never leave a sliver of the value peeking. Clipped to
            // the crop box just like a hand-drawn mark so it can't reach into a cropped-out margin.
            let padded = bounds.insetBy(dx: -1.5, dy: -1)
            if let clipped = RedactionMarkGeometry.clipToMediaBox(padded, mediaBox: cropBox) {
                rects.append(clipped)
            }
        }
        return rects
    }
}

/// Compiles a ``FindRedactQuery`` once, then finds every occurrence in a page's text. Built inside
/// the serial-queue closure and reused across pages, so a preset's regex is compiled a single time.
private struct TextMatcher {
    private enum Kind {
        case literal(String)
        case regex(NSRegularExpression)
    }
    private let kind: Kind

    init(query: FindRedactQuery) throws {
        switch query {
        case .literal(let raw):
            let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { throw PDFOperationError.noRedactions }
            kind = .literal(needle)
        case .pattern(let pattern):
            // The built-in patterns are valid; a compile failure would be a programmer error, mapped
            // to the same generic failure the redaction pipeline uses.
            guard let regex = try? NSRegularExpression(pattern: pattern.regexPattern, options: [.caseInsensitive]) else {
                throw PDFOperationError.redactionFailed
            }
            kind = .regex(regex)
        }
    }

    /// Every match range (UTF-16, indexing into `text` the way `PDFPage.selection(for:)` expects).
    func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        switch kind {
        case .literal(let needle):
            var found: [NSRange] = []
            var searchStart = 0
            while searchStart < ns.length {
                let scope = NSRange(location: searchStart, length: ns.length - searchStart)
                let r = ns.range(of: needle, options: [.caseInsensitive], range: scope)
                guard r.location != NSNotFound else { break }
                found.append(r)
                searchStart = r.location + max(r.length, 1)
            }
            return found
        case .regex(let regex):
            return regex.matches(in: text, options: [], range: full).map(\.range)
        }
    }
}
