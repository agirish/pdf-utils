import CoreGraphics
import Foundation
import PDFKit

/// The document-info fields of a PDF, held as plain values so they can cross the PDF serial queue
/// (`PDFDocument` itself is not `Sendable`). Blank strings mean "no value" — the write path omits
/// them from the info dictionary entirely rather than writing empty strings.
///
/// Only the first five fields are *writable*. PDFKit unconditionally stamps its own Producer
/// ("macOS … Quartz PDFContext") and fresh Creation/Modification dates on every `write(to:)` —
/// explicit values for those three are silently ignored (verified empirically on macOS 26). They
/// are carried here read-only so the tool can show what the file currently says.
struct PDFMetadataFields: Equatable, Sendable {
    var title = ""
    var author = ""
    var subject = ""
    /// Comma-separated for display and editing; written back to the PDF as an array.
    var keywords = ""
    var creator = ""
    /// Read-only: replaced by PDFKit's own producer string on every save.
    var producer = ""
    /// Read-only: reset by PDFKit to the save time on every save.
    var creationDate: Date?
    /// Read-only: reset by PDFKit to the save time on every save.
    var modificationDate: Date?

    /// True when every *editable* field is blank — the fully stripped state. Producer and dates
    /// don't count: PDFKit re-stamps them with neutral system values on save regardless.
    var isCleared: Bool {
        [title, author, subject, keywords, creator].allSatisfy { $0.trimmed.isEmpty }
    }

    /// All editable fields blanked.
    static let cleared = PDFMetadataFields()
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension PDFToolkit {
    /// Reads the standard info-dictionary fields of a PDF into plain values.
    ///
    /// Encrypted/locked documents are refused outright rather than shown blank: PDFKit hides
    /// attributes behind the password, and rewriting such a file would drop its encryption — the
    /// Protect tool is the right place to deal with the password first.
    static func readMetadata(inputURL: URL) throws -> PDFMetadataFields {
        guard let doc = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        guard !doc.isEncrypted, !doc.isLocked else {
            throw PDFOperationError.metadataEncrypted
        }
        let attrs = doc.documentAttributes ?? [:]

        var fields = PDFMetadataFields()
        fields.title = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        fields.author = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""
        fields.subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        fields.creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String ?? ""
        fields.producer = attrs[PDFDocumentAttribute.producerAttribute] as? String ?? ""
        fields.creationDate = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date
        fields.modificationDate = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date
        // Keywords come back as an array from most producers but as a single string from some;
        // normalize both to the comma-joined editing representation.
        switch attrs[PDFDocumentAttribute.keywordsAttribute] {
        case let list as [String]:
            fields.keywords = list.joined(separator: ", ")
        case let single as String:
            fields.keywords = single
        default:
            break
        }
        return fields
    }

    /// Writes a copy of the PDF whose *editable* info fields (title, author, subject, keywords,
    /// creator) contain exactly `fields` — blank fields are omitted, so ``PDFMetadataFields/cleared``
    /// produces a file carrying none of them. Page content, annotations, and everything else ride
    /// along unchanged.
    ///
    /// Producer and both dates are NOT written: PDFKit stamps its own neutral values on save and
    /// ignores explicit ones. The original tool name and timestamps still don't survive into the
    /// output, which is the privacy outcome the tool promises.
    static func writeMetadata(inputURL: URL, outputURL: URL, fields: PDFMetadataFields) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try writeMetadataData(inputURL: inputURL, fields: fields), to: outputURL)
    }

    /// In-memory core of ``writeMetadata(inputURL:outputURL:fields:)``.
    internal static func writeMetadataData(inputURL: URL, fields: PDFMetadataFields) throws -> Data {
        guard let doc = PDFDocument(url: inputURL) else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        guard !doc.isEncrypted, !doc.isLocked else {
            throw PDFOperationError.metadataEncrypted
        }

        var attrs: [AnyHashable: Any] = [:]
        func put(_ key: PDFDocumentAttribute, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { attrs[key] = v }
        }
        put(.titleAttribute, fields.title)
        put(.authorAttribute, fields.author)
        put(.subjectAttribute, fields.subject)
        put(.creatorAttribute, fields.creator)
        let keywordList = fields.keywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !keywordList.isEmpty { attrs[PDFDocumentAttribute.keywordsAttribute] = keywordList }

        // Clearing `documentAttributes` only rewrites the Info dictionary — PDFKit copies the catalog's
        // XMP `/Metadata` packet (author/title/creator that Adobe/Office duplicate there) verbatim, so
        // the source's identity would still leak. Rebuilding into a fresh document is the only way to
        // shed that packet; skip it when the doc carries a real form (the rebuild would flatten it).
        if !hasInteractiveForm(doc), let rebuilt = dataStrippingHiddenMetadata(from: doc, applying: attrs) {
            return rebuilt
        }
        doc.documentAttributes = attrs
        guard let data = doc.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
    }

    /// True when the document carries a catalog `/AcroForm` (a real interactive form). A page-by-page
    /// rebuild drops the catalog, orphaning the form's fields into non-fillable widgets, so the
    /// metadata-cleaning rebuild is skipped for these files. Reads the CoreGraphics catalog directly —
    /// PDFKit exposes no form accessor.
    static func hasInteractiveForm(_ doc: PDFDocument) -> Bool {
        guard let catalog = doc.documentRef?.catalog else { return false }
        var acroForm: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm)
    }

    /// Returns `doc`'s bytes with all hidden metadata gone: the Info dictionary set to `attributes`
    /// (empty = fully stripped) AND the catalog XMP `/Metadata` packet dropped — which a plain
    /// `documentAttributes` write leaves behind. Achieved by rebuilding into a fresh `PDFDocument`
    /// (the only way to shed the catalog XMP, since PDFKit can't delete `/Metadata` in place). The
    /// source outline is reattached so bookmarks — which live on the catalog, not the pages — survive
    /// the rebuild; PDFKit remaps their destinations onto the copied pages on write.
    ///
    /// The caller must have ruled out encrypted/locked docs (a rebuild breaks encryption) and forms
    /// (see ``hasInteractiveForm(_:)``). Returns nil on page-copy or encode failure so the caller can
    /// fall back to an in-place attribute write.
    static func dataStrippingHiddenMetadata(from doc: PDFDocument, applying attributes: [AnyHashable: Any]) -> Data? {
        let clean = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let copy = doc.page(at: i)?.copy() as? PDFPage else { return nil }
            clean.insert(copy, at: clean.pageCount)
        }
        if let outline = doc.outlineRoot {
            clean.outlineRoot = outline
        }
        clean.documentAttributes = attributes
        return clean.dataRepresentation()
    }
}
