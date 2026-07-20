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
        case .metadata:
            return ToolHelpContent(
                overview:
                    "Every PDF carries an info dictionary—title, author, subject, keywords, the app that created it, and dates. This tool shows those fields, lets you edit or clear each one, and writes the result to a new file. Page content is never modified.",
                steps: [
                    "Choose or drop a PDF. Its info fields load into the form.",
                    "Edit any field directly, or click Strip All Fields to blank everything at once.",
                    "Click Clean & save… and choose where the cleaned copy goes.",
                ],
                controls: [
                    ("Info fields", "Title, Author, Subject, Keywords, and Creator app as stored in the file. Blank fields are omitted from the saved copy entirely."),
                    ("Strip All Fields", "Blanks every editable field—one click to a fully clean file."),
                    ("Reset", "Restores the form to what the file actually contains, undoing your edits."),
                    ("Producer / Created / Modified", "Shown for reference. macOS replaces all three when you save: the Producer becomes the system PDF writer and both dates reset to the save time, so the originals never travel with the cleaned file."),
                    ("Clean & save…", "Writes a new PDF whose info fields are exactly what the form shows."),
                ],
                tips: [
                    "Password-protected PDFs can’t be edited here—remove the password with Password Protect first.",
                    "Some PDFs carry extra XMP metadata that macOS doesn’t expose; the standard info fields shown here are what Finder and most viewers read.",
                    "The summary line under the form tells you when the file still names an author or creator app.",
                ]
            )
        case .crop:
            return ToolHelpContent(
                overview:
                    "Crop tightens what viewers display of each page—the crop box—without deleting anything. Auto-detect renders each page and finds where the content actually is; custom margins trim fixed amounts you type. Either way a new PDF is written and the original stays put.",
                steps: [
                    "Choose or drop a PDF.",
                    "Pick Auto-detect and set how much breathing room to keep around the content, or pick Custom margins and type a trim for each edge.",
                    "With Auto-detect, decide whether every page should share one uniform crop (steady frame) or be trimmed to its own content.",
                    "Click Crop & save… and save the new PDF.",
                ],
                controls: [
                    ("Auto-detect", "Renders each page and trims to the darkest-pixel bounds of its content, plus your breathing room."),
                    ("Breathing room", "Points of margin kept around the detected content (72 pt = 1 inch)."),
                    ("Use the same crop on every page", "Applies the smallest per-edge trim that is safe on every page, so all pages keep one size—best for book scans."),
                    ("Custom margins", "Trims exactly what you type from the top, left, bottom, and right of every page, measured as displayed."),
                    ("Crop & save…", "Writes a new PDF with the tightened crop boxes."),
                ],
                tips: [
                    "Cropping is non-destructive: the content outside the crop box is hidden, not deleted, and another PDF editor can crop back out.",
                    "A trim that would leave less than about a third of an inch of page is refused rather than producing a sliver.",
                    "Blank pages are left alone by Auto-detect—there is nothing to crop to.",
                ]
            )
        case .imagesToPdf:
            return ToolHelpContent(
                overview:
                    "Images to PDF combines pictures into one document, a page per image, in list order. iPhone photos, screenshots, and scans all work—orientation is read from the file, so sideways shots come out upright.",
                steps: [
                    "Click Add Images… and pick one or more images (⌘-click for several), or drag them from Finder onto the dashed area.",
                    "Reorder with the chevron buttons; the trash button removes a row without touching the file on disk.",
                    "Pick a page size: Auto gives every page its image’s exact shape; A4 and US Letter are fixed paper sizes.",
                    "On a fixed size, choose Fit (whole image visible) or Fill (edge to edge, cropped).",
                    "Click Combine & save… and choose where the PDF goes.",
                ],
                controls: [
                    ("Add Images…", "Appends chosen images to the list. Order is top to bottom in the PDF."),
                    ("↑ / ↓", "Swaps the row with its neighbor—fix order without re-importing."),
                    ("Page size", "Auto (match image) makes each page exactly its image’s size. A4 and US Letter flip to landscape automatically for landscape images."),
                    ("Fit / Fill", "Fit letterboxes the whole image onto the page; Fill covers the page completely and crops the overflow."),
                    ("Combine & save…", "Builds the PDF off the main thread, then opens the save panel."),
                ],
                tips: [
                    "Big photos make big PDFs—run the result through Compress if it needs to be emailed.",
                    "The same image can appear twice: add it twice and it becomes two pages.",
                ]
            )
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
        case .split:
            return ToolHelpContent(
                overview:
                    "Split cuts one PDF into several separate files. Use fixed chunks of N pages for even slices, or list custom page ranges when each section is a different length. Every part is a full PDF; the original is left as-is.",
                steps: [
                    "Choose or drop a PDF.",
                    "Pick “Every N pages” and set the chunk size, or pick “Custom ranges” and list groups like 1-3, 4-6, 7-10.",
                    "Click Split & save… and choose a destination folder.",
                    "Use Show in Finder on the success screen to reveal the new files.",
                ],
                controls: [
                    ("Every N pages", "Cuts the document into consecutive chunks of that many pages; the last file takes the remainder."),
                    ("Custom ranges", "Each comma-separated group becomes one file (1-3 → a 3-page file). 1-based, inclusive ranges."),
                    ("Split & save…", "Writes each part into the folder you choose as name-01.pdf, name-02.pdf, …"),
                ],
                tips: [
                    "The live count under the options shows how many files the current settings will produce.",
                    "A part whose name is already taken in the chosen folder is numbered (\u{201C}name 2.pdf\u{201D}) — existing files are never overwritten.",
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
        case .reorder:
            return ToolHelpContent(
                overview:
                    "Reorder Pages lists every page of a PDF so you can rearrange them and save the result as a new file. The preview on the right always reflects the current arrangement, labeled with each page's original number.",
                steps: [
                    "Choose or drop a PDF; its pages load as a draggable list.",
                    "Drag rows into the order you want, or nudge a row with its ↑ / ↓ buttons.",
                    "Watch the preview reflow into the new order; use Reset to restore the original.",
                    "Click Save reordered PDF… and pick a name for the new file.",
                ],
                controls: [
                    ("Page list", "One row per page. The leading number is the new position; “Page N” is where it came from."),
                    ("↑ / ↓", "Moves a row up or down by one without dragging."),
                    ("Reset", "Restores the original page order. Appears once you've moved something."),
                    ("Save reordered PDF…", "Writes a new PDF whose pages follow the list order; the original file is unchanged."),
                ],
                tips: [
                    "Saving without changing anything just copies the document in its original order.",
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
        case .watermark:
            return ToolHelpContent(
                overview:
                    "Watermark stamps text across every page and bakes it into a new PDF. The underlying page is copied as vector content, so its text stays selectable; the watermark itself becomes part of the page, not a removable annotation.",
                steps: [
                    "Choose or drop a PDF.",
                    "Type the watermark text (DRAFT, CONFIDENTIAL, a name, …).",
                    "Pick a color and choose Centered or Tiled, then tune Size, Opacity, and Angle — the small preview updates as you go.",
                    "Click Watermark & save… and pick a name for the new file.",
                ],
                controls: [
                    ("Watermark text", "The string stamped on every page. Required."),
                    ("Color", "One of four ink colors for the stamp."),
                    ("Centered / Tiled", "Centered draws the text once in the middle; Tiled repeats it across the whole page."),
                    ("Size / Opacity / Angle", "Point size, fill strength (5–100%), and rotation (−90° to 90°) of the text."),
                    ("Watermark & save…", "Builds a new PDF with the stamp baked in; the original file is unchanged."),
                ],
                tips: [
                    "A subtle watermark usually reads best at 15–30% opacity and 45°.",
                    "Interactive form fields and link annotations are not carried into the watermarked copy, since each page is redrawn from its content.",
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
                    "Optional: raise Redacted page sharpness for crisper bitmap pages on the pages you marked.",
                    "Optional: enable removing annotations from pages you did not redact to avoid leaking hidden comments.",
                    "Click Redact & save… and pick a new filename for the sanitized PDF.",
                ],
                controls: [
                    ("⇧ Shift-drag", "Required modifier so normal scrolling and selection still work. Each drag must begin and end on the same page."),
                    ("Regions list", "Lists page numbers for each mark. Delete individual marks or use Clear all."),
                    ("Redacted page sharpness", "More pixels on the longest edge when rasterizing only the pages you marked—helps text stay readable after export."),
                    ("Remove highlights & notes from other pages", "Strips all PDF annotations from pages that were not rasterized—stronger hygiene for sharing."),
                    ("Redact & save…", "Builds a new PDF on disk; work stays on your Mac."),
                ],
                tips: [
                    "Like browser tools such as Smallpdf’s redactor, redaction is irreversible—double-check marks before exporting.",
                    "Very small rectangles may be ignored; drag a box at least a few points on each side.",
                    "Redacted pages are saved as full-page images. PDFKit’s OCR-on-save option is not used here because it re-encoded those pages as tiny thumbnails in testing.",
                ]
            )
        case .fillSign:
            return ToolHelpContent(
                overview:
                    "Fill & Sign lets you type into a flat (non-interactive) PDF form and add a signature. Typed text is baked in as selectable vector text; a signature you draw with the trackpad—or type in a script font—is baked in as vector ink. The original file is not changed until you save the new PDF.",
                steps: [
                    "Choose or drop a PDF, then scroll to the page you want to work on.",
                    "Click Add text to drop a text box on that page, then type into the Selected item field; drag the box to position it and drag its bottom-right handle to resize.",
                    "Use Add date for a one-tap dated stamp.",
                    "To sign: under Signature draw on the pad with the trackpad (or switch to Type and enter a name in a script font), then click Place signature to drop it on the page.",
                    "Reposition and resize items on the page, then click Fill & Sign & save… to write the new PDF.",
                ],
                controls: [
                    ("Ink color", "The color used for new text and signatures you place."),
                    ("Add text / Add date", "Drops a new text box on the current page—empty, or prefilled with today's date."),
                    ("Selected item", "Edit the highlighted item: its text, font size, or delete it. Signatures show a size note only."),
                    ("Signature · Draw / Type", "Draw a freehand signature on the pad, or type a name rendered in a handwriting font."),
                    ("Place signature", "Drops the drawn or typed signature onto the current page so you can position it."),
                    ("Drag / corner handle", "Drag an item to move it; drag its bottom-right handle to resize. Signatures scale with the box."),
                    ("Fill & Sign & save…", "Bakes every placed item into a new PDF; the original file is unchanged."),
                ],
                tips: [
                    "Text stays selectable and searchable in the export—only the signature is drawn ink.",
                    "Items live on the page they were added to; scroll and add to any page before saving.",
                    "Existing interactive AcroForm fields aren't detected here—this tool is for typing onto flat forms and layering a signature on top.",
                ]
            )
        case .protect:
            return ToolHelpContent(
                overview:
                    "Password Protect encrypts a PDF so it can only be opened with a password you set, or removes a password from a PDF you can already open. Everything runs on your Mac and the password is never sent anywhere.",
                steps: [
                    "Choose or drop a PDF.",
                    "Pick Add password or Remove password.",
                    "For Add password, type the password twice so they match; for Remove, type the current password.",
                    "Click the action button and save the new file.",
                ],
                controls: [
                    ("Add password / Remove password", "Switches between encrypting a PDF and stripping the password from one."),
                    ("New / Confirm password", "The password required to open the file, entered twice to catch typos."),
                    ("Current password", "The password that currently opens the PDF you're unlocking."),
                    ("Protect & save… / Remove password & save…", "Writes the encrypted or decrypted copy; the original file is unchanged."),
                ],
                tips: [
                    "There is no password recovery — if you forget an Add-password password, the file cannot be opened.",
                    "Removing a password only works on files you can already open with their current password.",
                    "Removing a password rebuilds the file: pages and document info carry over, but bookmarks, attachments, and interactive form structure do not.",
                ]
            )
        }
    }
}
