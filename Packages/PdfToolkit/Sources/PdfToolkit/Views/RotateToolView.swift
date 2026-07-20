import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct RotateToolView: View {
    @State private var inputURL: URL?
    @State private var scope: PageScope = .all
    @State private var rangeText = ""
    @State private var quarterTurns = 1
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "rotated.pdf"
    @State private var isDropTargeted = false
    @State private var thumbnails: [PDFPageThumbnail] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120

    // Multiple-files mode. The batch engine rotates every page of every file (there is no per-file
    // page picking), so the page-scope controls are replaced by an all-pages note in this mode.
    @State private var fileMode: ToolFileMode = .single
    @StateObject private var batchRunner = BatchRunner()

    enum PageScope: String, CaseIterable, Identifiable {
        case all
        case range
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All pages"
            case .range: return "Page range"
            }
        }
    }

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    var body: some View {
        if fileMode == .multiple {
            MultiFileBatchPanel(
                runner: batchRunner,
                tool: .rotate,
                mode: $fileMode,
                makeOperation: { .rotateConfig(quarterTurns: quarterTurns) },
                fallbackSuffix: "rotated"
            ) {
                batchRotationSection
            }
        } else {
            singleFileBody
        }
    }

    private var singleFileBody: some View {
        HSplitView {
            sidebarColumn
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
            SinglePDFPreviewColumn(
                thumbnails: thumbnails,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: Tool.rotate.accent,
                previewSubtitle: "Thumbnails show every page; only the pages you choose below are rotated in the new PDF.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here, choose one, or use Add PDF… to see thumbnails.",
                emptySystemImage: "rotate.right"
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.rotate.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.rotate.title) failed: \(err.localizedDescription)")
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
            VStack(alignment: .leading, spacing: 14) {
                ToolFileModePicker(mode: $fileMode)

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

                pagesSection
                rotationSection
            }
            .padding(18)
            .formCard()
            .padding(12)

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Rotate & save…", busy: busy, canRun: inputURL != nil) {
                Task { await runRotate() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "rotate.right")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tool.rotate.accent)
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
            Text(sidebarSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sidebarSubtitle: String {
        if inputURL == nil {
            return "Drop a PDF or add a file. Rotation options stay here; thumbnails are on the right."
        }
        return "Your original stays on disk until you save. Pick all pages or a range, then choose rotation."
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "rotate.right")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tool.rotate.accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Preview every page on the right, then choose which pages to rotate.")
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
                .foregroundStyle(isDropTargeted ? Tool.rotate.accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file selected. Drop a PDF or choose PDF.")
    }

    private func selectedFileCard(url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tool.rotate.accent.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Tool.rotate.accent)
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

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pages")
                .font(.subheadline.weight(.semibold))
            Picker("Scope", selection: $scope) {
                ForEach(PageScope.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)

            if scope == .range {
                TextField("e.g. 1, 3-5, 8", text: $rangeText)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(16)
        .formCard()
    }

    private var rotationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rotation")
                .font(.subheadline.weight(.semibold))
            Picker("Turns", selection: $quarterTurns) {
                Text("90° clockwise").tag(1)
                Text("180°").tag(2)
                Text("270° clockwise").tag(3)
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .formCard()
    }

    /// Rotation config for Multiple-files mode: the same turn picker, but with an all-pages note in
    /// place of the page-scope controls — the batch engine turns every page of every file.
    private var batchRotationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rotation")
                .font(.subheadline.weight(.semibold))
            Picker("Turns", selection: $quarterTurns) {
                Text("90° clockwise").tag(1)
                Text("180°").tag(2)
                Text("270° clockwise").tag(3)
            }
            .pickerStyle(.segmented)
            Label("Every page of every file is rotated. Page ranges aren't available in Multiple files mode.",
                  systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        // Drop the previous document's pages before the await so nobody picks page numbers
        // against thumbnails of a file that is no longer loaded.
        thumbnails = []
        isGeneratingPreviews = true
        do {
            let loaded = try await PDFPageThumbnailLoader.loadAllPages(from: url)
            // `.task(id:)` cancelled this load if the file changed again; a superseded load must
            // neither install its stale result nor clear the spinner the newer load now owns.
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
    private func runRotate() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.rotate.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.rotate.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-rotated.pdf"
        let scopeSnapshot = scope
        let rangeSnapshot = rangeText
        let quarterTurnsSnapshot = quarterTurns

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
                    let indices: [Int]
                    switch scopeSnapshot {
                    case .all:
                        indices = Array(0..<count)
                    case .range:
                        // The user explicitly chose "Page range": an empty field must error, not
                        // quietly mean "all pages" — that surprise rotated whole documents.
                        indices = try PageRangeParser.parse(
                            rangeSnapshot,
                            pageCount: count,
                            emptyMeansAllPages: false
                        )
                    }
                    return try PDFExportSupport.data { out in
                        try PDFToolkit.rotate(
                            inputURL: fileURL,
                            outputURL: out,
                            pageIndices: indices,
                            quarterTurns: quarterTurnsSnapshot
                        )
                    }
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.rotate.title,
                defaultStem: "rotated",
                suffixWord: "rotated"
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
            ActivityLog.shared.error("\(Tool.rotate.title) failed: \(error.localizedDescription)")
        }
    }
}
