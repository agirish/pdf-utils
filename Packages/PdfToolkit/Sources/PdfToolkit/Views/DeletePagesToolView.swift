import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct DeletePagesToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var inputURL: URL?
    @State private var rangeText = ""
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "edited.pdf"
    @State private var isDropTargeted = false
    @State private var pageSpecs: [PreviewPageSpec] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    private var canRunDelete: Bool {
        guard inputURL != nil else { return false }
        guard !rangeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // If the range resolves and would remove every page, keep Run disabled — the inline note already
        // explains why, and it matches the export's cannotRemoveEveryPage guard (which stays the backstop
        // for an invalid range that only errors at parse time).
        if case .pages(let indices) = PageRangeField.evaluate(rangeText, pageCount: pageSpecs.count, preserveOrder: false),
           pageSpecs.count > 0, indices.count >= pageSpecs.count {
            return false
        }
        return true
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
                previewSubtitle: "Full document preview; only the page numbers you list are removed from the saved copy.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here, choose one, or use Add PDF… to see thumbnails.",
                emptySystemImage: Tool.deletePages.symbolName,
                selectedPages: VisualPageSelection.pages(from: rangeText, pageCount: pageSpecs.count),
                onTogglePage: togglePage,
                selectionPrompt: "Click pages to mark them for removal, or type them on the left.",
                dimsUnselected: false,
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.deletePages.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.deletePages.title) failed: \(err.localizedDescription)")
            }
        }
        .toolErrorAlert($alertMessage)
        .task(id: selectionPathKey) {
            await loadThumbnails()
        }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                FileSidebarHeader(
                    accent: accent,
                    icon: Tool.deletePages.symbolName,
                    subtitle: sidebarSubtitle,
                    hasFile: inputURL != nil,
                    onClear: { inputURL = nil },
                    onAdd: { showImporter = true }
                )

                Group {
                    if inputURL == nil {
                        EmptyFileDropZone(
                            accent: accent,
                            icon: Tool.deletePages.symbolName,
                            description: "See every page on the right, then enter which page numbers to remove.",
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
            .padding(12)

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Delete pages & save…", busy: busy, canRun: canRunDelete) {
                Task { await runDelete() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarSubtitle: String {
        if inputURL == nil {
            return "Drop a PDF or add a file. List pages to remove on the left; preview on the right."
        }
        return "An empty page list does nothing — type which pages to drop. At least one page must remain."
    }

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pages to remove")
                .font(.subheadline.weight(.semibold))
            Text("Example: 1, 3-5 removes those pages from a copy of the PDF.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("e.g. 2, 4-6", text: $rangeText)
                .textFieldStyle(.roundedBorder)
            rangeNote
        }
        .padding(16)
        .formCard()
    }

    /// Live "N will remain" hint / inline error, mirroring the export parse so the field can't claim
    /// one thing and Save do another. Blank and mid-type states stay silent.
    @ViewBuilder
    private var rangeNote: some View {
        switch PageRangeField.evaluate(rangeText, pageCount: pageSpecs.count, preserveOrder: false) {
        case .empty, .incomplete:
            EmptyView()
        case .pages(let indices):
            let removed = indices.count
            let remaining = pageSpecs.count - removed
            if remaining <= 0 {
                RangeFieldNote(
                    text: "That removes every page — at least one must remain.",
                    systemImage: "exclamationmark.triangle",
                    isError: true,
                    accent: accent
                )
            } else {
                RangeFieldNote(
                    text: "Removes \(removed) page\(removed == 1 ? "" : "s") — \(remaining) will remain.",
                    systemImage: "rectangle.stack.badge.minus",
                    accent: accent
                )
            }
        case .invalid(let message):
            RangeFieldNote(text: message, systemImage: "exclamationmark.triangle", isError: true, accent: accent)
        }
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let url = inputURL else {
            pageSpecs = []
            isGeneratingPreviews = false
            return
        }
        // Drop the previous document's pages before the await so nobody picks page numbers
        // against thumbnails of a file that is no longer loaded — and the typed spec with them
        // (same rationale as Extract/Split): "2, 4-6" typed for document A silently deleted those
        // pages from a swapped-in document B with one click.
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

    /// Toggles one 1-based page in/out of the removal set and writes the result back to the range
    /// field — the field stays the single source of truth, so a click and a keystroke can never
    /// disagree. Blank means nothing (Delete never treats an empty field as "all pages"), so the first
    /// click on a fresh document marks just that page; clicking canonicalizes the text to ascending
    /// runs (e.g. `5,1,2` typed, then a click, becomes `1-2, 5`).
    private func togglePage(_ page: Int) {
        var pages = VisualPageSelection.pages(from: rangeText, pageCount: pageSpecs.count)
        if pages.contains(page) {
            pages.remove(page)
        } else {
            pages.insert(page)
        }
        rangeText = VisualPageSelection.rangeString(from: pages)
    }

    // MARK: - Export

    @MainActor
    private func runDelete() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.deletePages.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.deletePages.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-edited.pdf"

        let pagesSpec = rangeText

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    guard let doc = PDFDocument(url: fileURL) else {
                        throw PDFOperationError.couldNotOpen(fileURL)
                    }
                    let count = doc.pageCount
                    guard count > 0 else {
                        throw PDFOperationError.emptyPDF
                    }
                    let indices = try PageRangeParser.parse(pagesSpec, pageCount: count, emptyMeansAllPages: false)
                    return try PDFToolkit.deletePagesData(inputURL: fileURL, pageIndices: indices)
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.deletePages.title,
                defaultStem: "edited",
                suffixWord: "edited"
            ) {
            case .savedBeside:
                break
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                showExporter = true
            }
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.deletePages.title) failed: \(error.localizedDescription)")
        }
    }
}
