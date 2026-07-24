import Foundation

/// Rich help text for each tool's Help article: overview, steps, a control glossary, and tips. The
/// words here are the single source for both the tool screen's own guidance and the tool's article in
/// the Help book (`HelpBook.toolTopic` derives the article from this), so keep every label matching the
/// on-screen text — the drift these fields exist to prevent is exactly the drift users notice first.
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
                    ("Info fields", "Title, Author, Subject, Keywords (a comma-separated list), and Creator app as stored in the file. Blank fields are omitted from the saved copy entirely."),
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
        case .ocr:
            return ToolHelpContent(
                overview:
                    "OCR reads the picture of each scanned page with Apple's on-device text recognition and hides real, selectable text behind it. The page image is unchanged—search, copy, and highlighting simply start working. Nothing is uploaded anywhere.",
                steps: [
                    "Choose or drop a scanned PDF.",
                    "Pick Accurate (best hit rate) or Fast (long documents).",
                    "Leave “Skip pages that already have text” on unless a page’s existing text layer is broken.",
                    "Click Make searchable & save…—a progress bar tracks recognition page by page, and Cancel stops it (leaving the screen stops it too)—then save the new PDF.",
                ],
                controls: [
                    ("Accuracy", "Accurate uses the slower neural recognizer with language correction; Fast trades some accuracy for speed."),
                    ("Skip pages that already have text", "Pages whose text already selects are copied through untouched, so mixed documents only OCR the true scans."),
                    ("Cancel", "Stops recognition mid-run; nothing is saved. Leaving the screen cancels the run too."),
                    ("Make searchable & save…", "Runs recognition off the main thread, page by page, then opens the export sheet."),
                ],
                tips: [
                    "Everything runs on this Mac—no page image or recognized text ever leaves it.",
                    "Selection rectangles land where the recognizer saw each line, so highlights line up with the printed words.",
                    "If every page already has selectable text there is nothing to recognize, so no file is saved—turn off “Skip pages that already have text” to force a fresh layer.",
                    "Recognition quality follows scan quality: a straight, 300-dpi scan reads far better than a skewed phone photo. Crop or rotate first if the page is messy.",
                    "Bookmarks, the document title, and clickable links are carried into the recognized copy. Interactive form fields are not—each page is redrawn from its content.",
                ]
            )
        case .crop:
            return ToolHelpContent(
                overview:
                    "Crop tightens what viewers display of each page—the crop box—without deleting anything. Auto-detect finds where the content actually is on each page; Custom margins trim fixed amounts you type; Drag to crop lets you draw the crop box right on the page. A new PDF is written and the original stays put.",
                steps: [
                    "Choose or drop a PDF.",
                    "Under Crop mode, pick Auto-detect, Custom margins, or Drag to crop.",
                    "Auto-detect: set the breathing room to keep around the content, and whether every page shares one uniform crop or is trimmed to its own content. Custom margins: type a trim for the top, bottom, left, and right.",
                    "Drag to crop: draw a rectangle on the page or pull its eight handles; use Page X of N to move between pages and the zoom slider to work in close. The dimmed area is what gets trimmed.",
                    "Click Crop & save… and save the new PDF.",
                ],
                controls: [
                    ("Auto-detect", "Renders each page and trims to the bounds of its content, plus your breathing room."),
                    ("Breathing room", "Points of margin kept around the detected content (72 pt = 1 inch), set with the field or stepper."),
                    ("Use the same crop on every page", "In Auto-detect, applies the smallest per-edge trim that is safe on every page, so all pages keep one size—best for book scans. In Drag to crop, on trims every page; off crops only the page you're viewing and leaves the rest exactly as they are."),
                    ("Custom margins", "Trims exactly what you type from the top, bottom, left, and right of every page, measured as displayed (72 pt = 1 inch, 28 pt ≈ 1 cm)."),
                    ("Drag to crop", "Draw the crop rectangle directly on the page and fine-tune it with eight resize handles; the Top/Bottom/Left/Right fields mirror the box, so you can also type to nudge it. Reset selection clears it back to the full page."),
                    ("Zoom / Page X of N", "Zoom into the page (100–400%) and step between pages while drawing the crop box."),
                    ("Crop & save…", "Writes a new PDF with the tightened crop boxes."),
                ],
                tips: [
                    "Cropping is non-destructive: the content outside the crop box is hidden, not deleted, and another PDF editor can crop back out.",
                    "In Custom margins and Drag to crop, Crop & save… stays disabled until you set a non-zero trim.",
                    "A trim that would leave less than about a third of an inch of page is refused rather than producing a sliver.",
                    "Blank pages are left alone by Auto-detect—there is nothing to crop to.",
                    "An interactive form stops working in the saved copy — the fields stay visible and keep their values, but no reader will treat them as a fillable form again. Bookmarks, links, and the document title are kept.",
                ]
            )
        case .imagesToPdf:
            return ToolHelpContent(
                overview:
                    "Images to PDF combines pictures into one document, a page per image, in list order. iPhone photos, screenshots, and scans all work—orientation is read from the file, so sideways shots come out upright.",
                steps: [
                    "Click Add Images… and pick one or more images (⌘-click for several), or drag them from Finder onto the dashed area. JPG, PNG, HEIC, TIFF, and other common formats all work.",
                    "Reorder with the chevron buttons; the trash button removes a row without touching the file on disk.",
                    "Pick a page size: Auto gives every page its image’s exact shape; A4 and US Letter are fixed paper sizes.",
                    "On a fixed size, choose Fit (whole image visible) or Fill (edge to edge, cropped).",
                    "Click Combine & save… and choose where the PDF goes.",
                ],
                controls: [
                    ("Add Images…", "Appends chosen images to the list. Order is top to bottom in the PDF; each row shows the image’s pixel size (W × H)."),
                    ("↑ / ↓", "Swaps the row with its neighbor—fix order without re-importing."),
                    ("Page size", "Auto (match image) makes each page exactly its image’s size. A4 and US Letter flip to landscape automatically for landscape images."),
                    ("Fit / Fill", "Fit letterboxes the whole image onto the page; Fill covers the page completely and crops the overflow."),
                    ("Combine & save…", "Builds the PDF off the main thread, then opens the save panel."),
                ],
                tips: [
                    "The pixel size on each row is handy for spotting a low-resolution image before you combine.",
                    "Big photos make big PDFs—run the result through Compress if it needs to be emailed.",
                    "The same image can appear twice: add it twice and it becomes two pages.",
                ]
            )
        case .compress:
            return ToolHelpContent(
                overview:
                    "Compression rebuilds each page as an image and wraps it in a new PDF—best for scan- and photo-heavy documents; pure text PDFs may not shrink much. Pick a strength and see the size it will produce before you commit, or name a target size and let the tool work the quality down until the file fits.",
                steps: [
                    "Choose or drop a PDF (add several to compress a whole batch at once).",
                    "In By quality, pick Best Quality, Balanced, or Smallest File—each card previews the size it will produce—or open Fine-tune quality for the exact slider.",
                    "Or switch to By target size and type a size in MB; the tool lowers quality until the file fits under it.",
                    "Click Compress & save…. Afterwards a before/after card shows how much smaller the file got, with Reveal in Finder.",
                ],
                controls: [
                    ("By quality / By target size", "Two ways to compress: pick a named strength, or name a size in MB to fit under."),
                    ("Best Quality / Balanced / Smallest File", "Three one-tap strengths, lightest to strongest. Each card shows a live estimate of the file it will produce; tap one to select it."),
                    ("Fine-tune quality", "Reveals the exact quality slider (0.2–1) when a card isn't precise enough; the slider still highlights whichever card its value falls in."),
                    ("By target size", "Type a size in MB; the tool sweeps progressively lower quality and writes the highest-quality file that fits under it. Projected output previews the result."),
                    ("Compress & save… / Run on N files", "Compresses the one file through the save sheet, or every queued file at once following your Save location."),
                ],
                tips: [
                    "The before/after card reports the percent saved and the old→new size. “Already optimized” means the PDF was already about as small as it gets.",
                    "Compression never makes a file bigger: if a page can't be shrunk, the original is passed through unchanged.",
                    "Size estimates follow the “Strip metadata on export” setting, so the preview matches the file you actually save.",
                    "Bookmarks, the document title, and clickable links survive compression—only the page artwork is rebuilt as images.",
                    "Interactive form fields are flattened into the page — the saved copy looks identical but can no longer be filled in. Bookmarks, links, and the title are kept.",
                ]
            )
        case .rotate:
            return ToolHelpContent(
                overview:
                    "Rotation turns pages by 90°, 180°, or 270° and writes the result to a new PDF. Rotate one file—every page or only the pages you list—or add several files to rotate them all in one run. Your original files stay untouched.",
                steps: [
                    "Choose or drop one or more PDFs (Choose PDF… / Add PDFs…).",
                    "For a single file, pick All pages or Page range and, if needed, type pages like 1, 3-5, 8 (1-based, comma-separated).",
                    "Pick 90° clockwise, 180°, or 270° clockwise.",
                    "Click Rotate & save… for one file, or Run on N files for a batch—every page of every file is rotated. Watch the queue and use Show in Finder when it's done.",
                ],
                controls: [
                    ("Pages (one file)", "All pages turns every sheet; Page range turns only the pages you type. With two or more files this option goes away—every page of every file is rotated."),
                    ("Page range field", "With Page range selected, list pages using commas and ranges (1, 3-5, 8). An empty field is an error, not “all pages”."),
                    ("Rotation", "90° clockwise, 180°, or 270° clockwise. Each selected page is turned by that amount; other pages are unchanged."),
                    ("Rotate & save… / Run on N files", "Rotates the one file through the save sheet, or every queued file at once following your Save location."),
                ],
                tips: [
                    "In a page range, order doesn’t matter—each listed page is rotated once.",
                    "Page ranges apply to a single file; a multi-file run rotates every page of every file.",
                    "A PDF whose owner-password restrictions forbid changing its pages is refused rather than saved unrotated—remove the restrictions with Password Protect first.",
                ]
            )
        case .merge:
            return ToolHelpContent(
                overview:
                    "Merge combines PDFs in list order: first file’s pages, then the second’s, and so on. By default it takes every page of each file, but you can include only a subset of any file by typing a page range in its Pages field. The same file can appear twice if you add it twice.",
                steps: [
                    "Click Add PDFs… and select one or more PDFs (⌘-click for multiple), or drag PDFs from Finder onto the dashed area or list.",
                    "To include only some pages of a file, type a range in its Pages field (for example 1, 3-5). Leave it blank to take the whole file. The row shows how many pages will be used (e.g. “3 of 12 pages”).",
                    "Reorder by dragging rows in the list or with the chevron buttons; Delete removes the selected row; trash removes that file from the merge list only.",
                    "Watch the preview column on the right: it shows the pages in merge order. Use the trash on any page to drop it from the output; use the slider to change thumbnail size.",
                    "Click Merge & save…, choose a path in the save panel, then use Do another on the success screen to merge again.",
                ],
                controls: [
                    ("Add PDFs…", "Appends chosen PDFs to the list. Order is top to bottom in the merged file."),
                    ("Pages field", "Which pages of that file to include, like Extract: “1, 3-5” keeps those pages, in the order typed; blank means all pages."),
                    ("Clear all", "Empties the list and clears the preview."),
                    ("↑ / ↓", "Swaps the row with its neighbor—handy for fixing order without re-importing."),
                    ("Trash (row)", "Removes that entry from the list; it does not delete the file from disk."),
                    ("Trash (thumbnail)", "Leaves that single page out of the merged PDF. “Restore N hidden pages” brings them all back."),
                    ("Password-protected files", "A locked PDF is badged “Password-protected — can’t merge” and left out of the page total; the merge stays disabled until you remove it, or strip its password with Password Protect → Remove password."),
                    ("Preview slider", "Resizes page thumbnails in the right-hand preview."),
                    ("Merge & save…", "Opens the save panel, then writes one combined PDF from the pages you chose."),
                ],
                tips: [
                    "A page range keeps the order you type (for example 5,1,2), just like Extract.",
                    "Large merges can take a moment; the window should stay responsive while working.",
                    "Bookmarks aren’t carried into the merged file — each source has its own outline at different page offsets, so they’re dropped rather than pointed at the wrong pages. Page content, links, form fields, and the first file’s title are unaffected.",
                    "An interactive form also stops working — the fields stay visible and keep their values, but no reader will treat them as a fillable form again.",
                ]
            )
        case .split:
            return ToolHelpContent(
                overview:
                    "Split cuts one PDF into several separate files. Cut visually by clicking between pages, slice into fixed chunks of N pages, or list custom page ranges when each section is a different length. Every part is a full PDF; the original is left as-is.",
                steps: [
                    "Choose or drop a PDF.",
                    "Under How to split, pick Visual, Every N, or Custom.",
                    "Visual: click the scissors between two pages in the preview to start a new file there; each colored group (PDF 1, PDF 2, …) becomes one file. Every N: set the pages-per-file stepper. Custom: list groups like 1-3, 4-6, 7-10.",
                    "Watch “Creates N files” confirm the result, then click Split & save… and choose a destination folder.",
                    "Use Show in Finder on the success screen to reveal the new files, or Do another to split again.",
                ],
                controls: [
                    ("Visual", "Click a scissors between pages to start a new file there; click a Cut pill to merge two files back together. Each colored group—PDF 1, PDF 2, …—is one output file."),
                    ("Clear cuts", "Merges every group back into one file, so you can start the cuts over."),
                    ("Every N", "Cuts the document into consecutive chunks of the pages-per-file you set; the last file takes the remainder."),
                    ("Custom", "Each comma-separated group becomes one file (1-3 → a 3-page file), using 1-based, inclusive ranges. You can also click pages in the preview—each unbroken run becomes its own file."),
                    ("Split & save…", "Writes each part into the folder you choose as name-01.pdf, name-02.pdf, …"),
                ],
                tips: [
                    "The live “Creates N files” count under the options shows how many files the current settings will produce.",
                    "A part whose name is already taken in the chosen folder is numbered (\u{201C}name 2.pdf\u{201D}) — existing files are never overwritten.",
                    "Bookmarks aren’t carried into the parts — one outline can’t be cut across several files correctly yet, so they’re dropped rather than misdirected. Page content, links, form fields, and the document title are unaffected.",
                    "An interactive form also stops working — the fields stay visible and keep their values, but no reader will treat them as a fillable form again.",
                ]
            )
        case .extract:
            return ToolHelpContent(
                overview:
                    "Extract copies the pages you list into a brand-new PDF. Order is preserved: 3,1 puts page 3 first, then page 1. Ranges expand in order (3-5 → 3,4,5; 5-3 → 5,4,3).",
                steps: [
                    "Choose or drop a source PDF.",
                    "Type the pages in the Pages to extract field, or click pages in the preview to select them—the field and thumbnails stay in sync. Leave it blank to take all pages.",
                    "Click Extract & save… and save the new file.",
                ],
                controls: [
                    ("Pages to extract", "1-based numbers, commas, and inclusive ranges. Blank means all pages."),
                    ("Preview thumbnails", "Click a page to add or remove it from the selection; the field and highlights update live."),
                    ("Extract & save…", "Builds a new PDF containing only the selected pages, in order."),
                ],
                tips: [
                    "You can list the same page more than once if you need duplicates in the output.",
                    "Clicking pages sorts them into ascending order. To keep a custom order (for example 5, 1, 2), type it in the field and leave the thumbnails alone.",
                    "An interactive form stops working in the saved copy — the fields stay visible and keep their values, but no reader will treat them as a fillable form again. Bookmarks, links, and the document title are kept.",
                ]
            )
        case .reorder:
            return ToolHelpContent(
                overview:
                    "Reorder Pages shows every page of a PDF as a thumbnail you can drag into a new order—and drop the ones you don't need—then save the result as a new file. Removing a page only leaves it out of the saved copy; your original file is never changed, and any removed page can be restored. Each thumbnail keeps its original page number as a badge, so you can always tell where a page came from; its place in the grid is its new position.",
                steps: [
                    "Choose or drop a PDF; its pages appear as thumbnails on the right.",
                    "Drag a thumbnail to a new spot—the others shuffle to make room. (Use a thumbnail's ‹ › buttons, or right-click it, to move a page without dragging.)",
                    "Trash a page's thumbnail to leave it out of the copy; restore it from the Removed area on the left if you change your mind.",
                    "Watch the grid reflow to the pages you're keeping; use Reset to restore the original order and bring every page back.",
                    "Click Reorder & save… and pick a name for the new file.",
                ],
                controls: [
                    ("Drag a thumbnail", "Moves that page; the grid reorders live as the drag crosses other pages. Its badge stays the original page number."),
                    ("‹ › buttons", "Nudge a page one slot earlier or later without dragging—the click or keyboard path to reordering; disabled at the ends."),
                    ("Right-click a page", "Move to Front / Left / Right / End, or Remove—the same moves for when dragging is awkward."),
                    ("Trash", "Leaves that page out of the saved copy. Nothing is written to disk, so it's easy to undo."),
                    ("Removed (N) · Restore", "Lists the pages you've removed; Restore adds one back, Restore all brings every page back."),
                    ("Thumbnail size", "Scales the preview thumbnails; it doesn't change the PDF."),
                    ("Reset", "Restores the original order and brings back every removed page. Appears once you've changed something."),
                    ("Reorder & save…", "Writes a new PDF with the kept pages, in the grid order; the original file is unchanged."),
                ],
                tips: [
                    "Saving without changing anything just copies the document in its original order.",
                    "Saving is blocked while every page is removed—restore at least one to write a file.",
                    "An interactive form stops working in the saved copy — the fields stay visible and keep their values, but no reader will treat them as a fillable form again. Bookmarks, links, and the document title are kept.",
                ]
            )
        case .deletePages:
            return ToolHelpContent(
                overview:
                    "Delete pages writes a new PDF that omits the pages you specify. You must type which pages to remove; an empty field shows an error instead of deleting everything.",
                steps: [
                    "Choose or drop the PDF to edit.",
                    "Read the page numbers off the thumbnails on the right, then type the ones to drop (e.g. 2 or 1, 4-6) using 1-based numbers.",
                    "Click Delete pages & save…. You cannot remove every page—one sheet must remain.",
                ],
                controls: [
                    ("Pages to remove", "Required. Uses the same range syntax as other tools, but blank input is not allowed."),
                    ("Preview / Thumbnail size", "Shows every page with its number so you can pick what to remove; the slider only resizes thumbnails. Pages can't be removed by clicking here—type them on the left."),
                    ("Delete pages & save…", "Produces a copy without those pages; the original file is unchanged on disk."),
                ],
                tips: [
                    "If nothing seems to happen, confirm macOS allowed access to the file (try choosing it again).",
                    "A PDF whose owner-password restrictions forbid changing its pages is refused rather than saved with the pages still in it—remove the restrictions with Password Protect first.",
                    "Bookmarks pointing at a deleted page are removed too, so no bookmark sends a reader to the wrong content.",
                ]
            )
        case .watermark:
            return ToolHelpContent(
                overview:
                    "Watermark stamps text—or your own logo image—across the pages you choose and bakes it into a new PDF. The underlying page is copied as vector content, so its text stays selectable; the stamp becomes part of the page, not a removable annotation.",
                steps: [
                    "Choose or drop a PDF (add several to stamp a whole batch).",
                    "Pick Text or Image. For text, type it or tap a preset—CONFIDENTIAL, DRAFT, COPY—and choose a color and font. For image, click Choose image or PDF… (PNG, JPG, HEIC, or a PDF logo; transparency is kept).",
                    "Set Layout (Centered or Tiled) and Pages (All pages, First page, or a Custom range like 1, 3-5), then tune Size, Opacity, and Angle—the preview updates live.",
                    "Click Watermark & save… and pick a name for the new file.",
                ],
                controls: [
                    ("Watermark type", "Text stamps a word or phrase; Image stamps a logo you supply."),
                    ("Watermark text", "The string to stamp, with quick presets (CONFIDENTIAL, DRAFT, COPY). Text mode only."),
                    ("Watermark image", "PNG, JPG, HEIC, or a PDF logo (its first page). Transparency is preserved; Replace… swaps it, the trash button removes it."),
                    ("Color", "Four quick swatches—Black, Gray, Red, Blue—or Custom… for any color. Text mode only."),
                    ("Font", "The system default or any installed family. Text mode only."),
                    ("Centered / Tiled", "Centered draws the stamp once in the middle; Tiled repeats it across the whole page."),
                    ("Pages", "All pages, First page, or Custom—pick Custom to type a range like 1, 3-5, 8."),
                    ("Size / Opacity / Angle", "Point size in Text mode (12–160 pt) or logo scale in Image mode (5–100%); fill strength (5–100%); and rotation (−90° to 90°)."),
                    ("Watermark & save… / Run on N files", "Bakes the stamp into a new PDF—one file through the save sheet, or every queued file at once."),
                ],
                tips: [
                    "A subtle text watermark usually reads best at 15–30% opacity and around 45°.",
                    "Bookmarks, the document title, and clickable links are carried into the watermarked copy. Interactive form fields are not—each page is redrawn from its content, so a fillable field becomes part of the picture.",
                    "Across several files, a Custom page range follows each file's own page count; an empty Custom range is an error, not “all pages”.",
                ]
            )
        case .redact:
            return ToolHelpContent(
                overview:
                    "Redaction permanently destroys content on the pages you mark: each marked page is rebuilt as a flat image with solid black over every region you drew, so nothing on that page can be copied or searched in the export. Your original file is not changed until you save the sanitized copy.",
                steps: [
                    "Choose or drop a PDF.",
                    "Hold ⇧ Shift, then drag on the preview to draw each redaction rectangle (stay on one page per drag).",
                    "Or use Find & redact: type text (an email, a name) or tap a pattern chip (Emails, SSNs, Phone numbers, Card numbers) to auto-mark every match across the document.",
                    "Review the region list on the left — auto-marks are tagged “Auto” and outlined with a dash; remove any with the trash button, Clear auto-marks, or Clear all.",
                    "Optional: raise Redacted page sharpness for crisper bitmap pages on the pages you marked.",
                    "Optional: enable removing annotations from pages you did not redact to avoid leaking hidden comments.",
                    "Click Redact & save… and pick a new filename for the sanitized PDF.",
                ],
                controls: [
                    ("⇧ Shift-drag", "Required modifier so normal scrolling and selection still work. Each drag must begin and end on the same page."),
                    ("Find & redact", "Type free text, or tap a pattern chip (emails, US SSNs, phone numbers, card numbers), and every case-insensitive match becomes a redaction region — for review, never applied automatically. Pages with no text layer (unrecognized scans) are reported so you can mark them by hand."),
                    ("Regions list", "Lists page numbers for each mark and tags auto-detected ones. Delete individual marks, Clear auto-marks, or Clear all."),
                    ("Redacted page sharpness", "More pixels on the longest edge when rasterizing only the pages you marked—helps text stay readable after export."),
                    ("Remove highlights & notes from other pages", "Strips all PDF annotations from pages that were not rasterized—stronger hygiene for sharing."),
                    ("Redact & save…", "Builds a new PDF on disk; work stays on your Mac."),
                ],
                tips: [
                    "Redaction is irreversible—double-check every mark before exporting.",
                    "Rerunning a search won't stack duplicate boxes—an identical region is skipped, and the summary reports how many are new.",
                    "Very small rectangles may be ignored; drag a box at least a few points on each side.",
                    "Redacted pages are saved as full-page images, so anything on a marked page—not just the black boxes—is flattened out of the text layer, including any clickable links on that page.",
                    "Bookmarks and the document title are carried into the sanitized copy; pages you did not mark keep their own links and annotations unless you turn on removing them above.",
                ]
            )
        case .fillSign:
            return ToolHelpContent(
                overview:
                    "Fill & Sign lets you type into a flat (non-interactive) PDF form and add a signature. Typed text is baked in as selectable vector text; a signature you draw with the trackpad—or type in a script font—is baked in as vector ink. The original file is not changed until you save the new PDF.",
                steps: [
                    "Choose or drop a PDF, then scroll to the page you want to work on.",
                    "Click Add text to drop a text box on the page showing in the preview, then type into the Selected item field; drag the box to position it and drag its bottom-right handle to resize.",
                    "Use Add date for a one-tap dated stamp.",
                    "To sign: under Signature draw on the pad with the trackpad (or switch to Type and enter a name in a script font), then click Place signature to drop it on the page.",
                    "Reposition and resize items on the page, then click Sign & save… to write the new PDF.",
                ],
                controls: [
                    ("Ink color", "The color used for the next text box or signature you place—set it before adding an item."),
                    ("Add text / Add date", "Drops a new text box on the page showing in the preview—empty, or prefilled with today's date."),
                    ("Selected item", "Edit the highlighted item: its text, font size, or delete it. Signatures show a size note only."),
                    ("Signature · Draw / Type", "Draw a freehand signature on the pad, or type a name rendered in a handwriting font."),
                    ("Place signature", "Drops the drawn or typed signature onto the current page so you can position it."),
                    ("Drag / corner handle", "Drag an item to move it; drag its bottom-right handle to resize. Signatures scale with the box."),
                    ("Sign & save…", "Bakes every placed item into a new PDF; the original file is unchanged."),
                ],
                tips: [
                    "Text stays selectable and searchable in the export—only the signature is drawn ink.",
                    "New items land centered on whichever page is showing in the preview, and live on that page—scroll to a page before adding to it.",
                    "Existing interactive AcroForm fields aren't detected here—this tool is for typing onto flat forms and layering a signature on top, and a fillable field becomes part of the picture in the saved copy.",
                    "Bookmarks, the document title, and clickable links are carried into the signed copy.",
                ]
            )
        case .protect:
            return ToolHelpContent(
                overview:
                    "Password Protect encrypts a PDF so it can only be opened with a password you set, or removes a password from a PDF you can already open. Everything runs on your Mac and the password is never sent anywhere.",
                steps: [
                    "Choose or drop a PDF (add several to protect or unlock a whole set with one password).",
                    "Pick Add password or Remove password.",
                    "For Add password, type the password twice so they match; for Remove, type the current password.",
                    "Click the action button—Protect & save… / Remove password & save… for one file, or Run on N files for a batch—and save.",
                ],
                controls: [
                    ("Add password / Remove password", "Switches between encrypting a PDF and stripping the password from one."),
                    ("New / Confirm password", "The password required to open the file, entered twice to catch typos."),
                    ("Current password", "The password that currently opens the PDF you're unlocking. It disappears for a file that only restricts editing — that file already opens without a password, so none is asked for or checked."),
                    ("Protect & save… / Remove password & save…", "Writes the encrypted or decrypted copy; the original file is unchanged."),
                    ("Run on N files", "Applies the same password to every queued PDF at once; results follow your Save location, and Show in Finder reveals them."),
                ],
                tips: [
                    "There is no password recovery — if you forget an Add-password password, the file cannot be opened.",
                    "In a batch, the one password you enter is applied to every file.",
                    "Removing a password only works on files you can already open with their current password.",
                    "Restrict-editing protection is different: the PDF format leaves those restrictions up to each reader to honor, so they aren't enforced by encryption. Any PDF app can lift them, and Remove password does so without asking for the owner password — there is no way to check one on a file that already opens.",
                    "Removing a password rebuilds the file: pages, bookmarks, and document info carry over, but attachments do not, and an interactive form stops working — the fields stay visible and keep their values, yet no reader will treat them as a fillable form again.",
                ]
            )
        }
    }
}
