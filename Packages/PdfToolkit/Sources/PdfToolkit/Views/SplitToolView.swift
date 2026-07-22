import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private enum SplitMode: String, CaseIterable, Identifiable {
    case visual
    case everyN
    case customRanges

    var id: String { rawValue }

    /// Compact labels so all three fit the segmented control; the full wording lives in the helper
    /// text below each mode.
    var title: String {
        switch self {
        case .visual: return "Visual"
        case .everyN: return "Every N"
        case .customRanges: return "Custom"
        }
    }
}

private struct SplitResult {
    let directory: URL
    let files: [URL]
}

struct SplitToolView: View {
    @Environment(\.toolAccent) private var accent
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var inputURL: URL?
    @State private var mode: SplitMode = .visual
    @State private var chunkSize = 1
    @State private var rangeText = ""
    /// Visual mode's source of truth: 1-based cut points ("cut after page k"). The colored page groups,
    /// the live count, and the export all derive from this (see ``SplitCuts``). Empty = one file.
    @State private var cuts: Set<Int> = []
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var pageSpecs: [PreviewPageSpec] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120
    @State private var result: SplitResult?

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    private var pageCount: Int { pageSpecs.count }

    /// The exact output segments the current mode would write, when they are fully known — Visual and
    /// every-N always resolve; Custom resolves only once its text parses. `nil` means "not resolvable
    /// yet" (e.g. a half-typed custom range), which the count falls back to estimating.
    private var liveSegments: [[Int]]? {
        guard pageCount > 0 else { return nil }
        switch mode {
        case .visual:
            return SplitCuts.segments(pageCount: pageCount, cuts: cuts)
        case .everyN:
            return PageRangeParser.everyNPagesSegments(pageCount: pageCount, chunkSize: chunkSize)
        case .customRanges:
            return try? PageRangeParser.parseSegments(rangeText, pageCount: pageCount)
        }
    }

    /// Number of output files the current settings would produce (for the live "Creates N files" hint).
    private var estimatedParts: Int? {
        guard pageCount > 0 else { return nil }
        if let segments = liveSegments { return segments.count }
        // Custom mode mid-type: the ranges don't parse yet, so estimate from comma groups so the hint
        // still tracks what the user is typing.
        let groups = rangeText.split(separator: ",").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return groups.isEmpty ? nil : groups.count
    }

    /// The Run button gate: a file plus a split we can actually resolve. Custom-ranges mode leaves
    /// `liveSegments` nil while the text is empty or half-typed, so this keeps a click from throwing
    /// `pageRangeRequired`; Visual and every-N always resolve once the pages are known.
    private var canRun: Bool {
        inputURL != nil && liveSegments != nil
    }

    /// Per-file page counts for the summary, e.g. "3 + 3 + 2 pages". Shown only when the segments are
    /// fully resolved and few enough to stay readable; a fine-grained split (many one-page files) drops
    /// to just the file count above.
    private var pageBreakdown: String? {
        guard let segments = liveSegments, !segments.isEmpty, segments.count <= 12 else { return nil }
        let total = segments.reduce(0) { $0 + $1.count }
        let counts = segments.map { String($0.count) }.joined(separator: " + ")
        return "\(counts) page\(total == 1 ? "" : "s")"
    }

