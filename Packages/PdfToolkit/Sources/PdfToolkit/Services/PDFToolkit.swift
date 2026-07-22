import AppKit
import CoreGraphics
import Foundation
import ImageIO
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

/// How a Protect run encrypts a file. Plain values (no PDFKit objects) so the config crosses the PDF
/// serial queue and can be snapshotted into a batch operation.
///
/// Two styles express the same struct:
/// - **Lock to open** — `userPassword == ownerPassword`, `permissionBits == nil`. One password opens
///   the file and, once open, grants full access; the original single-password behavior.
/// - **Restrict editing** — `userPassword == ""`, `ownerPassword` set, `permissionBits` set. The file
///   opens (and prints) freely, but copying/editing/assembly need the owner password.
struct ProtectionOptions: Sendable {
    /// The password required to *open* the file. Empty means the file opens without a password.
    var userPassword: String
    /// The password required to change permissions or remove protection. Always required (an empty
    /// owner password throws `passwordRequired`).
    var ownerPassword: String
    /// Raw `PDFAccessPermissions` bits to record, or `nil` to write none (full owner access — the
    /// single-password lock). See ``PDFPermissionPreset``.
    var permissionBits: UInt?
}

/// Named `PDFAccessPermissions` bitmasks for ``ProtectionOptions``. Built from raw bit values because
/// `PDFAccessPermissions` is imported as an `NS_ENUM` rather than an `OptionSet`, so the members are
/// combined by OR-ing their `rawValue`s.
enum PDFPermissionPreset {
    /// Opens and prints freely; copying text, editing, annotating, and page assembly all require the
    /// owner password. Accessibility extraction stays allowed so screen readers keep working.
    static var openAndPrintOnly: UInt {
        PDFAccessPermissions.allowsLowQualityPrinting.rawValue
            | PDFAccessPermissions.allowsHighQualityPrinting.rawValue
            | PDFAccessPermissions.allowsContentAccessibility.rawValue
    }
}

/// A decoded logo carried by value so ``WatermarkOptions`` stays `Sendable` across the PDF serial
/// queue and can be snapshotted into a batch operation. The `CGImage` is immutable and only ever
/// read (drawn), so `@unchecked Sendable` is safe — nothing mutates it after decode.
struct WatermarkImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// How a watermark is stamped onto the chosen pages. RGB components (not `NSColor`) and a decoded
/// `CGImage` (not a URL) keep this `Sendable` for the background PDF queue and for a batch snapshot.
///
/// New fields are all defaulted so the original text-watermark call sites keep compiling unchanged;
/// `content == .text` with `pageScope == .all` reproduces the pre-existing behavior exactly.
struct WatermarkOptions: Sendable {
    /// Whether this watermark stamps text or a logo image. Image is the smallpdf-beating addition.
    enum Content: Sendable {
        case text
        case image
    }

    /// Which pages receive the mark. Resolved against each document's real page count at stamp
    /// time (so it stays correct per-file in a batch), never pre-expanded here.
    enum PageScope: Sendable, Equatable {
        case all
        case firstPageOnly
        /// `PageRangeParser` syntax, e.g. "1, 3-5, 8". Empty text is an error, not "all pages".
        case custom(String)
    }

    var text: String
    var fontSize: CGFloat
    /// 0…1 fill opacity of the stamp (applied to text fill and, for images, composited with the
    /// logo's own alpha so a transparent PNG fades correctly).
    var opacity: CGFloat
    var rotationDegrees: CGFloat
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// When true, the mark is repeated across the whole page; otherwise it is drawn once, centered.
    var tiled: Bool
    // --- Additive: all defaulted so existing initializers stay source-compatible ---
    /// Text vs. image. Defaults to `.text`, the original behavior.
    var content: Content = .text
    /// Font family (display or PostScript name) for text marks; `nil` = bold system font (default).
    var fontName: String? = nil
    /// The decoded logo for `.image` content; `nil` for text marks.
    var image: WatermarkImage? = nil
    /// Logo size as a fraction of the page, aspect-fit inside `imageScale × page` (0…1). Only used
    /// for `.image` content.
    var imageScale: CGFloat = 0.4
    /// Which pages get the mark. Defaults to every page.
    var pageScope: PageScope = .all
}

