import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One image queued for the combined PDF. Identity is the row, not the URL — the same image may
/// deliberately appear twice (a cover repeated at the end, say), so each row needs its own id.
private struct ImageQueueItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

struct ImagesToPDFToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var items: [ImageQueueItem] = []
    @State private var pageSize: ImagePageSize = .matchImage
    @State private var fillsPage = false
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "images.pdf"
    @State private var isDropTargeted = false
    @State private var thumbnails: [PDFPageThumbnail] = []
    /// Displayed pixel dimensions per file path, resolved on the background queue alongside the
    /// thumbnails — the rows must never do ImageIO reads inside `body` (once per row per re-render,
    /// on the main thread, was a real hitch with a long queue).
    @State private var pixelSizes: [String: CGSize] = [:]
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120

    /// Reload key: the ordered paths, so add/remove/reorder all refresh the preview.
    private var itemsKey: String {
        items.map(\.url.path).joined(separator: "|")
    }

    var body: some View {
        HSplitView {
            sidebarColumn
                .toolSidebarWidth()
            SinglePDFPreviewColumn(
                thumbnails: thumbnails,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: accent,
                previewSubtitle: "Each image becomes one page, in list order.",
                emptyTitle: "No images yet",
                emptySubtitle: "Drop JPG, PNG, or HEIC files here, or click Add Images…",
                emptySystemImage: "photo.on.rectangle.angled"
            )
            .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if busy { Color.black.opacity(0.08).ignoresSafeArea() }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                items.append(contentsOf: urls.map { ImageQueueItem(url: $0) })
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.imagesToPdf.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.imagesToPdf.title) failed: \(err.localizedDescription)")
            }
        }
        .alert(AppBrand.displayName, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .task(id: itemsKey) {
            await loadThumbnails()
        }
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        headerRow

                        Group {
                            if items.isEmpty {
                                emptyDropZone
                            } else {
                                imageList
                            }
                        }
                        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                            consumeDroppedProviders(providers)
                            return true
                        }
                    }
                    .padding(18)
                    .formCard()

                    if !items.isEmpty {
                        layoutSection
                    }
                }
                .padding(12)
            }

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Combine & save…", busy: busy, canRun: !items.isEmpty) {
                Task { await runCombine() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text("Images")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if !items.isEmpty {
                        Button("Clear all") {
                            items.removeAll()
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Empty the list (files on disk are untouched)")
                    }
                    Button("Add Images…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Text(items.isEmpty
                 ? "Drop images or add files. Every common format works—JPG, PNG, HEIC, TIFF."
                 : "\(items.count) image\(items.count == 1 ? "" : "s") → \(items.count) page\(items.count == 1 ? "" : "s"), top to bottom.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop images here or add files")
                .font(.title3.weight(.semibold))
            Text("Each image becomes one PDF page. Reorder them any time before saving.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose Images…") { showImporter = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [7, 5])
                )
                .foregroundStyle(isDropTargeted ? accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No images selected. Drop images or choose files.")
    }

    private var imageList: some View {
        VStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    RowIndexBadge(number: index + 1, accent: accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let size = pixelSizes[item.url.path] {
                            Text("\(Int(size.width)) × \(Int(size.height))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        Button {
                            items.swapAt(index, index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help("Move up")
                        Button {
                            items.swapAt(index, index + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == items.count - 1)
                        .help("Move down")
                        Button {
                            items.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove from the list (the file stays on disk)")
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.025))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Page \(index + 1): \(item.url.lastPathComponent)")
            }
        }
    }

    // MARK: - Layout controls

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Page layout")
                .font(.subheadline.weight(.semibold))
            Picker("Page size", selection: $pageSize) {
                ForEach(ImagePageSize.allCases, id: \.self) { size in
                    Text(size.label).tag(size)
                }
            }
            if pageSize != .matchImage {
                Picker("Placement", selection: $fillsPage) {
                    Text("Fit").tag(false)
                    Text("Fill").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(layoutFootnote)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .formCard()
    }

    private var layoutFootnote: String {
        switch (pageSize, fillsPage) {
        case (.matchImage, _):
            return "Every page takes its image’s exact size—nothing is cropped or letterboxed."
        case (_, false):
            return "Fit keeps the whole image visible, centered on the page. Landscape images get a landscape page."
        case (_, true):
            return "Fill covers the page edge to edge and crops whatever overflows. Landscape images get a landscape page."
        }
    }

    // MARK: - Preview

    private func loadThumbnails() async {
        guard !items.isEmpty else {
            thumbnails = []
            pixelSizes = [:]
            isGeneratingPreviews = false
            return
        }
        let urls = items.map(\.url)
        thumbnails = []
        isGeneratingPreviews = true
        do {
            // Pure ImageIO — runs on the global executor via the nonisolated helper, NOT the PDF
            // serial queue, so a big image queue can't starve other tools' page previews.
            let loaded = try await PDFToolkit.imagePreviews(for: urls)
            guard !Task.isCancelled else { return }
            thumbnails = loaded.0
            pixelSizes = loaded.1
            isGeneratingPreviews = false
        } catch is CancellationError {
            // Superseded mid-render; the newer load owns the state.
        } catch {
            guard !Task.isCancelled else { return }
            thumbnails = []
            isGeneratingPreviews = false
        }
    }

    private func consumeDroppedProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var added: [ImageQueueItem] = []
            for p in providers {
                if let url = await p.resolveImageItemURL() {
                    added.append(ImageQueueItem(url: url))
                }
            }
            items.append(contentsOf: added)
        }
    }

    // MARK: - Export

    @MainActor
    private func runCombine() async {
        guard !items.isEmpty else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.imagesToPdf.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.imagesToPdf.title)
        }

        let urls = items.map(\.url)
        let options = ImagesToPDFOptions(pageSize: pageSize, fillsPage: fillsPage)
        suggestedName = (urls.first?.deletingPathExtension().lastPathComponent ?? "images") + ".pdf"

        do {
            let data = try await PDFBackgroundWork.run {
                try URLCollectionSecurityScope.withAccess(urls) {
                    try PDFToolkit.imagesToPDFData(inputURLs: urls, options: options)
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: urls.first,
                toolTitle: Tool.imagesToPdf.title,
                defaultStem: "images",
                suffixWord: ""
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
            ActivityLog.shared.error("\(Tool.imagesToPdf.title) failed: \(error.localizedDescription)")
        }
    }
}
