import Foundation

enum PageRangeParser {
    /// Parses "1, 3-5, 8" into zero-based indices. Empty input means all pages.
    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
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
