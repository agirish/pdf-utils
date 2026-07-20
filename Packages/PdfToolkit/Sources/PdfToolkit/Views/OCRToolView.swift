import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct OCRToolView: View {
    @Environment(\.toolAccent) private var accent
    @State private var inputURL: URL?
    @State private var accurate = true
    @State private var skipPagesWithText = true
    @State private var busy = false
    @State private var progressPage = 0
    @State private var progressTotal = 0
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "searchable.pdf"
    @State private var isDropTargeted = false
    @State private var thumbnails: [PDFPageThumbnail] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
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
                previewSubtitle: "Pages in the file about to be recognized. The images stay exactly as they are.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a scanned PDF here or choose one to make it searchable.",
                emptySystemImage: "text.viewfinder"
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.ocr.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.ocr.title) failed: \(err.localizedDescription)")
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
        .task(id: selectionPathKey) {
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
                            if inputURL == nil {
                                emptyDropZone
                            } else if let url = inputURL {
                                selectedFileCard(url: url)
                            }
                        }
                        .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
                            consumeDroppedProviders(providers)
                            return true
                        }
                    }
                    .padding(18)
                    .formCard()

                    if inputURL != nil {
                        recognitionSection
                    }
                }
                .padding(12)
            }

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Make searchable & save…", busy: busy, canRun: inputURL != nil) {
                Task { await runOCR() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "text.viewfinder")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .font(.title)
                Text("PDF file")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if inputURL != nil {
                        Button("Clear") {
                            inputURL = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Remove the selected file")
                    }
                    Button("Add PDF…") { showImporter = true }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Text(inputURL == nil
                 ? "Drop a scanned PDF or add a file. Recognition runs entirely on this Mac."
                 : "Recognition reads every page image and hides real, selectable text behind it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Scans and photographed documents become searchable—select, copy, and ⌘F just start working.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose PDF…") { showImporter = true }
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
        .accessibilityLabel("No file selected. Drop a PDF or choose PDF.")
    }

    private func selectedFileCard(url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout.weight(.medium))
                if isGeneratingPreviews {
                    Text("Loading preview…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else if !thumbnails.isEmpty {
                    Text("\(thumbnails.count) page\(thumbnails.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected file \(url.lastPathComponent)")
    }

    // MARK: - Recognition controls

    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Accuracy")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Accuracy", selection: $accurate) {
                    Text("Fast").tag(false)
                    Text("Accurate").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Toggle("Skip pages that already have text", isOn: $skipPagesWithText)
                .toggleStyle(.checkbox)
                .font(.subheadline)
            Text(skipPagesWithText
                 ? "Pages whose text already selects are copied through untouched—only true scans are recognized."
                 : "Every page is recognized, even ones with live text. That can stack a second text layer; leave the skip on unless a page's existing text is broken.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if busy && progressTotal > 0 {
                Divider()
                ProgressView(value: Double(progressPage), total: Double(progressTotal))
                Text("Recognizing text… page \(progressPage) of \(progressTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .formCard()
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let url = inputURL else {
            thumbnails = []
            isGeneratingPreviews = false
            return
        }
        thumbnails = []
        isGeneratingPreviews = true
        do {
            let loaded = try await PDFPageThumbnailLoader.loadAllPages(from: url)
            guard !Task.isCancelled else { return }
            thumbnails = loaded
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
            for p in providers {
                if let url = await p.resolvePDFItemURL() {
                    inputURL = url
                    return
                }
            }
        }
    }

    // MARK: - Export

    @MainActor
    private func runOCR() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        progressPage = 0
        progressTotal = 0
        AppStateManager.shared.beginOperation(Tool.ocr.title)
        defer {
            busy = false
            progressTotal = 0
            AppStateManager.shared.endOperation(Tool.ocr.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-searchable.pdf"
        let options = OCROptions(accurate: accurate, skipPagesWithText: skipPagesWithText)

        do {
            let data = try await PDFBackgroundWork.run { isCancelled in
                try fileURL.withSecurityScopedAccess {
                    try PDFExportSupport.data { out in
                        _ = try PDFToolkit.ocr(
                            inputURL: fileURL,
                            outputURL: out,
                            options: options,
                            progress: { page, total in
                                Task { @MainActor in
                                    progressPage = page
                                    progressTotal = total
                                }
                            },
                            isCancelled: isCancelled
                        )
                    }
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.ocr.title,
                defaultStem: "searchable",
                suffixWord: "searchable"
            ) {
            case .savedBeside:
                break
            case .present(let document, let name):
                exportDoc = document
                suggestedName = name
                showExporter = true
            }
        } catch is CancellationError {
            // The screen was left mid-run; nothing to report.
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.ocr.title) failed: \(error.localizedDescription)")
        }
    }
}
