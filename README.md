# pdf-utils

Native **macOS** app for everyday PDF tasks: a tile-based **dashboard** (similar in spirit to tool hubs like [Smallpdf’s tools page](https://smallpdf.com/pdf-tools)), implemented with **SwiftUI** and **PDFKit**. Everything runs on your Mac; you pick input PDFs and save results with the system file UI.

## Tools

| Tool | What it does |
|------|----------------|
| **Compress PDF** | Rebuilds pages as images with adjustable quality to reduce file size (best for scan-heavy PDFs; vector text may become rasterized). Uses CoreGraphics (`CGPDFPage` drawing transform) so intrinsic page rotation in the file is flattened into the bitmap; output pages use rotation 0 to avoid double-applying. |
| **Rotate PDF** | Rotates all pages or a **page range** by 90° / 180° / 270°. |
| **Merge PDF** | Combines multiple PDFs **top to bottom** in the list (per-row **↑ / ↓** to reorder, **trash** to remove from the list). |
| **Split PDF** | Cuts one PDF into several files — fixed chunks of **N pages**, or **custom ranges** where each comma group (`1-3, 4-6, 7-10`) becomes its own file. Parts are written into a folder you choose. |
| **Extract PDF Pages** | Saves a new PDF containing only the pages you list (e.g. `1, 3-5`). Order matches what you type (`5,1,2` → page 5, then 1, then 2). Ranges expand forward (`3-5`) or backward (`5-3`). Leave the field empty to use all pages. |
| **Reorder Pages** | Lists every page as a draggable row; rearrange them (drag or **↑ / ↓**) and save a new PDF. The preview follows the new order, labeled with each page's original number. |
| **Delete PDF Pages** | Writes a new PDF with listed pages removed (original file is not modified). |
| **Watermark PDF** | Stamps text across every page (**centered** or **tiled**) with adjustable color, size, opacity, and angle. The underlying page is copied as vector, so its text stays selectable; the stamp is baked into the page content, not a strippable annotation. |
| **Redact PDF** | Draws rectangles you ⇧-drag over sensitive regions; those areas are rebuilt as solid black so the text underneath cannot be copied or searched in the export. Irreversible — review before saving. |
| **Password Protect** | Encrypts a PDF behind an open password, or removes a password from one you can already open. Runs entirely on your Mac; the password is never stored or sent anywhere. |

## Appearance

Open **Settings** (⌘,) to tune how the app looks:

- **Theme** — Light, Dark, or **System** (follows macOS). Applied through `NSApplication.appearance`, so it also reaches the title bar, open/save panels, and alerts — not just the SwiftUI views.
- **Window background** — Liquid glass (tinted gradient + material), or a flat system / paper-white / neutral canvas.
- **Accent color** — the hue used for the liquid-glass wash, chosen from a row of swatches.

### Page range syntax

- Comma-separated: `1, 3, 5`
- Inclusive ranges: `3-7`
- Mix: `1, 4-6, 10`  
Numbers are **1-based**, matching page labels in Preview.

## Requirements

- **macOS 15** or later (SwiftUI / PDFKit APIs used here).
- **Xcode 16+** (recommended) to open the Swift package.

## Build & run

1. Open **`Package.swift`** in Xcode (**File → Open…**).
2. Select the **`PdfUtils`** scheme (executable).
3. **Run** (⌘R).

From a terminal:

```bash
cd pdf-utils
swift build
swift run PdfUtils
```

`swift run` launches the GUI on macOS.

## Repository layout

```
Package.swift              # Swift package; open this in Xcode
MacApp/                    # App target (entry point, shell views, assets)
  PdfUtilsApp.swift
  Views/
Packages/PdfToolkit/       # Shared library: tools UI, PDF operations, settings
  Sources/PdfToolkit/
project.yml                # Optional: XcodeGen → PdfUtils.xcodeproj (gitignored)
```

## Capabilities & privacy

- No network calls; no analytics in this codebase.
- Uses **security-scoped** access from the file importer for chosen files. If macOS denies that access, the app shows a clear error instead of a generic PDF open failure.
- Heavy work runs **off the main thread** so the UI stays responsive on large files.

### Behaviour notes

- **Delete PDF Pages** requires an explicit page list. An empty field does *not* mean “all pages” (that would delete the entire document).
- You cannot remove **every** page; at least one page must remain in the output PDF.
- **Extract** / **Rotate (range)** still treat a blank range field as “all pages”, matching the on-screen hint. **Extract** keeps the order you list; **Rotate** and **Delete** still treat ranges as a set of unique pages (sorted internally where needed).

## License

Add a `LICENSE` file when you decide how you want to distribute this project.
