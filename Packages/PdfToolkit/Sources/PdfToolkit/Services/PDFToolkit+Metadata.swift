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

    /// Fields whose presence identifies a person or their tools — what the tool's summary counts.
    var identifyingFieldCount: Int {
        var count = [author, creator, producer].filter { !$0.trimmed.isEmpty }.count
        if creationDate != nil { count += 1 }
        if modificationDate != nil { count += 1 }
        return count
    }

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

        doc.documentAttributes = attrs
        guard doc.write(to: outputURL) else {
            throw PDFOperationError.couldNotWrite(outputURL)
        }
    }
}
