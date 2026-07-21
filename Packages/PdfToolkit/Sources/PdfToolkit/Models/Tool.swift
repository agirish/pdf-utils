import SwiftUI

public enum Tool: String, CaseIterable, Identifiable, Hashable {
    case compress
    case rotate
    case merge
    case split
    case extract
    case reorder
    case deletePages
    case watermark
    case redact
    case fillSign
    case protect
    case metadata
    case imagesToPdf
    case crop
    case ocr

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compress: return "Compress PDF"
        case .rotate: return "Rotate PDF"
        case .merge: return "Merge PDF"
        case .split: return "Split PDF"
        case .extract: return "Extract PDF Pages"
        case .reorder: return "Reorder Pages"
        case .deletePages: return "Delete PDF Pages"
        case .watermark: return "Watermark PDF"
        case .redact: return "Redact PDF"
        case .fillSign: return "Fill & Sign"
        case .protect: return "Password Protect"
        case .metadata: return "Clean Metadata"
        case .imagesToPdf: return "Images to PDF"
        case .crop: return "Crop PDF"
        case .ocr: return "OCR PDF"
        }
    }

    public var subtitle: String {
        switch self {
        case .compress:
            return "Shrink file size for sharing"
        case .rotate:
            return "Turn pages 90° at a time"
        case .merge:
            return "Combine PDFs, whole or by page"
        case .split:
            return "Break one PDF into several files"
        case .extract:
            return "Save selected pages as a new PDF"
        case .reorder:
            return "Rearrange pages, and drop any you don't need"
        case .deletePages:
            return "Remove unwanted pages"
        case .watermark:
            return "Stamp text or a logo across your pages"
        case .redact:
            return "Permanently black out sensitive areas"
        case .fillSign:
            return "Add text and a signature to a PDF"
        case .protect:
            return "Encrypt a PDF, or remove its password"
        case .metadata:
            return "View, edit, or strip hidden document info"
        case .imagesToPdf:
            return "Turn photos and scans into one PDF"
        case .crop:
            return "Trim margins by hand or automatically"
        case .ocr:
            return "Make scanned pages searchable"
        }
    }

    /// Short paragraph shown under the navigation area on each tool screen.
    public var headerDescription: String {
        switch self {
        case .compress:
            return "Rebuilds each page as an image to reduce file size—best for scans and photos. Vector text may become non-selectable; use the quality slider to balance size and sharpness."
        case .rotate:
            return "Turn every page or only the pages you list. Rotation is written into a new PDF; your original file stays untouched until you save over it from the save panel."
        case .merge:
            return "Stack several PDFs into one file in the order shown. Take only some pages of a file by typing a range in its Pages field (for example 1, 3-5); leave it blank for all pages. Reorder rows with the arrows, or drop a stray page straight from the combined preview."
        case .split:
            return "Cut one PDF into several. Split into fixed chunks of N pages, or list custom page ranges where each group becomes its own file. Parts are written into a folder you choose; the original file stays untouched."
        case .extract:
            return "Copy chosen pages into a new PDF in the order you type (for example 5,1,2). Handy for pulling chapters or attachments out of a larger document."
        case .reorder:
            return "Drag pages into the order you want—and trash any you don't need—then save a new PDF. Removed pages are only left out of the copy; nothing changes on disk, and you can restore any of them before saving. The preview follows the arrangement so you can see the result before saving; the original file is untouched."
        case .deletePages:
            return "Produce a new PDF without the pages you specify. You must list which pages to drop—an empty field will not delete everything. At least one page must remain."
        case .watermark:
            return "Overlay text—DRAFT, CONFIDENTIAL, a name—or your own logo image. Pick the font, color, size, angle, and opacity; choose a single centered stamp or a tiled pattern; and apply it to every page, the first page, or a range you type. The underlying page stays vector (text stays selectable); your original file is untouched."
        case .redact:
            return "Draw rectangles over names, account numbers, or images you want gone for good—or use Find & redact to auto-mark every match of a word or pattern. Marked regions are rebuilt as solid black—text there can’t be copied or searched. Everything runs on your Mac; review marks before exporting."
        case .fillSign:
            return "Drop typed text onto a non-interactive form, then draw or type a signature and place it on the page. Text stays selectable; the signature is baked in as vector ink. Your original file is untouched until you save the new PDF."
        case .protect:
            return "Add a password that’s required to open a PDF, or strip the password from one you can already open. Encryption is the standard PDF scheme, applied on your Mac—the password never leaves your machine."
        case .metadata:
            return "See what a PDF says about itself—title, author, keywords, the app that made it, dates—then edit any field or strip them all before sharing. Only the info fields are rewritten; the pages themselves are untouched."
        case .imagesToPdf:
            return "Drop in JPG, PNG, or HEIC images and get one PDF with a page per image, in the order shown. Choose a paper size—or let each page match its image exactly—and whether pictures fit inside the page or fill it edge to edge."
        case .crop:
            return "Tighten every page's margins—type a trim for each edge, or let the tool find the content bounds on its own. Cropping changes what viewers display; nothing is deleted from the page, and your original file stays untouched."
        case .ocr:
            return "Runs Apple's text recognition over every page—entirely on your Mac—and lays an invisible, selectable text layer behind the scan. The page image is unchanged; search, copy, and highlight simply start working."
        }
    }

    public var symbolName: String {
        switch self {
        case .compress: return "arrow.down.doc"
        case .rotate: return "rotate.right"
        case .merge: return "square.stack.3d.up"
        case .split: return "scissors"
        case .extract: return "doc.on.clipboard"
        case .reorder: return "arrow.up.arrow.down.square"
        // Badge-style "doc" symbols can look blank with hierarchical tinting on dashboard tiles; use a solid portrait-page + minus.
        case .deletePages: return "minus.rectangle.portrait.fill"
        case .watermark: return "signature"
        case .redact: return "eraser.line.dashed"
        case .fillSign: return "hand.draw"
        case .protect: return "lock.doc"
        case .metadata: return "tag.slash"
        case .imagesToPdf: return "photo.on.rectangle.angled"
        case .crop: return "crop"
        case .ocr: return "text.viewfinder"
        }
    }

    /// Which dashboard section this tool lives under (see ``ToolCategory``). The authoritative
    /// membership map; `ToolCategory.tools` fixes the order within a section and is kept in sync by test.
    public var category: ToolCategory {
        switch self {
        case .compress, .ocr:
            return .optimize
        case .merge, .split, .extract, .reorder, .deletePages, .rotate:
            return .organize
        case .crop, .watermark, .fillSign, .imagesToPdf:
            return .edit
        case .redact, .protect, .metadata:
            return .secure
        }
    }

    public var accent: Color {
        switch self {
        case .compress: return .orange
        case .rotate: return .blue
        case .merge: return .purple
        case .split: return .indigo
        case .extract: return .teal
        case .reorder: return .mint
        case .deletePages: return .pink
        case .watermark: return .brown
        case .redact: return Color(red: 0.78, green: 0.16, blue: 0.22)
        case .fillSign: return Color(red: 1.0, green: 0.45, blue: 0.4)
        case .protect: return .green
        // Periwinkle: sits between merge's purple and split's indigo without matching either.
        case .metadata: return Color(red: 0.48, green: 0.53, blue: 0.94)
        case .imagesToPdf: return .yellow
        // Lime: greener than protect's system green, far from mint/teal.
        case .crop: return Color(red: 0.64, green: 0.78, blue: 0.22)
        case .ocr: return .cyan
        }
    }
}