    /// The reason the custom-ranges text can't be split, for the inline error under the field — the
    /// same parse the export runs, so what it rejects here is exactly what Save would reject. Blank and
    /// half-typed ("1-") states stay silent; only custom mode can produce one.
    private var customRangeError: String? {
        guard mode == .customRanges else { return nil }
        let trimmed = rangeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("-"), pageCount > 0 else { return nil }
        do {
            _ = try PageRangeParser.parseSegments(trimmed, pageCount: pageCount)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The cut set the every-N stepper implies, so its reflection grid draws the same colored groups the
    /// setting will export.
    private var everyNPreviewCuts: Set<Int> {
        SplitCuts.everyNCuts(pageCount: pageCount, chunkSize: chunkSize)
    }

    /// Toggles the cut after a 1-based page — a gap click in the visual grid. Out-of-range guards keep a
    /// stray cut from ever pointing past the document.
    private func toggleCut(_ page: Int) {
        guard page >= 1, page < pageCount else { return }
        if cuts.contains(page) {
            cuts.remove(page)
        } else {
            cuts.insert(page)
        }
    }

    var body: some View {
        Group {
            if let result {
                successView(result)
            } else {
                HSplitView {
                    sidebarColumn
                        .toolSidebarWidth()
                    previewColumn
                        .frame(minWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if busy { Color.black.opacity(0.08).ignoresSafeArea() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                inputURL = urls.first
            case .failure(let err):
                alertMessage = err.localizedDescription
            }
        }
        .toolErrorAlert($alertMessage)
        .task(id: selectionPathKey) {
            await loadThumbnails()
        }
    }

    // MARK: - Preview column

    /// The right-hand pane, chosen per mode. Visual and every-N share the colored-group grid — Visual
    /// with live scissor cut-markers, every-N reflecting the setting read-only. Custom keeps its
    /// click-to-select thumbnails, the power-user surface that can express reorders and overlaps a
    /// gap-based grid can't.
    @ViewBuilder
    private var previewColumn: some View {
        let renderPage: (PreviewPageSpec) async -> NSImage? = { spec in
            guard let url = inputURL else { return nil }
            return (try? await PDFPageThumbnailLoader.loadPage(from: url, pageIndex: spec.id - 1))?.image
        }
        switch mode {
        case .visual:
            SplitGroupedPreviewColumn(
                pages: pageSpecs,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                cuts: cuts,
                onToggleCut: { toggleCut($0) },
                previewSubtitle: "Each colored group becomes its own PDF. Click a scissors between pages to cut.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here or choose one to see its pages.",
                render: renderPage
            )
        case .everyN:
            SplitGroupedPreviewColumn(
                pages: pageSpecs,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                cuts: everyNPreviewCuts,
                onToggleCut: nil,
                previewSubtitle: "Each colored group becomes its own PDF — the stepper on the left sets where the cuts fall.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here or choose one to see its pages.",
                render: renderPage
            )
        case .customRanges:
            SinglePDFPreviewColumn(
                pages: pageSpecs,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                previewSubtitle: "Every page in the file; the settings on the left decide where the cuts fall.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here or choose one to see its pages.",
                emptySystemImage: "scissors",
                selectedPages: visualSelection,
                onTogglePage: visualTogglePage,
                selectionPrompt: visualSelectionPrompt,
                render: renderPage
            )
        }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FileSidebarHeader(
                        accent: accent,
                        icon: "scissors",
                        subtitle: sidebarSubtitle,
                        hasFile: inputURL != nil,
                        onClear: { inputURL = nil },
                        onAdd: { showImporter = true }
                    )

                    Group {
                        if inputURL == nil {
                            EmptyFileDropZone(
                                accent: accent,
                                icon: "scissors",
                                description: "Preview pages on the right, then choose how to divide the document.",
                                isTargeted: isDropTargeted,
                                onChoose: { showImporter = true }
                            )
                        } else if let url = inputURL {
                            SelectedFileCard(
                                accent: accent,
                                url: url,
                                isLoadingPreview: isGeneratingPreviews,
                                pageCount: pageCount
                            )
                        }
                    }
                    .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                        consumeDroppedProviders(providers)
                        return true
                    }

                    if inputURL != nil {
                        splitOptions
                    }
                }
                .padding(18)
                .formCard()
                .padding(12)
            }

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Split & save…", busy: busy, canRun: canRun) {
                Task { await runSplit() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarSubtitle: String {
        if inputURL == nil {
            return "Drop a PDF or add a file, then pick where to cut. Each part becomes its own file."
        }
        return "Parts are written into a folder you choose. The original file is not changed."
    }


    private var splitOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How to split")
                .font(.subheadline.weight(.semibold))

            Picker("How to split", selection: $mode) {
                ForEach(SplitMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .visual:
                Text("Click a scissors between pages on the right to start a new file there; click a cut to merge two files back together. Each colored group is one PDF.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !cuts.isEmpty {
                    Button("Clear cuts") { cuts = [] }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .help("Merge everything back into one file")
                }
            case .everyN:
                HStack(spacing: 12) {
                    Stepper(value: $chunkSize, in: 1...max(1, pageCount)) {
                        Text("\(chunkSize) page\(chunkSize == 1 ? "" : "s") per file")
                            .font(.callout)
                    }
                }
                Text("The document is cut into consecutive chunks of this many pages; the last file takes whatever remains.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .customRanges:
                TextField("e.g. 1-3, 4-6, 7-10", text: $rangeText)
                    .textFieldStyle(.roundedBorder)
                Text("Each comma group becomes one file (1-3 → a 3-page file). 1-based; ranges are inclusive.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let customRangeError {
                RangeFieldNote(text: customRangeError, systemImage: "exclamationmark.triangle", isError: true, accent: accent)
            } else if let parts = estimatedParts {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Creates \(parts) file\(parts == 1 ? "" : "s")", systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentText(accent, on: scheme, contrast: contrast))
                    if let pageBreakdown {
                        Text(pageBreakdown)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .formCard()
    }

    // MARK: - Success

    private func successView(_ result: SplitResult) -> some View {
        ToolSuccessView(
            accent: accent,
            title: "Split into \(result.files.count) file\(result.files.count == 1 ? "" : "s")",
            path: result.directory.path,
            onShowInFinder: {
                NSWorkspace.shared.activateFileViewerSelecting(result.files)
            },
            onDoAnother: {
                withAnimation { self.result = nil }
            }
        )
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let url = inputURL else {
            pageSpecs = []
            isGeneratingPreviews = false
            return
        }
        // Drop the previous document's pages before the await so nobody picks page numbers
        // against thumbnails of a file that is no longer loaded — and the typed range with them:
        // stale text (or a leftover out-of-range typo) made the next thumbnail click silently
        // replace the whole field with just the clicked page.
        pageSpecs = []
        rangeText = ""
        cuts = []
        isGeneratingPreviews = true
        do {
            // Only the page count loads up front; cells render on demand as they appear.
            let count = try await PDFPageThumbnailLoader.pageCount(of: url)
            // `.task(id:)` cancelled this load if the file changed again; a superseded load must
            // neither install its stale result nor clear the spinner the newer load now owns.
            guard !Task.isCancelled else { return }
            pageSpecs = PreviewPageSpec.specs(forPDFAt: url, pageCount: count)
            // A smaller document caps the chunk at its page count (every-N of a short file is one
            // file) rather than snapping back to 1 — "every 8" on a 5-page doc becomes "every 5".
            chunkSize = min(chunkSize, max(1, pageSpecs.count))
            isGeneratingPreviews = false
        } catch is CancellationError {
            // Superseded mid-load; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            pageSpecs = []
            isGeneratingPreviews = false
            if case PDFOperationError.encryptedInput = error {
                // The loader refuses locked documents (their pages render blank). Surface the
                // actionable message and clear the selection back to the empty state — the
                // pattern Clean Metadata established.
                alertMessage = error.localizedDescription
                inputURL = nil
            }
        }
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            if let url = await NSItemProvider.firstResolvablePDFURL(from: providers) {
                inputURL = url
            }
        }
    }

    // MARK: - Visual selection

    /// Visual page selection is offered only in custom-ranges mode; "Every N pages" has no page-level
    /// choice to make, so it renders the plain, non-interactive preview (selection nil).
    private var visualSelection: Set<Int>? {
        guard mode == .customRanges else { return nil }
        return VisualPageSelection.pages(from: rangeText, pageCount: pageSpecs.count)
    }

    private var visualTogglePage: ((Int) -> Void)? {
        mode == .customRanges ? { togglePage($0) } : nil
    }

    private var visualSelectionPrompt: String? {
        mode == .customRanges ? "Click pages to include — each unbroken run becomes its own file." : nil
    }

    /// Toggles one 1-based page in the custom-ranges field. The range text stays authoritative, so
    /// clicks and typing share one state; clicking canonicalizes it to ascending runs, and each
    /// unbroken run is one output file. Splitting into adjacent-but-separate files (e.g. `1-3 | 4-6`)
    /// can't be drawn by clicking — that stays a text-field capability, matching custom ranges' own
    /// "each comma group is a file" rule.
    private func togglePage(_ page: Int) {
        var pages = VisualPageSelection.pages(from: rangeText, pageCount: pageSpecs.count)
        if pages.contains(page) {
            pages.remove(page)
        } else {
            pages.insert(page)
        }
        rangeText = VisualPageSelection.rangeString(from: pages)
    }

    // MARK: - Run

    @MainActor
    private func runSplit() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        let directory: URL
        // Which URLs need security scope for the write. A folder picked by the user is scoped; the
        // source's own parent folder (used by "Save beside original") is not — and in this unsandboxed
        // app doesn't need to be. Scoping it would fail `startAccessingSecurityScopedResource`.
        let scopeURLs: [URL]
        if SaveLocation.current() == .besideOriginal {
            directory = fileURL.deletingLastPathComponent()
            scopeURLs = [fileURL]
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose Folder"
            panel.message = "Choose a folder for the split PDF files"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            directory = chosen
            scopeURLs = [fileURL, directory]
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.split.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.split.title)
        }

        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let modeSnapshot = mode
        let chunkSnapshot = max(1, chunkSize)
        let rangeSnapshot = rangeText
        let cutsSnapshot = cuts
        let stripMetadata = UserDefaults.standard.bool(forKey: SettingsKeys.stripMetadataOnExport)

        do {
            let files = try await PDFBackgroundWork.run {
                try URLCollectionSecurityScope.withAccess(scopeURLs) {
                    guard let doc = PDFDocument(url: fileURL) else {
                        throw PDFOperationError.couldNotOpen(fileURL)
                    }
                    let count = doc.pageCount
                    guard count > 0 else { throw PDFOperationError.emptyPDF }

                    let segments: [[Int]]
                    switch modeSnapshot {
                    case .visual:
                        segments = SplitCuts.segments(pageCount: count, cuts: cutsSnapshot)
                    case .everyN:
                        segments = PageRangeParser.everyNPagesSegments(pageCount: count, chunkSize: chunkSnapshot)
                    case .customRanges:
                        segments = try PageRangeParser.parseSegments(rangeSnapshot, pageCount: count)
                    }

                    let parts = try PDFToolkit.split(
                        inputURL: fileURL,
                        into: directory,
                        baseName: baseName,
                        segments: segments
                    )
                    if stripMetadata {
                        // Honor the Files-tab "Strip metadata on export" setting, like the single-file
                        // tools. Best-effort per part: each file is already a valid split output, so a
                        // strip hiccup must never fail an otherwise-successful run.
                        for part in parts {
                            guard let raw = try? Data(contentsOf: part) else { continue }
                            let cleaned = PDFExportCoordinator.stripMetadata(raw)
                            try? cleaned.write(to: part, options: .atomic)
                        }
                    }
                    return parts
                }
            }
            withAnimation {
                result = SplitResult(directory: directory, files: files)
            }
            ActivityLog.shared.recordSaved(Tool.split.title, to: directory, bytes: nil, detail: "\(files.count) \(files.count == 1 ? "file" : "files")")
            AfterExportAction.current().perform(on: files)
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.split.title) failed: \(error.localizedDescription)")
        }
    }
}
