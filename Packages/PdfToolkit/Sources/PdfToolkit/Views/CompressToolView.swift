import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which lever the user drives compression with: a direct quality slider, or a size budget the tool
/// works down to on its own.
private enum CompressMode: Hashable {
    case quality
    case targetSize
}

struct CompressToolView: View {
    @State private var inputURL: URL?
    // Starts on (and writes back to) the Advanced "Default compression quality" — so the slider is
    // pre-selected and sticky across launches. Same 0.2…1 range as that control.
    @AppStorage(SettingsKeys.defaultCompressionQuality) private var quality: Double = 0.72
    @State private var mode: CompressMode = .quality
    // Target file size in megabytes for `.targetSize` mode. A plain, friendly unit for the field.
    @State private var targetMB: Double = 2
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: PDFFileDocument?
    @State private var suggestedName = "compressed.pdf"
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
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
            SinglePDFPreviewColumn(
                thumbnails: thumbnails,
                isGenerating: isGeneratingPreviews,
                thumbnailSize: $thumbnailSize,
                accent: Tool.compress.accent,
                previewSubtitle: "Pages in the file you’re about to compress.",
                emptyTitle: "No PDF selected",
                emptySubtitle: "Drop a PDF here, choose one, or use Add PDF… to see thumbnails.",
                emptySystemImage: "arrow.down.doc"
            )
            .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if busy { Color.black.opacity(0.08).ignoresSafeArea() }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
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
                PDFExportCoordinator.didExport(to: url, toolTitle: Tool.compress.title, bytes: savedBytes)
            case .failure(let err):
                guard !err.isUserCancelled else { break }
                alertMessage = err.localizedDescription
                ActivityLog.shared.error("\(Tool.compress.title) failed: \(err.localizedDescription)")
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

                controlsSection
            }
            .padding(18)
            .formCard()
            .padding(12)

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Compress & save…", busy: busy, canRun: canRun) {
                Task { await runCompress() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tool.compress.accent)
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
            return "Drop a PDF or add a file. Quality stays here; thumbnails appear on the right."
        }
        return "Rebuilds pages as images to shrink the file. Use the quality slider to balance size and sharpness."
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tool.compress.accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Thumbnails load on the right after you pick a document.")
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
                .foregroundStyle(isDropTargeted ? Tool.compress.accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file selected. Drop a PDF or choose PDF.")
    }

    private func selectedFileCard(url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tool.compress.accent.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Tool.compress.accent)
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

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Compression mode", selection: $mode) {
                Text("By quality").tag(CompressMode.quality)
                Text("By target size").tag(CompressMode.targetSize)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .quality:
                qualityControls
            case .targetSize:
                targetSizeControls
            }
        }
        .padding(16)
        .formCard()
    }

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quality")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(qualityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $quality, in: 0.2...1)
        }
    }

    private var targetSizeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target size")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let label = sourceSizeLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField("2", value: $targetMB, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                    .multilineTextAlignment(.trailing)
                Text("MB")
                    .foregroundStyle(.secondary)
                Stepper("Target size", value: $targetMB, in: 0.1...500, step: 0.5)
                    .labelsHidden()
            }
            Text("Tries progressively lower quality until the file fits under your target.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canRun: Bool {
        guard inputURL != nil else { return false }
        if mode == .targetSize { return targetMB > 0 }
        return true
    }

    /// The original file's size, shown next to the target field as context. Best-effort — a nil here
    /// (e.g. the URL isn't currently readable) just hides the hint rather than blocking the tool.
    private var sourceSizeLabel: String? {
        guard let url = inputURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return "Now \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
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
        defer { isGeneratingPreviews = false }
        do {
            let loaded = try await PDFPageThumbnailLoader.loadAllPages(from: url)
            // `.task(id:)` cancelled this load if the file changed again; don't let a stale
            // result overwrite the newer document's thumbnails.
            guard !Task.isCancelled else { return }
            thumbnails = loaded
        } catch {
            thumbnails = []
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

    private var qualityLabel: String {
        switch quality {
        case ..<0.45: return "Smaller file"
        case ..<0.75: return "Balanced"
        default: return "Higher quality"
        }
    }

    @MainActor
    private func runCompress() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        busy = true
        AppStateManager.shared.beginOperation(Tool.compress.title)
        defer {
            busy = false
            AppStateManager.shared.endOperation(Tool.compress.title)
        }

        suggestedName = fileURL.deletingPathExtension().lastPathComponent + "-compressed.pdf"
        let qualityValue = quality
        let selectedMode = mode
        let targetBytes = max(1, Int((targetMB * 1_048_576).rounded()))

        do {
            let data = try await PDFBackgroundWork.run {
                try fileURL.withSecurityScopedAccess {
                    try PDFExportSupport.data { out in
                        switch selectedMode {
                        case .quality:
                            try PDFToolkit.compress(inputURL: fileURL, outputURL: out, quality: qualityValue)
                        case .targetSize:
                            try PDFToolkit.compressToTarget(inputURL: fileURL, outputURL: out, targetBytes: targetBytes)
                        }
                    }
                }
            }
            switch try await PDFExportCoordinator.route(
                data: data,
                source: fileURL,
                toolTitle: Tool.compress.title,
                defaultStem: "compressed",
                suffixWord: "compressed"
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
            ActivityLog.shared.error("\(Tool.compress.title) failed: \(error.localizedDescription)")
        }
    }
}
