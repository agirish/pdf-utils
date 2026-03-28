# pdf-utils

Native **macOS** app for everyday PDF tasks: a tile-based **dashboard** (similar in spirit to tool hubs like [Smallpdf’s tools page](https://smallpdf.com/pdf-tools)), implemented with **SwiftUI** and **PDFKit**. Everything runs on your Mac; you pick input PDFs and save results with the system file UI.

## Tools (v1)

| Tool | What it does |
|------|----------------|
| **Compress PDF** | Rebuilds pages as images with adjustable quality to reduce file size (best for scan-heavy PDFs; vector text may become rasterized). |
| **Rotate PDF** | Rotates all pages or a **page range** by 90° / 180° / 270°. |
| **Merge PDF** | Combines multiple PDFs **top to bottom** in the list (reorder with **Edit**). |
| **Extract PDF Pages** | Saves a new PDF containing only the pages you list (e.g. `1, 3-5`). Leave the field empty to use all pages. |
| **Delete PDF Pages** | Writes a new PDF with listed pages removed (original file is not modified). |

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
Sources/PdfUtils/
  PdfUtilsApp.swift       # App entry, window
  Models/Tool.swift       # Dashboard tiles & metadata
  Services/               # PDFKit operations + errors
  Utilities/PageRangeParser.swift
  Views/                  # Dashboard, tool screens, shared chrome
```

## Capabilities & privacy

- No network calls; no analytics in this codebase.
- Uses **security-scoped** access from the file importer for chosen files.

## License

Add a `LICENSE` file when you decide how you want to distribute this project.
