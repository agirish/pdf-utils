import Foundation

/// Rich help text for the per-tool help sheet (overview, steps, control glossary, tips).
struct ToolHelpContent {
    let overview: String
    let steps: [String]
    /// (Control name, explanation)
    let controls: [(String, String)]
    let tips: [String]
}

extension Tool {
    var helpContent: ToolHelpContent {
        switch self {
        case .compress:
            return ToolHelpContent(
                overview:
                    "Compression redraws each page to a bitmap and wraps it in a new PDF. That usually shrinks scan- and photo-heavy documents. Pure text PDFs may not get much smaller.",
                steps: [
                    "Click Choose… and pick a PDF (you can use files from iCloud Drive, Desktop, etc.).",
                    "Adjust Quality—lower tends toward smaller files; higher keeps more detail.",
                    "Click Compress & save…. When the save sheet appears, pick a name and folder for the new PDF.",
                ],
                controls: [
                    ("Choose…", "Opens the system file picker. macOS grants one-time access to the file you select."),
                    ("Quality", "Balances resolution (max pixel size per page) against file size."),
                    ("Compress & save…", "Runs compression off the main thread, then opens the export sheet."),
                ],
                tips: [
                    "Original file is not modified until you deliberately save over it.",
                    "If the save panel fails, check that the destination folder allows writing.",
                ]
            )
        case .rotate:
            return ToolHelpContent(
                overview:
                    "Rotation changes how pages are stored in the output PDF (0°, 90°, 180°, 270°). You can rotate all pages or only a subset using the same page-number rules as other tools.",
                steps: [
                    "Choose a PDF with Choose….",
                    "Pick All pages or Page range and, if needed, type pages like 1, 3-5 (1-based, comma-separated).",
                    "Choose 90°, 180°, or 270° clockwise.",
                    "Click Rotate & save… and save the new PDF.",
                ],
                controls: [
                    ("Pages", "All pages applies to every sheet; Page range uses the text field."),
                    ("Page range field", "Empty with “All pages” is ignored. With Page range, list pages using commas and ranges."),
                    ("Rotation", "Each selected page is turned by the chosen amount; other pages are unchanged."),
                ],
                tips: [
                    "Range parsing treats lists as a set of unique pages for rotation (order does not matter).",
                ]
            )
        case .merge:
            return ToolHelpContent(
                overview:
                    "Merge concatenates whole PDFs in list order: first file’s pages, then the second’s, and so on. The same file can appear twice if you add it twice.",
                steps: [
                    "Click Add PDFs… and select one or more PDFs (⌘-click for multiple), or drag PDFs from Finder onto the dashed area or list.",
                    "Reorder by dragging rows in the list or with the chevron buttons; Delete removes the selected row; trash removes that file from the merge list only.",
                    "Watch the preview column on the right: it shows every page in merge order; use the slider to change thumbnail size.",
                    "Click Merge & save…, choose a path in the save panel, then use Start over on the success screen to merge again.",
                ],
                controls: [
                    ("Add PDFs…", "Appends chosen PDFs to the list. Order is top to bottom in the merged file."),
                    ("Clear all", "Empties the list and clears the preview."),
                    ("↑ / ↓", "Swaps the row with its neighbor—handy for fixing order without re-importing."),
                    ("Trash", "Removes that entry from the list; it does not delete the file from disk."),
                    ("Preview slider", "Resizes page thumbnails in the right-hand preview."),
                    ("Merge & save…", "Opens the save panel, then writes one combined PDF from every listed file."),
                ],
                tips: [
                    "Large merges can take a moment; the window should stay responsive while working.",
                ]
            )
        case .extract:
            return ToolHelpContent(
                overview:
                    "Extract copies the pages you list into a brand-new PDF. Order is preserved: 3,1 puts page 3 first, then page 1. Ranges expand in order (3-5 → 3,4,5; 5-3 → 5,4,3).",
                steps: [
                    "Choose a source PDF.",
                    "Edit the Pages to extract field, or leave it blank to take all pages.",
                    "Click Extract & save… and save the new file.",
                ],
                controls: [
                    ("Pages to extract", "1-based numbers, commas, and inclusive ranges. Blank means all pages."),
                    ("Extract & save…", "Builds a new PDF containing only the listed pages, in that order."),
                ],
                tips: [
                    "You can list the same page more than once if you need duplicates in the output.",
                ]
            )
        case .deletePages:
            return ToolHelpContent(
                overview:
                    "Delete pages writes a new PDF that omits the pages you specify. You must type which pages to remove; an empty field shows an error instead of deleting everything.",
                steps: [
                    "Choose the PDF to edit.",
                    "Enter pages to remove (e.g. 2 or 1, 4-6) using 1-based numbers.",
                    "Click Delete pages & save…. You cannot remove every page—one sheet must remain.",
                ],
                controls: [
                    ("Pages to remove", "Required. Uses the same range syntax as other tools, but blank input is not allowed."),
                    ("Delete pages & save…", "Produces a copy without those pages; the original file is unchanged on disk."),
                ],
                tips: [
                    "If nothing seems to happen, confirm macOS allowed access to the file (try choosing it again).",
                ]
            )
        case .redact:
            return ToolHelpContent(
                overview:
                    "Redaction permanently destroys content inside rectangles you draw: those page regions are rebuilt as images with solid black fills, so text and graphics there cannot be copied or searched in the export. Your original file is not changed until you save over it.",
                steps: [
                    "Choose or drop a PDF.",
                    "Hold ⇧ Shift, then drag on the preview to draw each redaction rectangle (stay on one page per drag).",
                    "Review the region list on the left; remove mistakes with the trash button or Clear all.",
                    "Optional: enable removing annotations from pages you did not redact to avoid leaking hidden comments.",
                    "Click Redact & save… and pick a new filename for the sanitized PDF.",
                ],
                controls: [
                    ("⇧ Shift-drag", "Required modifier so normal scrolling and selection still work. Each drag must begin and end on the same page."),
                    ("Regions list", "Lists page numbers for each mark. Delete individual marks or use Clear all."),
                    ("Remove highlights & notes from other pages", "Strips all PDF annotations from pages that were not rasterized—stronger hygiene for sharing."),
                    ("Redact & save…", "Builds a new PDF on disk; work stays on your Mac."),
                ],
                tips: [
                    "Like browser tools such as Smallpdf’s redactor, redaction is irreversible—double-check marks before exporting.",
                    "Very small rectangles may be ignored; drag a box at least a few points on each side.",
                ]
            )
        }
    }
}
