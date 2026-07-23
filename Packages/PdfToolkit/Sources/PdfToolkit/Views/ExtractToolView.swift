import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ExtractToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var inputURL: URL?
    /// The pending "your output will lose X" warning and its acknowledgement.
    @StateObject private var fidelity = OutputFidelityGate()
    // Blank means "all pages" (see the field's hint). Loading a file also resets this to "" in
    // loadThumbnails, so seeding it to "1" only made the field visibly flip 1 → blank on first load.
    @State private var rangeText = ""
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "extracted.pdf"
    @State private var isDropTargeted = false
    @State private var pageSpecs: [PreviewPageSpec] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120

    /// The inline confirmation shown after a successful save, and the summary stashed while the save
    /// dialog is open (its URL is filled in from the dialog's success callback).
    @State private var saveSummary: ToolSaveSummary?
    @State private var pendingSaveSummary: ToolSaveSummary?

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .toolSidebarWidth()
            SinglePDFPreviewColumn(
                pages: pageSpecs,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                previewSubtitle: "Every page in the file; the list on the left chooses which pages go into the new PDF.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here, choose one, or use Add PDF… to see thumbnails.",
                emptySystemImage: "doc.on.clipboard",
                selectedPages: VisualPageSelection.pages(from: rangeText, pageCount: pageSpecs.count, emptyMeansAllPages: true),
                onTogglePage: togglePage,
                selectionPrompt: "Click pages to choose what to extract, or type them on the left.",
                render: { spec in
                    guard let url = inputURL else { return nil }
                    return (try? await PDFPageThumbnailLoader.loadPage(from: url, pageIndex: spec.id - 1))?.image
                }
            )
            .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .pdf,
            defaultFilename: suggestedName.exportFilenameStem
        ) { result in
            let savedBytes = exportDoc?.data.count
            exportDoc = nil
            switch result {
            case .success(let url):
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.extract.title, bytes: savedBytes)
                if var summary = pendingSaveSummary {
                    summary.url = url
                    saveSummary = summary
                }
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.extract.title) failed: \(err.localizedDescription)")
            }
            pendingSaveSummary = nil
        }
        .toolErrorAlert($alertMessage)
        .task(id: selectionPathKey) {
            guard let url = inputURL else {
                fidelity.update(nil)
                return
            }
            // Copying pages into a fresh document leaves the widgets but drops the catalog
            // /AcroForm, so a real form stops being fillable — verified empirically.
            await fidelity.refresh(urls: [url], formLoss: .formOrphaned, checksBookmarks: false)
        }
        .task(id: selectionPathKey) {
            await loadThumbnails()
        }
        // Editing which pages to extract makes the last run's "Extracted N pages" receipt stale — the
        // live range no longer matches the saved copy — so invalidate it on any range edit.
        .onChange(of: rangeText) { _, _ in saveSummary = nil }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        FileSidebarHeader(
                            accent: accent,
                            icon: "doc.on.clipboard",
                            subtitle: sidebarSubtitle,
                            hasFile: inputURL != nil,
                            onClear: { inputURL = nil },
                            onAdd: { showImporter = true }
                        )

                        Group {
                            if inputURL == nil {
                                EmptyFileDropZone(
                                    accent: accent,
                                    icon: "doc.on.clipboard",
                                    description: "Preview pages on the right, then type which pages to copy into a new PDF.",
                                    isTargeted: isDropTargeted,
                                    onChoose: { showImporter = true }
                                )
                            } else if let url = inputURL {
                                SelectedFileCard(
                                    accent: accent,
                                    url: url,
                                    isLoadingPreview: isGeneratingPreviews,
                                    pageCount: pageSpecs.count
                                )
                            }
                        }
                        .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                            consumeDroppedProviders(providers)
                            return true
                        }

                        pagesSection
                    }
                    .padding(18)
                    .formCard()

                    if let saveSummary {
                        ToolSaveBanner(accent: accent, summary: saveSummary)
                    }
                }
                .padding(12)
            }

            Spacer(minLength: 0)

            Divider()

            VStack(spacing: 12) {
                if let warning = fidelity.warning {
                    OutputFidelityNote(warning: warning, toolTitle: Tool.extract.title)
                }
                RunActionButton(title: "Extract & save…", busy: busy || fidelity.isSettling, canRun: inputURL != nil) {
                    Task {
                        await fidelity.settle()
                        guard fidelity.shouldProceed() else { return }
                        await runExtract()
                    }
                }
            }
            .padding(16)
            .toolActionBar()
            .outputFidelityConfirmation(fidelity, toolTitle: Tool.extract.title) {
                Task { await runExtract() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarSubtitle: String {
        if inputURL == nil {
            return "Drop a PDF or add a file. Page list is on the left; thumbnails on the right."
        }
        return "Order in the field is kept (e.g. 5,1,2). Leave the field empty to extract all pages."
    }

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pages to extract")
                .font(.subheadline.weight(.semibold))
            Text(
                "List order is kept (e.g. 5,1,2 → page 5, then 1, then 2). Ranges: 3-5 → 3,4,5; 5-3 → 5,4,3. Leave empty for all pages."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            TextField("e.g. 1, 3-5", text: $rangeText)
                .textFieldStyle(.roundedBorder)
            rangeNote
        }
        .padding(16)
        .formCard()
    }

    /// Live "N pages will be extracted" hint / inline error. A blank field is valid here (it extracts
    /// every page), so it reports the whole count rather than staying silent; mid-type stays silent.
    @ViewBuilder
    private var rangeNote: some View {
        switch PageRangeField.evaluate(rangeText, pageCount: pageSpecs.count, preserveOrder: true) {
        case .empty:
            if pageSpecs.count > 0 {
                RangeFieldNote(
                    text: "Extracts all \(pageSpecs.count) page\(pageSpecs.count == 1 ? "" : "s").",
                    systemImage: "doc.on.doc",
                    accent: accent
                )
            }
        case .incomplete:
            EmptyView()
        case .pages(let indices):
            RangeFieldNote(
                text: "Extracts \(indices.count) page\(indices.count == 1 ? "" : "s") into the new PDF.",
                systemImage: "doc.on.doc",
                accent: accent
            )
        case .invalid(let message):
            RangeFieldNote(text: message, systemImage: "exclamationmark.triangle", isError: true, accent: accent)
        }
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        // A different (or removed) file: the last run's confirmation no longer describes what's loaded.
        saveSummary = nil
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
        isGeneratingPreviews = true
        do {
            // Only the page count loads up front; cells render on demand as they appear.
            let count = try await PDFPageThumbnailLoader.pageCount(of: url)
            // `.task(id:)` cancelled this load if the file changed again; a superseded load must
            // neither install its stale result nor clear the spinner the newer load now owns.
            guard !Task.isCancelled else { return }
            pageSpecs = PreviewPageSpec.specs(forPDFAt: url, pageCount: count)
            isGeneratingPreviews = false
        } catch is CancellationError {
            // Superseded mid-load; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            pageSpecs = []
            isGeneratingPreviews = false
            if case PDFOperationError.encryptedInput = error {
                // Locked selection: actionable message + back to the empty state (Metadata's pattern).
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

    /// Toggles one 1-based page in/out of the selection and writes the result back to the range field
    /// — the field stays the single source of truth, so a click and a keystroke can never disagree.
    /// Clicking canonicalizes the text to ascending runs (e.g. `5,1,2` typed, then a click, becomes
    /// `1-2, 5`); custom order remains available by typing and leaving the thumbnails alone.
    private func togglePage(_ page: Int) {
        // Same blank-field semantics as the highlight layer: blank = all pages, so the first click
        // on a fully-selected document deselects that page rather than starting from nothing.
        var pages = VisualPageSelection.pages(from: rangeText, pageCount: pageSpecs.count, emptyMeansAllPages: true)
        if pages.contains(page) {
            pages.remove(page)
        } else {
            pages.insert(page)
        }
        rangeText = VisualPageSelection.rangeString(from: pages)
    }

    // MARK: - Export

    @MainActor
    private func runExtract() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        saveSummary = nil
        AppStateManager.shared.beginOperation(Tool.extract.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.extract.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-extracted.pdf"
        let rangeSnapshot = rangeText

        do {
            let (data, extractedCount) = try await PDFBackgroundWork.run { () -> (Data, Int) in
                try fileURL.withSecurityScopedAccess { () -> (Data, Int) in
                    guard let doc = PDFDocument(url: fileURL) else {
                        throw PDFOperationError.couldNotOpen(fileURL)
                    }
                    let count = doc.pageCount
                    guard count > 0 else {
                        throw PDFOperationError.emptyPDF
                    }
                    let indices = try PageRangeParser.parse(rangeSnapshot, pageCount: count, preserveOrder: true)
                    let out = try PDFToolkit.extractData(inputURL: fileURL, pageIndices: indices)
                    return (out, indices.count)
                }
            }
            let summary = ToolSaveSummary(
                title: "Extracted \(extractedCount) page\(extractedCount == 1 ? "" : "s")",
                detail: "Saved a new PDF with just those pages.",
                url: nil
            )
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.extract.title,
                defaultStem: "extracted",
                suffixWord: "extracted"
            ) {
            case .savedBeside(let url):
                saveSummary = ToolSaveSummary(title: summary.title, detail: summary.detail, url: url)
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                pendingSaveSummary = summary
                showExporter = true
            }
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.extract.title) failed: \(error.localizedDescription)")
        }
    }
}
