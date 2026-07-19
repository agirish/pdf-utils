import Foundation

/// Bridges the visual thumbnail selection (a set of 1-based page numbers) and the text range field
/// that Split ("Custom ranges") and Extract already expose. The text field stays authoritative for
/// power-user input — custom order like `5,1,2`, reversed ranges, overlaps — none of which an
/// unordered set can represent; this helper only powers the click-to-select convenience layer, so it
/// is deliberately best-effort and never throws.
enum VisualPageSelection {
    /// A compact, 1-based, ascending range string with consecutive pages collapsed into runs:
    /// `{1,2,3,5,9,10}` → `"1-3, 5, 9-10"`. This is what a thumbnail click writes back into the
    /// field, so clicking canonicalizes the text (the documented tradeoff of the visual layer).
    /// For Split each run is a separate output file; adjacent-but-distinct files (`1-3 | 4-6`) can't
    /// be expressed by clicking and remain a text-field-only capability.
    static func rangeString(from pages: Set<Int>) -> String {
        let sorted = pages.filter { $0 >= 1 }.sorted()
        guard let first = sorted.first else { return "" }

        var runs: [String] = []
        var runStart = first
        var previous = first
        for page in sorted.dropFirst() {
            if page == previous + 1 {
                previous = page
            } else {
                runs.append(runStart == previous ? "\(runStart)" : "\(runStart)-\(previous)")
                runStart = page
                previous = page
            }
        }
        runs.append(runStart == previous ? "\(runStart)" : "\(runStart)-\(previous)")
        return runs.joined(separator: ", ")
    }

    /// The 1-based pages a range string covers, for highlighting the current text on the thumbnails.
    /// Reuses `PageRangeParser` (so it matches exactly what an export would select) but swallows every
    /// error: while the user is mid-type (`"1-"`) or has typed something invalid, nothing is
    /// highlighted rather than the field fighting back. Pages outside `1...pageCount` are dropped.
    static func pages(from text: String, pageCount: Int) -> Set<Int> {
        guard pageCount > 0,
              let indices = try? PageRangeParser.parse(text, pageCount: pageCount, emptyMeansAllPages: false) else {
            return []
        }
        return Set(indices.map { $0 + 1 })
    }
}
