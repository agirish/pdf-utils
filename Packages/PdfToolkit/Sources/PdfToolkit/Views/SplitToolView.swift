import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private enum SplitMode: String, CaseIterable, Identifiable {
    case everyN
    case customRanges

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyN: return "Every N pages"
        case .customRanges: return "Custom ranges"
        }
    }
}

private struct SplitResult {
    let directory: URL
    let files: [URL]
}

struct SplitToolView: View {
    @State private var inputURL: URL?
    @State private var mode: SplitMode = .everyN
    @State private var chunkSize = 1
    @State private var rangeText = ""
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var thumbnails: [PDFPageThumbnail] = []
    @State private var isGeneratingPreviews = false
    @State private var thumbnailSize: CGFloat = 120
    @State private var result: SplitResult?

    private var selectionPathKey: String {
        inputURL?.standardizedFileURL.path ?? ""
    }

    private var pageCount: Int { thumbnails.count }

    /// Number of output files the current settings would produce (for the live hint).
    private var estimatedParts: Int? {
        guard pageCount > 0 else { return nil }
        switch mode {
        case .everyN:
            let n = max(1, chunkSize)
            return Int((Double(pageCount) / Double(n)).rounded(.up))
        case .customRanges:
            let groups = rangeText.split(separator: ",").filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return groups.isEmpty ? nil : groups.count
        }
    }

    var body: some View {
        Group {
            if let result {
                successView(result)
            } else {
                HSplitView {
                    sidebarColumn
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
                    SinglePDFPreviewColumn(
                        thumbnails: thumbnails,
                        isGenerating: isGeneratingPreviews,
                        thumbnailSize: $thumbnailSize,
                        accent: Tool.split.accent,
                        previewSubtitle: "Every page in the file; the settings on the left decide where the cuts fall.",
                        emptyTitle: "No PDF selected",
                        emptySubtitle: "Drop a PDF here or choose one to see its pages.",
                        emptySystemImage: "scissors"
                    )
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

                if inputURL != nil {
                    splitOptions
                }
            }
            .padding(18)
            .formCard()
            .padding(12)

            Spacer(minLength: 0)

            Divider()

            RunActionButton(title: "Split & save…", busy: busy, canRun: inputURL != nil) {
                Task { await runSplit() }
            }
            .padding(16)
            .toolActionBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "scissors")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tool.split.accent)
                    .font(.title)
                Text("PDF file")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if inputURL != nil {
                        Button("Clear") { inputURL = nil }
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
            return "Drop a PDF or add a file, then pick where to cut. Each part becomes its own file."
        }
        return "Parts are written into a folder you choose. The original file is not changed."
    }

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "scissors")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tool.split.accent.opacity(0.85))
            Text("Drop a PDF here or add a file")
                .font(.title3.weight(.semibold))
            Text("Preview pages on the right, then choose how to divide the document.")
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
                .foregroundStyle(isDropTargeted ? Tool.split.accent : Color.secondary.opacity(0.35))
        }
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file selected. Drop a PDF or choose PDF.")
    }

    private func selectedFileCard(url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tool.split.accent.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Tool.split.accent)
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
                } else if pageCount > 0 {
                    Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
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
            case .everyN:
                HStack(spacing: 12) {
                    Stepper(value: $chunkSize, in: 1...max(1, pageCount)) {
                        Text("\(chunkSize) page\(chunkSize == 1 ? "" : "s") per file")
                            .font(.callout)
                    }
                }
                Text("The document is cut into consecutive chunks of this many pages; the last file takes whatever remains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .customRanges:
                TextField("e.g. 1-3, 4-6, 7-10", text: $rangeText)
                    .textFieldStyle(.roundedBorder)
                Text("Each comma group becomes one file (1-3 → a 3-page file). 1-based; ranges are inclusive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let parts = estimatedParts {
                Label("Produces \(parts) file\(parts == 1 ? "" : "s")", systemImage: "doc.on.doc")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Tool.split.accent)
            }
        }
        .padding(16)
        .formCard()
    }

    // MARK: - Success

    private func successView(_ result: SplitResult) -> some View {
        ToolFormContainer {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                VStack(spacing: 8) {
                    Text("Split into \(result.files.count) file\(result.files.count == 1 ? "" : "s")")
                        .font(.title2.weight(.bold))
                    Text(result.directory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 16) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(result.files)
                    }
                    .controlSize(.large)

                    Button("Split another") {
                        withAnimation { self.result = nil }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let url = inputURL else {
            thumbnails = []
            isGeneratingPreviews = false
            return
        }
        isGeneratingPreviews = true
        defer { isGeneratingPreviews = false }
        do {
            thumbnails = try await PDFPageThumbnailLoader.loadAllPages(from: url)
            if chunkSize > max(1, thumbnails.count) { chunkSize = 1 }
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

    // MARK: - Run

    @MainActor
    private func runSplit() async {
        guard let fileURL = inputURL else {
            alertMessage = PDFOperationError.noInputFiles.localizedDescription
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder for the split PDF files"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

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

        do {
            let files = try await PDFBackgroundWork.run {
                try URLCollectionSecurityScope.withAccess([fileURL, directory]) {
                    guard let doc = PDFDocument(url: fileURL) else {
                        throw PDFOperationError.couldNotOpen(fileURL)
                    }
                    let count = doc.pageCount
                    guard count > 0 else { throw PDFOperationError.emptyPDF }

                    let segments: [[Int]]
                    switch modeSnapshot {
                    case .everyN:
                        segments = stride(from: 0, to: count, by: chunkSnapshot).map { start in
                            Array(start..<min(start + chunkSnapshot, count))
                        }
                    case .customRanges:
                        segments = try PageRangeParser.parseSegments(rangeSnapshot, pageCount: count)
                    }

                    return try PDFToolkit.split(
                        inputURL: fileURL,
                        into: directory,
                        baseName: baseName,
                        segments: segments
                    )
                }
            }
            withAnimation {
                result = SplitResult(directory: directory, files: files)
            }
            ActivityLog.shared.recordSaved(Tool.split.title, to: directory, bytes: nil, detail: "\(files.count) \(files.count == 1 ? "file" : "files")")
        } catch {
            alertMessage = error.localizedDescription
            ActivityLog.shared.error("\(Tool.split.title) failed: \(error.localizedDescription)")
        }
    }
}
