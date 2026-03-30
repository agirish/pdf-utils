import Foundation

enum PDFOperationError: LocalizedError {
    case couldNotOpen(URL)
    case couldNotWrite(URL)
    case invalidPageRange(String)
    case pageOutOfBounds(Int)
    case pageRangeRequired
    case cannotRemoveEveryPage
    case fileAccessDenied(URL)
    case noInputFiles
    case noPagesSelected
    case compressionFailed
    case emptyPDF
    case noRedactions
    case redactionFailed

    var errorDescription: String? {
        switch self {
        case .couldNotOpen(let url):
            return "Could not open PDF: \(url.lastPathComponent)"
        case .couldNotWrite(let url):
            return "Could not save to: \(url.lastPathComponent)"
        case .invalidPageRange(let s):
            return "Invalid page range: \(s)"
        case .pageOutOfBounds(let n):
            return "Page \(n) is not in this document."
        case .pageRangeRequired:
            return "Enter at least one page number (for example 1 or 2-5)."
        case .cannotRemoveEveryPage:
            return "You cannot remove every page from a PDF. Leave at least one page."
        case .fileAccessDenied(let url):
            return "Could not access “\(url.lastPathComponent)”. Try choosing the file again."
        case .noInputFiles:
            return "Choose at least one PDF file."
        case .noPagesSelected:
            return "Select at least one page."
        case .compressionFailed:
            return "Compression failed while rebuilding the PDF."
        case .emptyPDF:
            return "This PDF has no pages."
        case .noRedactions:
            return "Draw at least one redaction rectangle on a page before saving."
        case .redactionFailed:
            return "Redaction failed while rebuilding the PDF."
        }
    }
}
