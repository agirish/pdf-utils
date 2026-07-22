import Foundation

/// Live, best-effort validation of a page-range text field, surfaced inline under the field so a bad
/// range shows up *before* the save dialog instead of after it — Extract and Delete previously only
/// reported a bad range once you'd already picked a save location. It runs exactly the parse the
/// tool's export runs (through ``PageRangeParser``), so the inline verdict can never disagree with
/// what Save would actually do.
enum PageRangeField {
    enum Outcome: Equatable {
        /// The field is blank. Each tool decides what blank means (Extract exports every page; Delete
        /// removes nothing), so the caller supplies the wording.
        case empty
        /// A half-finished token like `"1-"` — the user is mid-type. Nothing is shown rather than
        /// flashing an error at a range that isn't done being typed.
        case incomplete
        /// Parsed cleanly. `indices` are the zero-based pages the export would act on, in export order
        /// (so the caller can report a count, and Extract's duplicates/reordering survive).
        case pages([Int])
        /// The text can't be parsed against this document; `message` is the reason to show inline.
        case invalid(String)
    }

    /// - Parameter preserveOrder: mirror the tool's export parse — Extract keeps order and allows
    ///   duplicates (`true`), Delete collapses to a unique sorted set (`false`).
    static func evaluate(_ text: String, pageCount: Int, preserveOrder: Bool) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        // A trailing hyphen is an unfinished range like "3-": don't nag until the second bound lands.
        // Other incomplete states (a too-big number typed digit by digit) are rarer and still resolve
        // to a genuinely helpful "not in this document" message.
        if trimmed.hasSuffix("-") { return .incomplete }
        // No document yet (or an empty one): nothing to validate against, so stay quiet.
        guard pageCount > 0 else { return .incomplete }
        do {
            let indices = try PageRangeParser.parse(
                trimmed,
                pageCount: pageCount,
                emptyMeansAllPages: false,
                preserveOrder: preserveOrder
            )
            return .pages(indices)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }
}
