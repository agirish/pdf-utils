import Foundation

enum PDFOperationError: LocalizedError {
    case couldNotOpen(URL)
    case couldNotWrite(URL)
    case invalidPageRange(String)
    case pageOutOfBounds(Int)
    case noInputFiles
    case noPagesSelected
    case compressionFailed

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
        case .noInputFiles:
            return "Choose at least one PDF file."
        case .noPagesSelected:
            return "Select at least one page."
        case .compressionFailed:
            return "Compression failed while rebuilding the PDF."
        }
    }
}