public enum PDFToolkit {
    /// Quick page count for UI summaries; the URL must already be readable (e.g. under active security scope).
    public static func pageCount(at url: URL) -> Int? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return doc.pageCount
    }

    /// Wraps any degree value into 0…359, handling negatives (both PDFKit's `page.rotation` and our
    /// quarter-turn math can go negative). Centralizes the `((x % 360) + 360) % 360` idiom that
    /// rotate, crop, watermark, and page-replay each inlined.
    static func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    /// Opens a PDF for a content operation, refusing password-locked documents.
    ///
    /// A locked `PDFDocument` opens "successfully" and even reports its real page count, but its
    /// pages are inaccessible placeholders: `page.copy()` yields blank US-Letter pages (verified
    /// empirically — merge/extract/split/reorder silently emitted contentless output), `pageRef`
    /// is nil (compress/watermark/fill-sign fail with generic errors), and `write(to:)` on the
    /// mutated document just returns false (rotate/delete reported "could not save"). Refusing up
    /// front turns silent data loss and misleading failures into one clear, actionable error.
    /// Encrypted-but-not-locked documents (empty user password) pass through: PDFKit unlocks them
    /// implicitly and their pages are fully accessible. Internal so the per-tool extensions
    /// (Crop, OCR, …) open through the same guard.
    static func openUnlockedDocument(at url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw PDFOperationError.couldNotOpen(url)
        }
        guard !doc.isLocked else {
            throw PDFOperationError.encryptedInput(url)
        }
        return doc
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
    // Internal (not private): operation extensions in sibling files (e.g. metadata) share this guard.
    static func requireDistinctOutput(_ output: URL, from inputs: [URL]) throws {
        let target = output.resolvingSymlinksInPath().standardizedFileURL
        for input in inputs where input.resolvingSymlinksInPath().standardizedFileURL == target {
            throw PDFOperationError.outputMatchesInput(output)
        }
    }

    /// Lands a core's in-memory result at `outputURL` atomically, mapping any write failure to the
    /// operation-level `couldNotWrite` the URL API has always thrown. The one write path every
    /// URL wrapper shares now that the operations build their result as `Data`.
    // Internal (not private): operation extensions in sibling files (Crop, Metadata, …) share it.
    static func writeOutput(_ data: Data, to outputURL: URL) throws {
        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }

    /// Merges whole PDFs in the order given, copying every source page into the result.
    public static func merge(inputURLs: [URL], outputURL: URL) throws {
        try requireDistinctOutput(outputURL, from: inputURLs)
        try writeOutput(try mergeData(inputURLs: inputURLs), to: outputURL)
    }

    /// Merges a per-input page selection in list order.
    public static func merge(inputs: [(url: URL, pageIndices: [Int]?)], outputURL: URL) throws {
        try requireDistinctOutput(outputURL, from: inputs.map(\.url))
        try writeOutput(try mergeData(inputs: inputs), to: outputURL)
    }

    /// In-memory core of ``merge(inputURLs:outputURL:)`` — whole files, every page.
    internal static func mergeData(inputURLs: [URL]) throws -> Data {
        try mergeData(inputs: inputURLs.map { (url: $0, pageIndices: nil) })
    }

    /// In-memory core of the merge, with a per-input page selection — the tool views consume the
    /// bytes directly, skipping the temp-file round trip.
    ///
    /// Each input carries `pageIndices`: `nil` copies **every** page of that file (the whole-file
    /// default), a non-nil array copies exactly those zero-based pages **in the order given**
    /// (duplicates allowed, so a caller can reorder or repeat within a file), and an empty array
    /// contributes no pages from that input. At least one page must survive across all inputs, or
    /// `noPagesSelected` is thrown — PDFKit cannot persist a zero-page document.
    ///
    /// Uses `page.copy()` rather than moving the original page out of its document — the same
    /// approach as `extract`/`split`. Inserting a page that still belongs to another live
    /// `PDFDocument` hangs on macOS 26 (PDFKit spins building an `NSOrderedSet` inside
    /// `insertPage:atIndex:`), which would freeze every merge; copying detaches the page first and
    /// sidesteps it.
    internal static func mergeData(inputs: [(url: URL, pageIndices: [Int]?)]) throws -> Data {
        guard !inputs.isEmpty else { throw PDFOperationError.noInputFiles }

        let merged = PDFDocument()
        for input in inputs {
            let doc = try openUnlockedDocument(at: input.url)
            let indices = input.pageIndices ?? Array(0..<doc.pageCount)
            for i in indices {
                guard i >= 0, i < doc.pageCount else {
                    throw PDFOperationError.pageOutOfBounds(i + 1)
                }
                guard let copy = doc.page(at: i)?.copy() as? PDFPage else {
                    throw PDFOperationError.couldNotOpen(input.url)
                }
                merged.insert(copy, at: merged.pageCount)
            }
        }

        // A selection that copies nothing (every page dropped/filtered out) would otherwise be
        // written as a one-blank-page file by PDFKit's writer — refuse it with a clear error instead.
        guard merged.pageCount > 0 else { throw PDFOperationError.noPagesSelected }
        guard let data = merged.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
    }

    /// Splits a PDF into several files, one per segment. Each `segment` is a list of zero-based
    /// page indices copied (in order) into its own document. Files are written into `directory`
    /// as `baseName-01.pdf`, `baseName-02.pdf`, … (index width grows with the part count) and the
    /// produced URLs are returned in order. A name clash with an existing file is numbered via
    /// ``PDFExportCoordinator/uniqueURL(inDirectory:filename:fileManager:)`` — never overwritten,
    /// upholding the same promise the Files settings make for every single-file tool.
    static func split(inputURL: URL, into directory: URL, baseName: String, segments: [[Int]]) throws -> [URL] {
        guard !segments.isEmpty else { throw PDFOperationError.noPagesSelected }
        let source = try openUnlockedDocument(at: inputURL)
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
    public static func extract(inputURL: URL, outputURL: URL, pageIndices: [Int]) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try extractData(inputURL: inputURL, pageIndices: pageIndices), to: outputURL)
    }

    /// In-memory core of ``extract(inputURL:outputURL:pageIndices:)``.
    internal static func extractData(inputURL: URL, pageIndices: [Int]) throws -> Data {
        guard !pageIndices.isEmpty else { throw PDFOperationError.noPagesSelected }
        let source = try openUnlockedDocument(at: inputURL)

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

        guard let data = out.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
    }

    /// Writes a new PDF whose pages follow `order` (a permutation of the source's zero-based
    /// indices). This is `extract` with the full page set reshuffled — a page appears exactly
    /// where the new order places it.
    static func reorder(inputURL: URL, outputURL: URL, order: [Int]) throws {
        try extract(inputURL: inputURL, outputURL: outputURL, pageIndices: order)
    }

    /// In-memory core of ``reorder(inputURL:outputURL:order:)`` — `extract`'s core reshuffled.
    internal static func reorderData(inputURL: URL, order: [Int]) throws -> Data {
        try extractData(inputURL: inputURL, pageIndices: order)
    }

    /// Removes pages (zero-based). Duplicates are ignored.
    static func deletePages(inputURL: URL, outputURL: URL, pageIndices: [Int]) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try deletePagesData(inputURL: inputURL, pageIndices: pageIndices), to: outputURL)
    }

    /// In-memory core of ``deletePages(inputURL:outputURL:pageIndices:)``. Removed from highest
    /// index first.
    internal static func deletePagesData(inputURL: URL, pageIndices: [Int]) throws -> Data {
        guard !pageIndices.isEmpty else { throw PDFOperationError.noPagesSelected }
        let doc = try openUnlockedDocument(at: inputURL)

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

        guard let data = doc.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
    }

    /// Rotates selected pages by `quarterTurns` × 90° clockwise.
    public static func rotate(inputURL: URL, outputURL: URL, pageIndices: [Int], quarterTurns: Int) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(
            try rotateData(inputURL: inputURL, pageIndices: pageIndices, quarterTurns: quarterTurns),
            to: outputURL
        )
    }

    /// In-memory core of ``rotate(inputURL:outputURL:pageIndices:quarterTurns:)``.
    internal static func rotateData(inputURL: URL, pageIndices: [Int], quarterTurns: Int) throws -> Data {
        let doc = try openUnlockedDocument(at: inputURL)
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns != 0 {
            let unique = Set(pageIndices)
            for i in 0..<doc.pageCount {
                guard unique.contains(i), let page = doc.page(at: i) else { continue }
                var r = page.rotation
                r = normalizedRotation(r)
                r += turns * 90
                r = normalizedRotation(r)
                page.rotation = r
            }
        }

        guard let data = doc.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
    }

    /// Writes an encrypted copy that requires `password` to open.
    static func encrypt(inputURL: URL, outputURL: URL, password: String) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try encryptData(inputURL: inputURL, password: password), to: outputURL)
    }

    /// In-memory core of ``encrypt(inputURL:outputURL:password:)``. The same string is set as both
    /// the user password (needed to open) and the owner password (needed to change permissions), so
    /// the document is fully locked behind one password. The input must be an openable, unencrypted
    /// PDF.
    internal static func encryptData(inputURL: URL, password: String) throws -> Data {
        guard !password.isEmpty else { throw PDFOperationError.passwordRequired }
        // A single password locks the whole file: user == owner, no permission bits written (once
        // opened, the reader has full owner access) — byte-for-byte the original single-password lock.
        return try encryptData(
            inputURL: inputURL,
            options: ProtectionOptions(userPassword: password, ownerPassword: password, permissionBits: nil)
        )
    }

    /// In-memory core shared by both protection styles. Always encrypts (an owner password is
    /// required); the user password gates *opening* and is omitted for the restrict-only style so the
    /// file opens freely, while `permissionBits` — when set — records what a reader may still do
    /// without the owner password. The input must be an openable, unencrypted PDF; a locked input
    /// throws `encryptedInput` (via `openUnlockedDocument`), not `incorrectPassword`, since no
    /// password was typed on this path.
    internal static func encryptData(inputURL: URL, options: ProtectionOptions) throws -> Data {
        guard !options.ownerPassword.isEmpty else { throw PDFOperationError.passwordRequired }
        let doc = try openUnlockedDocument(at: inputURL)
        guard doc.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        var writeOptions: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: options.ownerPassword,
        ]
        // Only set a user (open) password when there is one: an empty string here would demand an
        // empty password to open rather than opening freely.
        if !options.userPassword.isEmpty {
            writeOptions[.userPasswordOption] = options.userPassword
        }
        // Access permissions only bite when the file opens without the owner password, which is the
        // restrict-only style. `PDFAccessPermissions` is declared `NS_ENUM`, so the raw bits are
        // combined by the caller and passed as an NSNumber — the shape the write option expects.
        if let bits = options.permissionBits {
            writeOptions[.accessPermissionsOption] = NSNumber(value: bits)
        }
        guard let data = doc.dataRepresentation(options: writeOptions) else {
            throw PDFOperationError.protectionFailed
        }
        return data
    }

    /// Writes a decrypted copy with no password.
    public static func removePassword(inputURL: URL, outputURL: URL, password: String) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try removePasswordData(inputURL: inputURL, password: password), to: outputURL)
    }

    /// In-memory core of ``removePassword(inputURL:outputURL:password:)``. If the source is locked
    /// it is unlocked with `password` first (wrong password → `incorrectPassword`); a source that
    /// isn't encrypted at all throws `notEncrypted` so the tool can say there's nothing to remove.
    internal static func removePasswordData(inputURL: URL, password: String) throws -> Data {
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

        // Serializing the unlocked document directly is NOT enough: PDFKit carries the original
        // encryption into the output, so a just-unlocked doc re-serializes to a file that is
        // still locked with the same password. Rebuild the pages into a fresh document, which
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
        guard output.pageCount > 0, let data = output.dataRepresentation() else {
            throw PDFOperationError.protectionFailed
        }
        return data
    }

    /// Stamps text or a logo image onto the chosen pages and writes a new PDF.
    ///
    /// Each page is copied into a fresh CoreGraphics PDF context with `drawPDFPage`, which keeps the
    /// original page **as vector content** (text stays selectable, graphics stay sharp) rather than
    /// rasterizing it the way compression does. The watermark is then drawn on top — text with
    /// CoreText via an `NSGraphicsContext` bridge, a logo with `CGContext.draw` — so it is baked
    /// into the page content stream, not a strippable annotation. Intrinsic page rotation is
    /// honored: the output page's media box uses the page's *displayed* size and `getDrawingTransform`
    /// maps the source upright before the stamp is added. Visible annotation appearances (form
    /// values, signatures, notes) are drawn after the content so they survive the rebuild —
    /// flattened into the page rather than silently dropped. Pages outside `options.pageScope` are
    /// still emitted unchanged (page count is always preserved); they just receive no mark.
    static func watermark(inputURL: URL, outputURL: URL, options: WatermarkOptions) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try watermarkData(inputURL: inputURL, options: options), to: outputURL)
    }

    /// In-memory core of ``watermark(inputURL:outputURL:options:)`` — the CGPDFContext already
    /// builds the whole result in an `NSMutableData`, so the core simply hands those bytes back.
    internal static func watermarkData(inputURL: URL, options: WatermarkOptions) throws -> Data {
        let trimmed = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate the payload for the chosen mode before touching the document.
        switch options.content {
        case .text:
            guard !trimmed.isEmpty else { throw PDFOperationError.watermarkTextRequired }
        case .image:
            guard options.image != nil else { throw PDFOperationError.watermarkImageRequired }
        }

        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        // Which pages get the mark, resolved against this document's real length (a custom range
        // that overshoots throws `pageOutOfBounds`, exactly like the other range-taking tools).
        let stampPages = try applicableWatermarkPages(options.pageScope, pageCount: source.pageCount)

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.watermarkFailed
        }

        for i in 0..<source.pageCount {
            let dp = try displayedPage(source.page(at: i), inputURL: inputURL)
            emitDisplayedPage(dp, into: ctx) { ctx, dp in
                // Every page is emitted; only the in-scope ones are stamped.
                guard stampPages.contains(i) else { return }
                drawWatermark(in: ctx, box: dp.box, trimmedText: trimmed, options: options)
            }
        }
        ctx.closePDF()

        guard pdfData.length > 0 else { throw PDFOperationError.watermarkFailed }
        return pdfData as Data
    }

    /// Bakes placed text and drawn signatures onto their pages and writes a new PDF.
    ///
    /// Built exactly like ``watermark``: each page is redrawn as **vector** content with
    /// `drawPDFPage` (so the underlying text stays selectable) and its visible annotations are
    /// flattened in (in displayed-page space — PDFKit's annotation draw maps there itself). The
    /// placed items are then drawn *inside the crop-box drawing transform* like the content — so an
    /// item's page-space rectangle (captured from the placement canvas) lands on exactly the pixels
    /// the user saw, honoring page rotation and crop just like redaction fills.
    /// Typed runs are drawn with CoreText (they remain selectable, searchable vector text); drawn
    /// signatures are stroked as vector paths from their normalized polylines — never rasterized.
    static func fillAndSign(inputURL: URL, outputURL: URL, items: [FillSignItem]) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try fillAndSignData(inputURL: inputURL, items: items), to: outputURL)
    }

    /// In-memory core of ``fillAndSign(inputURL:outputURL:items:)`` — like ``watermarkData``, the
    /// CGPDFContext builds the result in memory and the core hands the bytes back.
    internal static func fillAndSignData(inputURL: URL, items: [FillSignItem]) throws -> Data {
        let inked = items.filter(\.hasInk)
        guard !inked.isEmpty else { throw PDFOperationError.noFillSignItems }
        let source = try openUnlockedDocument(at: inputURL)
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
            let dp = try displayedPage(source.page(at: i), inputURL: inputURL)
            emitDisplayedPage(dp, into: ctx) { ctx, dp in
                // Placed items draw on top of the annotations, each in the space that renders it
                // the way the editor previewed it. Signatures are polylines: every point maps
                // through the page transform, so rotation is handled exactly. Typed text is laid
                // out by NSStringDrawing along the current CTM's axes — under the rotated page
                // transform it baked sideways (and wrapped to the unswapped width) on /Rotate
                // pages while the editor showed it upright, so text draws in display space with
                // the display-mapped rect.
                for item in byPage[i] ?? [] {
                    switch item.content {
                    case .text(let text):
                        drawFillText(text, in: displayRect(item.rect, cropBox: dp.cropBox, rotation: dp.rotation), ctx: ctx)
                    case .signature(let signature):
                        ctx.saveGState()
                        ctx.concatenate(dp.transform)
                        drawFillSignature(signature, in: item.rect, ctx: ctx)
                        ctx.restoreGState()
                    }
                }
            }
        }
        ctx.closePDF()

        guard pdfData.length > 0 else { throw PDFOperationError.fillSignFailed }
        return pdfData as Data
    }

    /// Maps a PDF-user-space rect into displayed-page coordinates (origin at the displayed crop
    /// box's corner, /Rotate applied, width/height swapped for 90°/270°) — the space the on-screen
    /// editor and `PDFAnnotation.draw` work in. Internal so geometry tests can pin the mapping.
    static func displayRect(_ rect: CGRect, cropBox: CGRect, rotation: Int) -> CGRect {
        let r = normalizedRotation(rotation)
        switch r {
        case 90:
            return CGRect(
                x: rect.minY - cropBox.minY,
                y: cropBox.maxX - rect.maxX,
                width: rect.height, height: rect.width
            )
        case 180:
            return CGRect(
                x: cropBox.maxX - rect.maxX,
                y: cropBox.maxY - rect.maxY,
                width: rect.width, height: rect.height
            )
        case 270:
            return CGRect(
                x: cropBox.maxY - rect.maxY,
                y: rect.minX - cropBox.minX,
                width: rect.height, height: rect.width
            )
        default:
            return CGRect(
                x: rect.minX - cropBox.minX,
                y: rect.minY - cropBox.minY,
                width: rect.width, height: rect.height
            )
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
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try redactData(inputURL: inputURL, marks: marks, options: options), to: outputURL)
    }

    /// In-memory core of ``redact(inputURL:outputURL:marks:options:)``.
    internal static func redactData(
        inputURL: URL,
        marks: [RedactionMark],
        options: PDFRedactionExportOptions = .default
    ) throws -> Data {
        guard !marks.isEmpty else { throw PDFOperationError.noRedactions }
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let grouped = Dictionary(grouping: marks, by: \.pageIndex)
        for key in grouped.keys {
            guard key >= 0, key < source.pageCount else {
                throw PDFOperationError.pageOutOfBounds(key + 1)
            }
        }

        let output = PDFDocument()
        for pageIndex in 0..<source.pageCount {
            // Per-page pool: redaction renders at up to `maxPixelDimension` (4000 px default,
            // ~150 MB of transient bitmap per US Letter page) — that scratch must drain per page,
            // not accumulate for the whole document. The inserted page survives; output owns it.
            try autoreleasepool {
                guard let page = source.page(at: pageIndex) else { return }
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
                    // A marked page is rasterized even when every fill clips away against the crop box
                    // (a mark dragged wholly into a cropped-out margin): rasterization destroys the
                    // out-of-crop content the mark covered, which is the safe direction — the old
                    // "empty fills → fail the whole export" behavior aborted with no hint which mark
                    // was the problem, and copying the page as vector would keep recoverable content.
                    let fills = mergeOverlappingRedactions(rectsForPage, pageBox: geometry.pageBox)
                    guard
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
        }

        guard output.pageCount > 0 else { throw PDFOperationError.redactionFailed }
        // Do not pass `saveTextFromOCROption`: PDFKit’s OCR-on-save pass re-encodes image-based pages and
        // reliably produced thumbnail-sized redacted pages in testing (even with screen-optimize off).
        guard let data = output.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
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
    // Internal (not private): the shared raster helpers that return/consume it are used by the
    // Compress core in a sibling file, which reads `displaySize` off the geometry.
    struct PageRasterGeometry {
        let pageBox: CGRect
        let displaySize: CGSize
        let scale: CGFloat
        var pixelWidth: Int { max(1, Int(ceil(displaySize.width * scale))) }
        var pixelHeight: Int { max(1, Int(ceil(displaySize.height * scale))) }
    }

    // Internal (not private): the raster pipeline is shared by redaction and the Compress core in a
    // sibling file (PDFToolkit+Compress.swift), which rebuilds pages through the same rasterizer.
    static func rasterGeometry(
        for page: PDFPage,
        maxPixelDimension: CGFloat,
        allowUpscale: Bool
    ) -> PageRasterGeometry? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0, page.pageRef != nil else { return nil }
        let displaySize = displayedSize(of: box, rotation: page.rotation)
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
    // Internal (not private): shared with the Compress core in PDFToolkit+Compress.swift (same raster path).
    static func renderBitmap(
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

        ctx.saveGState()
        ctx.concatenate(transform)
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()

        // Scale-only state: `PDFAnnotation.draw(with:in:)` maps into *displayed-page* coordinates
        // itself — it applies the page's rotation and subtracts the crop origin — so it must not
        // run under the page transform above. Composing both shifted annotations by the crop
        // origin on cropped pages and rotated them twice on rotated pages.
        drawAnnotations(of: page, in: ctx)

        // Redaction rects are in PDF user space, so the fills do need the page transform. Painting
        // after the annotations keeps a marked annotation buried under black.
        ctx.concatenate(transform)
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
    /// them unless they are drawn here. The context must be in *displayed-page* space (origin at the
    /// displayed crop box's corner, rotation already upright): PDFKit's draw performs the page's
    /// display mapping internally.
    // Internal (not private): the OCR extension re-draws pages the same way watermark does.
    static func drawAnnotations(of page: PDFPage, in ctx: CGContext) {
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
    /// Internal for the OCR extension: the page as displayed (rotation and crop applied), upscaled
    /// when the page is small so Vision has pixels to read. Compression's raster path deliberately
    /// never upscales; recognition wants the opposite.
    static func renderPageBitmap(_ page: PDFPage, maxPixelDimension: CGFloat) -> CGImage? {
        guard
            let cgPage = page.pageRef,
            let geometry = rasterGeometry(for: page, maxPixelDimension: maxPixelDimension, allowUpscale: true)
        else { return nil }
        return renderBitmap(page, cgPage: cgPage, geometry: geometry, redactionFills: [])
    }
}
