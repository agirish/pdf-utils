import Foundation

enum PageRangeParser {
    /// Parses "1, 3-5, 8" into zero-based indices.
    /// When `emptyMeansAllPages` is true, blank input selects every page (used by Extract / Rotate “all” semantics).
    /// When false, blank input throws `pageRangeRequired` (used by Delete so an empty field cannot mean “delete everything”).
    static func parse(_ text: String, pageCount: Int, emptyMeansAllPages: Bool = true) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            guard emptyMeansAllPages else {
                throw PDFOperationError.pageRangeRequired
            }
            return Array(0..<pageCount)
        }

        var indices = Set<Int>()
        let parts = trimmed.split(separator: ",")

        for part in parts {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }

            if p.contains("-") {
                let rangeParts = p.split(separator: "-", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard rangeParts.count == 2,
                    let startOneBased = Int(rangeParts[0]),
                    let endOneBased = Int(rangeParts[1])
                else {
                    throw PDFOperationError.invalidPageRange(p)
                }
                let lo = min(startOneBased, endOneBased)
                let hi = max(startOneBased, endOneBased)
                for oneBased in lo...hi {
                    let zero = oneBased - 1
                    guard (0..<pageCount).contains(zero) else {
                        throw PDFOperationError.pageOutOfBounds(oneBased)
                    }
                    indices.insert(zero)
                }
            } else if let oneBased = Int(p) {
                let zero = oneBased - 1
                guard (0..<pageCount).contains(zero) else {
                    throw PDFOperationError.pageOutOfBounds(oneBased)
                }
                indices.insert(zero)
            } else {
                throw PDFOperationError.invalidPageRange(p)
            }
        }

        guard !indices.isEmpty else {
            throw PDFOperationError.invalidPageRange(trimmed)
        }

        return indices.sorted()
    }
}
